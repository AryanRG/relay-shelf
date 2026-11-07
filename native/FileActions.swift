import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Local, non-destructive file transforms. All returned URLs are newly created files.
///
/// Options (unknown keys and incorrectly typed values are errors):
/// - resizeImage: width (integer, default 1600), height (optional integer).
///   Fits inside the bounding box, preserving aspect ratio, never enlarging.
/// - convertImage: format (required: png, jpeg, heic).
/// - compressImage: quality (0.1...1, default 0.75), format (default jpeg;
///   png, heic, and original are also accepted). PNG remains lossless.
/// - stripMetadata, ocr, mergePDF, imagesToPDF: no options.
/// Resize/strip preserve PNG/JPEG/HEIC encoding; other still images become PNG.
/// All image encodings bake orientation into sRGB pixels, retain alpha except for
/// JPEG (white background), and do not copy source metadata. Conversion/strip do
/// not silently reduce resolution. Multi-frame images are explicitly rejected.
/// OCR uses fast, on-device Vision recognition, one UTF-8 file per source;
/// PDF pages are separated by a form feed. Empty recognition produces empty text.
/// Uses Vision's default recognition languages without forced script detection.
/// Each Vision request has a 30-second deadline that calls VNRequest.cancel().
/// imagesToPDF uses one oriented image per page, one pixel = one PDF point,
/// with embedded images downsampled to 4096 pixels on the longest edge.
enum FileActions {
    private static let maxFiles = 100
    private static let maxPages = 100 // Total pages across the whole invocation.
    private static let maxFileBytes = 256 * 1_024 * 1_024
    private static let maxBatchBytes = 512 * 1_024 * 1_024
    private static let maxSourcePixels = 100_000_000
    private static let maxDecodedPixels = 16_777_216
    private static let maxDimension = 32_768
    private static let maxPDFDimension: CGFloat = 14_400
    private static let maxTextBytes = 8 * 1_024 * 1_024
    private static let ocrRequestSeconds: TimeInterval = 30

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Operation: String, Sendable {
        case resizeImage, convertImage, compressImage, stripMetadata, ocr, mergePDF, imagesToPDF
    }

    private enum Format: String, Sendable {
        case png, jpeg, heic
        var identifier: String {
            switch self {
            case .png: return UTType.png.identifier
            case .jpeg: return UTType.jpeg.identifier
            case .heic: return UTType.heic.identifier
            }
        }
        static func original(_ identifier: String) -> Format {
            [Format.png, .jpeg, .heic].first { $0.identifier == identifier } ?? .png
        }
    }

    private struct Configuration: Sendable {
        let operation: Operation
        var width = 1600
        var height: Int?
        var format: Format?
        var quality = 0.75

        init(operation: String, options: [String: Any]) throws {
            guard let operation = Operation(rawValue: operation) else {
                throw Failure(message: "Unsupported file operation: \(operation).")
            }
            self.operation = operation
            let allowed: Set<String>
            switch operation {
            case .resizeImage: allowed = ["width", "height"]
            case .convertImage: allowed = ["format"]
            case .compressImage: allowed = ["quality", "format"]
            default: allowed = []
            }
            let unknown = Set(options.keys).subtracting(allowed).sorted()
            guard unknown.isEmpty else {
                throw Failure(message: "Unsupported option(s) for \(operation.rawValue): \(unknown.joined(separator: ", ")).")
            }
            if let value = options["width"] { width = try Self.dimension(value, name: "width") }
            if let value = options["height"] { height = try Self.dimension(value, name: "height") }
            if let value = options["quality"] {
                guard let number = Self.number(value), (0.1...1).contains(number) else {
                    throw Failure(message: "quality must be a finite number in 0.1...1.")
                }
                quality = number
            }
            if operation == .compressImage { format = .jpeg }
            if let value = options["format"] {
                guard let string = value as? String else {
                    throw Failure(message: "format must be png, jpeg, or heic (or original for compressImage).")
                }
                if operation == .compressImage && string == "original" {
                    format = nil
                } else if let parsed = Format(rawValue: string) {
                    format = parsed
                } else {
                    throw Failure(message: "Unsupported image format: \(string). Use png, jpeg, or heic\(operation == .compressImage ? ", or original" : "").")
                }
            } else if operation == .convertImage {
                throw Failure(message: "convertImage requires format: png, jpeg, or heic.")
            }
        }

        private static func number(_ value: Any) -> Double? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }

        private static func dimension(_ value: Any, name: String) throws -> Int {
            guard let number = number(value), number.rounded() == number,
                  (1...Double(maxDimension)).contains(number) else {
                throw Failure(message: "\(name) must be an integer in 1...\(maxDimension).")
            }
            return Int(number)
        }
    }

    private struct ImageInfo {
        let width: Int // Display dimensions after applying EXIF orientation.
        let height: Int
        let identifier: String
    }

    private enum InputKind {
        case image(ImageInfo)
        case pdf(Int)
    }

    private struct Input {
        let url: URL
        let kind: InputKind
        // Reject common source changes between preflight and execution.
        let size: Int
        let modified: Date?
        let identity: NSObject?
    }

    /// VNRequest.cancel() is intended to be called while perform() is running.
    /// The lock protects only the reference and flag, never the Vision work.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var request: VNRequest?
        private var deadline: DispatchSourceTimer?
        private var timedOut = false

        func install(_ request: VNRequest) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            self.request = request
            timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + ocrRequestSeconds)
            timer.setEventHandler { [weak self, weak request] in
                guard let request else { return }
                self?.expire(request)
            }
            deadline = timer
            timer.resume()
        }

        func clear() -> Bool {
            lock.lock()
            request = nil
            let timer = deadline
            deadline = nil
            let expired = timedOut
            lock.unlock()
            timer?.cancel()
            return expired
        }

        private func expire(_ request: VNRequest) {
            lock.lock()
            guard self.request === request, !cancelled else { lock.unlock(); return }
            timedOut = true
            lock.unlock()
            request.cancel()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let active = request
            let timer = deadline
            lock.unlock()
            timer?.cancel()
            active?.cancel()
        }
    }

    static func execute(operation: String, urls: [URL], outputDirectory: URL,
                        options: [String: Any]) async throws -> [URL] {
        try Task.checkCancellation()
        // Convert the untyped bridge payload before crossing the task boundary.
        let configuration = try Configuration(operation: operation, options: options)
        let cancellation = Cancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try run(configuration, urls: urls, outputDirectory: outputDirectory, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
            cancellation.cancel()
        })
    }

    private static func run(_ configuration: Configuration, urls: [URL], outputDirectory: URL,
                            cancellation: Cancellation) throws -> [URL] {
        try Task.checkCancellation()
        guard outputDirectory.isFileURL else { throw Failure(message: "Output must be a local directory.") }
        let inputs = try preflight(configuration, urls: urls)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let existed = fm.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory)
        guard !existed || isDirectory.boolValue else { throw Failure(message: "Output location is not a directory.") }
        try Task.checkCancellation()
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var staging: URL?
        var published: [URL] = []
        var succeeded = false
        defer {
            if !succeeded { for url in published { try? fm.removeItem(at: url) } }
            if let staging { try? fm.removeItem(at: staging) }
            if !succeeded && !existed,
               (try? fm.contentsOfDirectory(atPath: outputDirectory.path).isEmpty) == true {
                try? fm.removeItem(at: outputDirectory)
            }
        }
        let work = outputDirectory.appendingPathComponent(".RelayShelf-actions-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        staging = work
        var staged: [(url: URL, name: String, ext: String)] = []
        var outputBytes = 0
        func record(_ url: URL, name: String, ext: String) throws {
            let size = try resources(url, keys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxFileBytes, size <= maxBatchBytes - outputBytes else {
                throw Failure(message: "Generated files exceed the 256 MiB per-file or 512 MiB batch limit.")
            }
            outputBytes += size
            staged.append((url, name, ext))
        }

        switch configuration.operation {
        case .mergePDF:
            let target = work.appendingPathComponent("merged.pdf")
            try merge(inputs, to: target)
            try record(target, name: "Merged", ext: "pdf")
        case .imagesToPDF:
            let target = work.appendingPathComponent("images.pdf")
            try imagesPDF(inputs, to: target)
            try record(target, name: "Images", ext: "pdf")
        default:
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                try unchanged(input)
                try autoreleasepool {
                    let ext: String
                    if configuration.operation == .ocr { ext = "txt" }
                    else if case .image(let info) = input.kind {
                        ext = (configuration.format ?? Format.original(info.identifier)).rawValue
                    } else { throw Failure(message: "An image is required: \(input.url.lastPathComponent).") }
                    let target = work.appendingPathComponent("\(index).\(ext)")
                    if configuration.operation == .ocr {
                        try recognize(input, to: target, cancellation: cancellation)
                    } else {
                        try transform(input, configuration: configuration, to: target)
                    }
                    try unchanged(input)
                    try record(target, name: input.url.deletingPathExtension().lastPathComponent, ext: ext)
                }
            }
        }
        // No public output appears until every input has completed successfully.
        for item in staged {
            try Task.checkCancellation()
            let stem = String(item.name.prefix(80))
            var committed = false
            for _ in 0..<5 {
                let target = outputDirectory.appendingPathComponent("\(stem)-\(configuration.operation.rawValue)-\(UUID().uuidString).\(item.ext)")
                do {
                    // link(2) fails atomically if a name exists; never replaces a source
                    // or another operation's output. Staging is on the same volume.
                    try fm.linkItem(at: item.url, to: target)
                    published.append(target)
                    committed = true
                    break
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    continue
                }
            }
            guard committed else { throw Failure(message: "Could not allocate a fresh output filename.") }
        }
        try Task.checkCancellation()
        succeeded = true
        return published
    }

    private static func preflight(_ configuration: Configuration, urls: [URL]) throws -> [Input] {
        guard !urls.isEmpty, urls.count <= maxFiles else {
            throw Failure(message: "Select between 1 and \(maxFiles) source files.")
        }
        var bytes = 0
        var pages = 0
        var result: [Input] = []
        let writable = CGImageDestinationCopyTypeIdentifiers() as! [String]
        for url in urls {
            try Task.checkCancellation()
            try autoreleasepool {
                guard url.isFileURL else { throw Failure(message: "Source must be a local file: \(url.absoluteString).") }
                let values: URLResourceValues
                do {
                    values = try resources(url, keys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
                } catch { throw Failure(message: "Cannot read source \(url.lastPathComponent): \(error.localizedDescription)") }
                guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else {
                    throw Failure(message: "Source is not a readable regular file: \(url.lastPathComponent).")
                }
                let size = values.fileSize ?? 0
                guard size > 0, size <= maxFileBytes, size <= maxBatchBytes - bytes else {
                    throw Failure(message: "Source \(url.lastPathComponent) is empty or exceeds the 256 MiB per-file / 512 MiB batch limit.")
                }
                bytes += size
                let kind: InputKind
                if configuration.operation == .mergePDF {
                    kind = .pdf(try inspectPDF(url, remainingPages: maxPages - pages))
                } else if configuration.operation == .ocr, let document = CGPDFDocument(url as CFURL) {
                    kind = .pdf(try inspectPDF(url, remainingPages: maxPages - pages, document: document))
                } else {
                    let info = try inspectImage(url)
                    kind = .image(info)
                    let target = imageSize(info, configuration: configuration)
                    guard target.0 * target.1 <= maxDecodedPixels else {
                        throw Failure(message: "Image \(url.lastPathComponent) exceeds the 16-megapixel decode limit. Resize it first.")
                    }
                    if configuration.operation == .imagesToPDF {
                        guard max(info.width, info.height) <= Int(maxPDFDimension) else {
                            throw Failure(message: "Image page exceeds the 14,400-point PDF dimension limit: \(url.lastPathComponent).")
                        }
                    } else if configuration.operation != .ocr {
                        if configuration.operation == .compressImage, configuration.format == nil,
                           ![Format.png.identifier, Format.jpeg.identifier, Format.heic.identifier].contains(info.identifier) {
                            throw Failure(message: "Original-format compression supports only PNG, JPEG, and HEIC: \(url.lastPathComponent).")
                        }
                        let format = configuration.format ?? Format.original(info.identifier)
                        guard writable.contains(format.identifier) else {
                            throw Failure(message: "This system cannot encode \(format.rawValue) images.")
                        }
                    }
                }
                switch kind {
                case .pdf(let count): pages += count
                case .image: pages += 1
                }
                guard pages <= maxPages else { throw Failure(message: "The operation exceeds the \(maxPages)-page limit.") }
                result.append(Input(url: url, kind: kind, size: size, modified: values.contentModificationDate,
                                    identity: values.fileResourceIdentifier as? NSObject))
            }
        }
        return result
    }

    private static func unchanged(_ input: Input) throws {
        let values = try resources(input.url, keys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isRegularFile == true, values.fileSize == input.size,
              values.contentModificationDate == input.modified,
              input.identity == nil || input.identity?.isEqual(values.fileResourceIdentifier) == true else {
            throw Failure(message: "Source changed during the operation: \(input.url.lastPathComponent). Retry with a stable source.")
        }
    }

    private static func resources(_ url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: keys)
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure(message: "Unsupported or invalid image: \(url.lastPathComponent).")
        }
        return source
    }

    private static func inspectImage(_ url: URL) throws -> ImageInfo {
        let source = try imageSource(url)
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw Failure(message: "Incomplete or corrupt image: \(url.lastPathComponent).")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw Failure(message: "Only single-frame still images are supported: \(url.lastPathComponent).")
        }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier {
            try validatePNG(url)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let identifier = CGImageSourceGetType(source) else {
            throw Failure(message: "Invalid image dimensions: \(url.lastPathComponent).")
        }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w.rounded() == w, h.rounded() == h,
              (1...Double(maxDimension)).contains(w), (1...Double(maxDimension)).contains(h),
              w * h <= Double(maxSourcePixels) else {
            throw Failure(message: "Image exceeds the 100-megapixel / \(maxDimension)-pixel source dimension limit: \(url.lastPathComponent).")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw Failure(message: "Invalid image orientation: \(url.lastPathComponent).") }
        return ImageInfo(width: orientation >= 5 ? Int(h) : Int(w),
                         height: orientation >= 5 ? Int(w) : Int(h), identifier: identifier as String)
    }

    // ImageIO can return a salvaged image and statusComplete for a truncated PNG.
    // Check framing without decoding or allocating its compressed chunk payloads.
    private static func validatePNG(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 8)
        var hasPixels = false
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            guard let header = try file.read(upToCount: 8), header.count == 8 else { break }
            let length = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let offset = try file.offset()
            guard offset <= size, length + 4 <= size - offset else { break }
            let kind = String(data: header.suffix(4), encoding: .ascii)
            if kind == "IDAT" { hasPixels = true }
            if kind == "IEND", length == 0, hasPixels, offset + 4 == size { return }
            try file.seek(toOffset: offset + length + 4)
        }
        throw Failure(message: "Incomplete or invalid PNG container: \(url.lastPathComponent).")
    }

    private static func imageSize(_ info: ImageInfo, configuration: Configuration) -> (Int, Int) {
        let scale: Double
        switch configuration.operation {
        case .resizeImage:
            scale = min(1, Double(configuration.width) / Double(info.width),
                        configuration.height.map { Double($0) / Double(info.height) } ?? 1)
        case .ocr: scale = min(1, 3200 / Double(max(info.width, info.height)))
        case .imagesToPDF: scale = min(1, 4096 / Double(max(info.width, info.height)))
        default: scale = 1
        }
        return (max(1, Int((Double(info.width) * scale).rounded(.down))),
                max(1, Int((Double(info.height) * scale).rounded(.down))))
    }

    private static func decoded(_ input: Input, size: (Int, Int), opaque: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let source = try imageSource(input.url)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.0, size.1),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure(message: "Could not decode image: \(input.url.lastPathComponent).")
        }
        try Task.checkCancellation()
        guard image.width * image.height <= maxDecodedPixels else { throw Failure(message: "Decoded image exceeds the 16-megapixel limit.") }
        // Drawing into an sRGB context converts the source color profile, rather
        // than dropping a profile while leaving the source pixel values unchanged.
        let context = try bitmap(width: size.0, height: size.1)
        let rect = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw Failure(message: "Could not prepare image pixels.") }
        return result
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxDecodedPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "Could not allocate a bounded sRGB image buffer.")
        }
        return context
    }

    private static func transform(_ input: Input, configuration: Configuration, to target: URL) throws {
        guard case .image(let info) = input.kind else { throw Failure(message: "An image is required.") }
        let format = configuration.format ?? Format.original(info.identifier)
        let image = try decoded(input, size: imageSize(info, configuration: configuration), opaque: format == .jpeg)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, format.identifier as CFString, 1, nil) else {
            throw Failure(message: "Could not create \(format.rawValue) output.")
        }
        // Deliberately AddImage, never AddImageFromSource / CopyImageSource:
        // no EXIF, GPS, IPTC, XMP, TIFF, or textual source dictionaries are copied.
        var properties: [CFString: Any] = [:]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = configuration.operation == .compressImage ? configuration.quality : 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "Could not encode \(format.rawValue) output for \(input.url.lastPathComponent).")
        }
        if configuration.operation == .stripMetadata {
            try removeEncoderMetadata(target, format: format)
        }
    }

    /// ImageIO itself creates EXIF ColorSpace/PixelDimension tags in PNG/JPEG.
    /// Remove those carriers from our *new encoding*, without touching source
    /// bytes or the encoded pixels/color profile. Copy in bounded 1 MiB chunks.
    private static func removeEncoderMetadata(_ url: URL, format: Format) throws {
        if format != .heic {
            let clean = url.appendingPathExtension("clean")
            defer { try? FileManager.default.removeItem(at: clean) }
            guard FileManager.default.createFile(atPath: clean.path, contents: nil) else {
                throw Failure(message: "Could not create metadata-free output.")
            }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: clean)
            defer { try? writer.close() }
            let size = try reader.seekToEnd()
            guard size <= maxFileBytes else { throw Failure(message: "Encoded image exceeds the 256 MiB limit.") }
            try reader.seek(toOffset: 0)
            func read(_ count: Int) throws -> Data {
                guard let bytes = try reader.read(upToCount: count), bytes.count == count else {
                    throw Failure(message: "Could not read the generated image container.")
                }
                return bytes
            }
            func copy(_ count: UInt64) throws {
                var remaining = count
                while remaining > 0 {
                    try Task.checkCancellation()
                    let amount = Int(min(1_048_576, remaining))
                    try writer.write(contentsOf: read(amount))
                    remaining -= UInt64(amount)
                }
            }
            if format == .png {
                let signature = try read(8)
                guard signature == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
                    throw Failure(message: "Invalid generated PNG container.")
                }
                try writer.write(contentsOf: signature)
                while try reader.offset() < size {
                    try Task.checkCancellation()
                    let header = try read(8)
                    let length = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    let kind = String(data: header.suffix(4), encoding: .ascii) ?? ""
                    let offset = try reader.offset()
                    guard length + 4 <= size - offset else { throw Failure(message: "Invalid generated PNG chunk.") }
                    if ["eXIf", "tEXt", "zTXt", "iTXt"].contains(kind) {
                        try reader.seek(toOffset: offset + length + 4)
                    } else {
                        try writer.write(contentsOf: header)
                        try copy(length + 4) // Includes the unchanged chunk CRC.
                    }
                }
            } else {
                let signature = try read(2)
                guard signature == Data([0xFF, 0xD8]) else { throw Failure(message: "Invalid generated JPEG container.") }
                try writer.write(contentsOf: signature)
                while try reader.offset() < size {
                    try Task.checkCancellation()
                    let start = try reader.offset()
                    guard try read(1)[0] == 0xFF else { throw Failure(message: "Invalid generated JPEG marker.") }
                    var marker = try read(1)[0]
                    while marker == 0xFF { marker = try read(1)[0] }
                    if marker == 0xDA || marker == 0xD9 { // SOS: copy compressed scans verbatim.
                        try reader.seek(toOffset: start)
                        try copy(size - start)
                        break
                    }
                    let data = try read(2)
                    let length = UInt64(data[0]) * 256 + UInt64(data[1])
                    let offset = try reader.offset()
                    guard length >= 2, length - 2 <= size - offset else { throw Failure(message: "Invalid generated JPEG segment.") }
                    let end = offset + length - 2
                    if [0xE1, 0xED, 0xFE].contains(marker) { // EXIF/XMP, IPTC, comments.
                        try reader.seek(toOffset: end)
                    } else {
                        try reader.seek(toOffset: start)
                        try copy(end - start)
                    }
                }
            }
            try writer.close()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: clean, to: url)
        }
        let source = try imageSource(url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            guard properties[key] == nil else { throw Failure(message: "System encoder could not produce an image without \(key) metadata.") }
        }
    }

    private static func inspectPDF(_ url: URL, remainingPages: Int, document supplied: CGPDFDocument? = nil) throws -> Int {
        guard let document = supplied ?? CGPDFDocument(url as CFURL), document.isUnlocked else {
            throw Failure(message: "Invalid or password-locked PDF: \(url.lastPathComponent).")
        }
        guard document.allowsCopying else { throw Failure(message: "PDF does not permit content copying: \(url.lastPathComponent).") }
        let count = document.numberOfPages
        guard count > 0, count <= remainingPages else { throw Failure(message: "PDF exceeds the \(maxPages)-page batch limit or has no pages: \(url.lastPathComponent).") }
        for index in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw Failure(message: "Cannot read PDF page \(index).") }
            _ = try pageBounds(page)
        }
        return count
    }

    private static func pageBounds(_ page: CGPDFPage) throws -> CGRect {
        let media = page.getBoxRect(.mediaBox)
        let bounds = page.getBoxRect(.cropBox).intersection(media)
        guard !bounds.isNull, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 1, bounds.height >= 1,
              media.minX.isFinite, media.minY.isFinite, media.width.isFinite, media.height.isFinite,
              media.width >= 1, media.height >= 1,
              max(media.width, media.height) <= maxPDFDimension,
              max(bounds.width, bounds.height) <= maxPDFDimension,
              page.rotationAngle % 90 == 0 else {
            throw Failure(message: "PDF page has invalid geometry or exceeds the 14,400-point dimension limit.")
        }
        return bounds
    }

    private static func merge(_ inputs: [Input], to target: URL) throws {
        let merged = PDFDocument()
        for input in inputs {
            try Task.checkCancellation()
            try unchanged(input)
            try autoreleasepool {
                guard case .pdf(let count) = input.kind, let document = PDFDocument(url: input.url),
                      !document.isLocked, document.pageCount == count else { throw Failure(message: "Could not open PDF: \(input.url.lastPathComponent).") }
                for index in 0..<count {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { throw Failure(message: "Could not copy PDF page \(index + 1).") }
                    // PDFKit retains vectors, dimensions, crop boxes, rotation and
                    // annotations. It may normalize a nonzero media-box origin.
                    merged.insert(page, at: merged.pageCount)
                }
            }
            try unchanged(input)
        }
        try Task.checkCancellation()
        guard merged.write(to: target) else { throw Failure(message: "Could not write merged PDF.") }
    }

    private static func imagesPDF(_ inputs: [Input], to target: URL) throws {
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(target as CFURL, mediaBox: &paper, nil) else { throw Failure(message: "Could not create PDF output.") }
        defer { context.closePDF() }
        for input in inputs {
            try Task.checkCancellation()
            try unchanged(input)
            try autoreleasepool {
                guard case .image(let info) = input.kind else { throw Failure(message: "imagesToPDF requires still images.") }
                let config = try Configuration(operation: "imagesToPDF", options: [:])
                let image = try decoded(input, size: imageSize(info, configuration: config))
                var bounds = CGRect(x: 0, y: 0, width: info.width, height: info.height)
                let data = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(bounds)
                context.draw(image, in: bounds)
                context.endPDFPage()
            }
            try unchanged(input)
            try checkPDFSize(target)
        }
    }

    private static func checkPDFSize(_ url: URL) throws {
        let size = try resources(url, keys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileBytes else { throw Failure(message: "PDF output exceeds the 256 MiB limit.") }
    }

    private static func recognize(_ input: Input, to target: URL, cancellation: Cancellation) throws {
        var text = ""
        switch input.kind {
        case .image(let info):
            let config = try Configuration(operation: "ocr", options: [:])
            text = try recognizeImage(decoded(input, size: imageSize(info, configuration: config), opaque: true),
                                      cancellation: cancellation, label: input.url.lastPathComponent)
        case .pdf(let count):
            guard let document = CGPDFDocument(input.url as CFURL), document.isUnlocked,
                  document.numberOfPages == count else { throw Failure(message: "Could not open PDF for OCR.") }
            for index in 1...count {
                try Task.checkCancellation()
                let pageText = try autoreleasepool { () throws -> String in
                    guard let page = document.page(at: index) else { throw Failure(message: "Could not render PDF page \(index).") }
                    let bounds = try pageBounds(page)
                    let rotated = abs(page.rotationAngle % 180) == 90
                    let w = rotated ? bounds.height : bounds.width
                    let h = rotated ? bounds.width : bounds.height
                    // At most 144 DPI and 3200 pixels per edge, one page at a time.
                    let scale = min(2, 3200 / max(w, h))
                    let width = max(1, Int((w * scale).rounded(.up)))
                    let height = max(1, Int((h * scale).rounded(.up)))
                    let context = try bitmap(width: width, height: height)
                    let rect = CGRect(x: 0, y: 0, width: width, height: height)
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(rect)
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                    guard let image = context.makeImage() else { throw Failure(message: "Could not rasterize PDF page \(index).") }
                    return try recognizeImage(image, cancellation: cancellation, label: "\(input.url.lastPathComponent), page \(index)")
                }
                if index > 1 { text += "\n\u{000C}\n" }
                guard text.utf8.count + pageText.utf8.count <= maxTextBytes else { throw Failure(message: "OCR text exceeds the 8 MiB per-source limit.") }
                text += pageText
            }
        }
        try Task.checkCancellation()
        guard text.utf8.count <= maxTextBytes else { throw Failure(message: "OCR text exceeds the 8 MiB per-source limit.") }
        try Data(text.utf8).write(to: target, options: .withoutOverwriting)
    }

    private static func recognizeImage(_ image: CGImage, cancellation: Cancellation, label: String) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        // The accurate revision-3 path can block inside ANE model compilation
        // on macOS 27 even after cancel(). Use Vision's responsive fast path for
        // this interactive action; do not launch an uninterruptible warm-up.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        // Keep Vision's default recognition languages without loading additional
        // script-detection models for each newly launched process.
        request.automaticallyDetectsLanguage = false
        // This is an explicit user action, already off-main and sequential.
        // The background hint trades interactive latency for lower resource use.
        request.preferBackgroundProcessing = false
        try cancellation.install(request)
        var failure: Error?
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
        catch { failure = error }
        let timedOut = cancellation.clear()
        try Task.checkCancellation()
        guard !timedOut else { throw Failure(message: "Text recognition timed out after 30 seconds for \(label). Try a smaller image or fewer PDF pages.") }
        if let failure { throw Failure(message: "Text recognition failed for \(label): \(failure.localizedDescription)") }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
