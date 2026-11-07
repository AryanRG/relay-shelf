import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Standalone regression executable (no app/store dependencies):
// swiftc -swift-version 5 native/FileActions.swift tests/FileActionsTests.swift \
//   -framework Vision -framework PDFKit -o /tmp/relay-file-actions-tests
@main
struct FileActionsTests {
    private struct TestFailure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw TestFailure(description: message) }
    }

    private static func folder(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func contents(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private static func perform(_ operation: String, _ urls: [URL], _ output: URL,
                                _ options: [String: Any] = [:]) async throws -> [URL] {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await FileActions.execute(operation: operation, urls: urls, outputDirectory: output, options: options)
        if operation == "ocr" {
            print(String(format: "OCR completed %d source(s) in %.2fs", urls.count, ProcessInfo.processInfo.systemUptime - started))
        }
        return result
    }

    private static func failure(_ operation: String, _ urls: [URL], _ output: URL,
                                _ options: [String: Any] = [:], contains expected: String? = nil) async throws {
        let before = try contents(output)
        do {
            _ = try await perform(operation, urls, output, options)
            throw TestFailure(description: "Expected failure: \(operation), \(options)")
        } catch let error as TestFailure { throw error }
        catch {
            try check(!error.localizedDescription.isEmpty, "Failure has a readable description")
            if let expected {
                try check(error.localizedDescription.localizedCaseInsensitiveContains(expected),
                          "Expected '\(expected)' in '\(error.localizedDescription)'")
            }
        }
        try check(try contents(output) == before, "Failure leaves no partial outputs or staging folders")
    }

    private static func context(_ width: Int, _ height: Int, space: CGColorSpace? = nil) throws -> CGContext {
        guard let space = space ?? CGColorSpace(name: CGColorSpace.sRGB),
              let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure(description: "Cannot create fixture context")
        }
        return result
    }

    private static func image(_ width: Int, _ height: Int, transparent: Bool = false,
                              space: CGColorSpace? = nil) throws -> CGImage {
        let ctx = try context(width, height, space: space)
        // Two solid bands make orientation/color changes observable. A clear
        // corner verifies alpha rather than merely the encoder's alpha flag.
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        if transparent { ctx.clear(CGRect(x: 0, y: 0, width: max(1, width / 4), height: max(1, height / 2))) }
        guard let result = ctx.makeImage() else { throw TestFailure(description: "Cannot create fixture image") }
        return result
    }

    private static func encode(_ image: CGImage, _ url: URL, type: String = UTType.png.identifier,
                               properties: [CFString: Any] = [:], metadata: CGImageMetadata? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw TestFailure(description: "Cannot create fixture encoder")
        }
        if let metadata {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw TestFailure(description: "Cannot encode fixture") }
    }

    private static func properties(_ url: URL) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw TestFailure(description: "Cannot read image properties: \(url.path)")
        }
        return properties
    }

    private static func decoded(_ url: URL, oriented: Bool = false) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw TestFailure(description: "Cannot read fixture image") }
        let image: CGImage?
        if oriented {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ] as CFDictionary)
        } else { image = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let image else { throw TestFailure(description: "Cannot decode image: \(url.path)") }
        return image
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw TestFailure(description: "Missing pixel data") }
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private static func dimensions(_ url: URL, _ width: Int, _ height: Int) throws {
        let result = try decoded(url)
        try check(result.width == width && result.height == height,
                  "Expected \(width)x\(height), got \(result.width)x\(result.height)")
    }

    private static func textImage(_ text: String) throws -> CGImage {
        let ctx = try context(1100, 180)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1100, height: 180))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = CGPoint(x: 30, y: 60)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { throw TestFailure(description: "Cannot create text fixture") }
        return image
    }

    private static func pdf(_ url: URL, pages: [(CGRect, CGImage?)]) throws {
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &paper, nil) else { throw TestFailure(description: "Cannot create PDF fixture") }
        for (var bounds, image) in pages {
            let data = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            if let image { context.draw(image, in: bounds) }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func renderedPage(_ url: URL, page index: Int = 1) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index) else {
            throw TestFailure(description: "Cannot render PDF fixture")
        }
        let bounds = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle % 180) == 90
        let width = Int(rotated ? bounds.height : bounds.width)
        let height = Int(rotated ? bounds.width : bounds.height)
        let ctx = try context(width, height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()!
    }

    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            fputs("FileActionsTests failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let root = try folder(FileManager.default.temporaryDirectory, "RelayShelf-FileActionsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try folder(root, "sources")
        let output = try folder(root, "output")
        let png = sources.appendingPathComponent("alpha.png")
        try encode(image(80, 40, transparent: true), png)
        let pngData = try Data(contentsOf: png)
        try await imageOperations(png, output)
        print("PASS resize, PNG alpha, JPEG flattening, HEIC, compression, unique outputs")
        try await metadataAndOrientation(sources, output)
        print("PASS metadata removal, all eight orientations, sRGB color correctness")
        try await pdfAndOCR(sources, output)
        print("PASS ordered PDF merge, crop/rotation/annotations, image pages, image/PDF OCR")
        try await invalidAndBounds(png, sources, output)
        print("PASS invalid options/inputs, resource bounds, failure rollback")
        try await cancellation(png, sources, output)
        try check(try Data(contentsOf: png) == pngData, "Original source bytes remain unchanged")
        try check(try contents(output).allSatisfy { !$0.hasPrefix(".RelayShelf") }, "No staging folders remain")
        print("FileActionsTests passed (\(assertions) assertions)")
    }

    private static func imageOperations(_ png: URL, _ output: URL) async throws {
        let defaultResize = try await perform("resizeImage", [png], output)[0]
        try dimensions(defaultResize, 80, 40)
        let resized = try await perform("resizeImage", [png], output, ["width": 60, "height": 20])[0]
        try dimensions(resized, 40, 20)
        let widthOnly = try await perform("resizeImage", [png], output, ["width": 20])[0]
        try dimensions(widthOnly, 20, 10)
        let pngPixels = try pixels(decoded(defaultResize))
        try check(stride(from: 3, to: pngPixels.count, by: 4).contains { pngPixels[$0] == 0 }, "PNG retains genuinely transparent pixels")

        for format in ["png", "jpeg", "heic"] {
            let result = try await perform("convertImage", [png], output, ["format": format])[0]
            try check(result.pathExtension == format, "Conversion uses requested file extension")
            try dimensions(result, 80, 40)
            if format == "jpeg" {
                let bytes = try pixels(decoded(result))
                try check(stride(from: 0, to: bytes.count, by: 4).contains {
                    bytes[$0] >= 245 && bytes[$0 + 1] >= 245 && bytes[$0 + 2] >= 245 && bytes[$0 + 3] == 255
                }, "JPEG composites transparent pixels onto white")
            }
        }
        let kept = try await perform("compressImage", [png], output, ["format": "original"])[0]
        try check(kept.pathExtension == "png", "Original compression keeps PNG")
        try check(try pixels(decoded(kept)) == pixels(decoded(png)), "Lossless PNG compression preserves RGBA pixels")
        let compressed = try await perform("compressImage", [png], output)[0]
        try check(compressed.pathExtension == "jpeg", "Default compression outputs JPEG")
        try dimensions(compressed, 80, 40)
        let batch = try await perform("convertImage", [png, png], output, ["format": "png"])
        try check(batch.count == 2 && batch[0] != batch[1] && !batch.contains(png), "Repeated sources get distinct fresh output names")
        let repeatBatch = try await perform("convertImage", [png], output, ["format": "png"])
        try check(!batch.contains(repeatBatch[0]), "Repeated invocations never overwrite prior output")

        let ctx = try context(256, 128)
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(256 * 128) {
            bytes[index * 4] = UInt8(truncatingIfNeeded: index * 37)
            bytes[index * 4 + 1] = UInt8(truncatingIfNeeded: index * 13 + index / 256 * 59)
            bytes[index * 4 + 2] = UInt8(truncatingIfNeeded: index * 97)
            bytes[index * 4 + 3] = 255
        }
        let noisy = png.deletingLastPathComponent().appendingPathComponent("detail.png")
        try encode(ctx.makeImage()!, noisy)
        let original = try Data(contentsOf: noisy)
        let low = try await perform("compressImage", [noisy], output, ["quality": 0.1])[0]
        let high = try await perform("compressImage", [noisy], output, ["quality": 1.0])[0]
        try check(try Data(contentsOf: low).count < Data(contentsOf: high).count, "Compression quality changes actual JPEG encoding")
        try check(try Data(contentsOf: noisy) == original, "Compression leaves source unchanged")

        let sameDirectory = try await perform("stripMetadata", [png], png.deletingLastPathComponent())[0]
        try check(sameDirectory != png, "Source directory is a safe output destination")
        let wide = png.deletingLastPathComponent().appendingPathComponent("wide.png")
        try encode(image(2000, 40), wide)
        let defaultDownsample = try await perform("resizeImage", [wide], output)[0]
        try dimensions(defaultDownsample, 1600, 32)
    }

    private static func metadataAndOrientation(_ sources: URL, _ output: URL) async throws {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, "PRIVATE-XMP-CONTENT" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, "PRIVATE-EXIF-CONTENT" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, NSNumber(value: 12.5))
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, "N" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCredit, "PRIVATE-IPTC-CONTENT" as CFString)
        for orientation in 1...8 {
            let source = sources.appendingPathComponent("orientation-\(orientation).tiff")
            let space = CGColorSpace(name: CGColorSpace.displayP3)!
            try encode(image(80, 40, space: space), source, type: UTType.tiff.identifier, properties: [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE-EXIF-CONTENT"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCredit: "PRIVATE-IPTC-CONTENT"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "PRIVATE-ARTIST"],
            ], metadata: metadata)
            let original = try Data(contentsOf: source)
            let before = try properties(source)
            try check(before[kCGImagePropertyGPSDictionary] != nil && before[kCGImagePropertyExifDictionary] != nil,
                      "Fixture contains genuine GPS and EXIF metadata")
            let result = try await perform("stripMetadata", [source], output)[0]
            try dimensions(result, orientation >= 5 ? 40 : 80, orientation >= 5 ? 80 : 40)
            let after = try properties(result)
            for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                try check(after[key] == nil, "Strip does not carry source dictionary \(key): \(String(describing: after[key]))")
            }
            let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil)!
            let outputImage = CGImageSourceCreateWithURL(result as CFURL, nil)!
            let sourceXMP = CGImageSourceCopyMetadataAtIndex(sourceImage, 0, nil)
            try check(sourceXMP != nil && CGImageMetadataCopyTagWithPath(sourceXMP!, nil, "dc:description" as CFString) != nil,
                      "Fixture includes real XMP")
            let outputXMP = CGImageSourceCopyMetadataAtIndex(outputImage, 0, nil)
            if let outputXMP {
                try check(CGImageMetadataCopyTagWithPath(outputXMP, nil, "dc:description" as CFString) == nil, "Source XMP removed")
            }
            let reference = try pixels(decoded(source, oriented: true))
            let actual = try pixels(decoded(result))
            try check(reference.count == actual.count && zip(reference, actual).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                      "Orientation \(orientation) and P3-to-sRGB color conversion preserve visible pixels")
            try check(try Data(contentsOf: source) == original, "Stripping does not alter source metadata or bytes")
        }
        for (ext, type) in [("jpeg", UTType.jpeg.identifier), ("heic", UTType.heic.identifier)] {
            let source = sources.appendingPathComponent("private.\(ext)")
            try encode(image(80, 40), source, type: type, metadata: metadata)
            let original = try Data(contentsOf: source)
            let result = try await perform("stripMetadata", [source], output)[0]
            try check(result.pathExtension == ext, "Strip retains supported encoding \(ext)")
            try dimensions(result, 80, 40)
            let after = try properties(result)
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                try check(after[key] == nil, "Strip removes \(key) in \(ext)")
            }
            let outputImage = CGImageSourceCreateWithURL(result as CFURL, nil)!
            if let remaining = CGImageSourceCopyMetadataAtIndex(outputImage, 0, nil) {
                try check(CGImageMetadataCopyTagWithPath(remaining, nil, "dc:description" as CFString) == nil, "Strip removes XMP in \(ext)")
            }
            try check(try Data(contentsOf: source) == original, "Strip retains source bytes for \(ext)")
        }
    }

    private static func pdfAndOCR(_ sources: URL, _ output: URL) async throws {
        let text = "RELAY SHELF TEST 7429"
        let raster = try textImage(text)
        let imageURL = sources.appendingPathComponent("readable.png")
        try encode(raster, imageURL)
        let first = sources.appendingPathComponent("first.pdf")
        let second = sources.appendingPathComponent("second.pdf")
        try pdf(first, pages: [(CGRect(x: 12, y: 24, width: 550, height: 90), raster)])
        try pdf(second, pages: [(CGRect(x: 0, y: 0, width: 80, height: 40), try image(80, 40))])
        let edited = PDFDocument(url: second)!
        edited.page(at: 0)!.rotation = 90
        edited.page(at: 0)!.setBounds(CGRect(x: 10, y: 5, width: 60, height: 30), for: .cropBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 10, width: 10, height: 10), forType: .text, withProperties: nil)
        annotation.contents = "Keep annotation"
        edited.page(at: 0)!.addAnnotation(annotation)
        try check(edited.write(to: second), "Write rotated PDF fixture")
        let originals = try [Data(contentsOf: first), Data(contentsOf: second), Data(contentsOf: imageURL)]
        let merged = try await perform("mergePDF", [second, first], output)[0]
        let document = PDFDocument(url: merged)!
        try check(document.pageCount == 2, "Merge preserves page count")
        try check(document.page(at: 0)!.rotation == 90, "Merge preserves rotation and input order")
        try check(document.page(at: 0)!.bounds(for: .cropBox) == edited.page(at: 0)!.bounds(for: .cropBox), "Merge preserves crop box")
        try check(document.page(at: 0)!.annotations.first?.contents == "Keep annotation", "Merge preserves annotations")
        try check(document.page(at: 1)!.bounds(for: .mediaBox).size == PDFDocument(url: first)!.page(at: 0)!.bounds(for: .mediaBox).size, "Merge preserves page dimensions for nonzero source origins")
        try check(try pixels(renderedPage(first)) == pixels(renderedPage(merged, page: 2)), "Normalizing a page origin retains visible content and placement")

        let imagePDF = try await perform("imagesToPDF", [imageURL, sources.appendingPathComponent("alpha.png")], output)[0]
        let images = PDFDocument(url: imagePDF)!
        try check(images.pageCount == 2, "One image per PDF page")
        try check(images.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 1100, height: 180), "Image PDF uses natural image dimensions")
        try check(images.page(at: 1)!.bounds(for: .mediaBox).size == CGSize(width: 80, height: 40), "Image PDF preserves input order")
        let orientedPDF = try await perform("imagesToPDF", [sources.appendingPathComponent("orientation-6.tiff")], output)[0]
        try check(PDFDocument(url: orientedPDF)!.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 40, height: 80), "Image PDF dimensions apply orientation")

        let multi = sources.appendingPathComponent("multi.pdf")
        try pdf(multi, pages: [(CGRect(x: 12, y: 24, width: 550, height: 90), raster),
                               (CGRect(x: 0, y: 0, width: 550, height: 90), try textImage("SECOND PAGE 8152"))])
        let recognized = try await perform("ocr", [imageURL, first, multi, imagePDF], output)
        try check(recognized.count == 4 && recognized.allSatisfy { $0.pathExtension == "txt" }, "OCR writes one text file per source")
        for index in 0..<recognized.count {
            let value = try String(contentsOf: recognized[index], encoding: .utf8)
            try check(value.contains("RELAY") && value.contains("7429"), "Actual Vision OCR recognizes image/PDF text (source \(index)): \(value)")
        }
        let pageText = try String(contentsOf: recognized[2], encoding: .utf8)
        try check(pageText.contains("SECOND PAGE") && pageText.contains("\u{000C}"), "OCR preserves PDF page order and page boundaries")
        let blank = sources.appendingPathComponent("blank.png")
        let blankContext = try context(80, 40)
        blankContext.setFillColor(CGColor(gray: 1, alpha: 1))
        blankContext.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        try encode(blankContext.makeImage()!, blank)
        let blankText = try await perform("ocr", [blank], output)[0]
        try check(try String(contentsOf: blankText, encoding: .utf8).isEmpty, "Blank image produces valid empty UTF-8 text")
        try check(try [Data(contentsOf: first), Data(contentsOf: second), Data(contentsOf: imageURL)] == originals, "PDF and OCR leave all source bytes unchanged")
    }

    private static func invalidAndBounds(_ png: URL, _ sources: URL, _ output: URL) async throws {
        try await failure("unknown", [png], output, contains: "Unsupported")
        try await failure("resizeImage", [], output, contains: "Select")
        try await failure("resizeImage", Array(repeating: png, count: 101), output, contains: "100")
        for value: Any in [0, -1, 12.5, true, "100", Double.infinity, 32_769] {
            try await failure("resizeImage", [png], output, ["width": value], contains: "width")
        }
        try await failure("resizeImage", [png], output, ["height": false], contains: "height")
        try await failure("resizeImage", [png], output, ["preserveAspect": false], contains: "Unsupported option")
        try await failure("convertImage", [png], output, contains: "requires format")
        try await failure("convertImage", [png], output, ["format": "gif"], contains: "format")
        try await failure("convertImage", [png], output, ["format": 12], contains: "format")
        for value: Any in [0.09, 1.01, Double.nan, true, "0.5"] {
            try await failure("compressImage", [png], output, ["quality": value], contains: "quality")
        }
        try await failure("stripMetadata", [png], output, ["format": "png"], contains: "Unsupported option")
        try await failure("resizeImage", [png, sources.appendingPathComponent("missing.png")], output, contains: "Cannot read source")
        try await failure("ocr", [URL(string: "https://example.com/a.png")!], output, contains: "local")
        try await failure("resizeImage", [sources], output, contains: "regular file")
        let invalid = sources.appendingPathComponent("not-an-image.png")
        try Data("plain text, not a PNG".utf8).write(to: invalid)
        try await failure("resizeImage", [png, invalid], output, contains: "image")
        try await failure("mergePDF", [png], output, contains: "PDF")
        try await failure("imagesToPDF", [sources.appendingPathComponent("first.pdf")], output, contains: "image")
        let empty = sources.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        try await failure("stripMetadata", [empty], output, contains: "empty")
        let large = sources.appendingPathComponent("101-pages.pdf")
        try pdf(large, pages: Array(repeating: (CGRect(x: 0, y: 0, width: 10, height: 10), nil), count: 101))
        try await failure("ocr", [large], output, contains: "100-page")
        try await failure("mergePDF", [large], output, contains: "100-page")
        let fiftyOne = sources.appendingPathComponent("51-pages.pdf")
        try pdf(fiftyOne, pages: Array(repeating: (CGRect(x: 0, y: 0, width: 10, height: 10), nil), count: 51))
        try await failure("mergePDF", [fiftyOne, fiftyOne], output, contains: "100-page")
        let hugePage = sources.appendingPathComponent("huge-page.pdf")
        try pdf(hugePage, pages: [(CGRect(x: 0, y: 0, width: 15_000, height: 10), nil)])
        try await failure("ocr", [hugePage], output, contains: "dimension limit")
        let sparse = sources.appendingPathComponent("large.bin")
        try Data([0]).write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 256 * 1_024 * 1_024 + 1)
        try handle.close()
        try await failure("resizeImage", [sparse], output, contains: "256 MiB")
        try FileManager.default.removeItem(at: sparse)

        // A genuine 25-megapixel, one-bit grayscale image uses only ~3 MiB
        // of fixture memory; full RGBA decoding must be rejected up front.
        let oversized = sources.appendingPathComponent("oversized.png")
        let provider = CGDataProvider(data: Data(repeating: 0, count: 625 * 5000) as CFData)!
        let largeImage = CGImage(width: 5000, height: 5000, bitsPerComponent: 1, bitsPerPixel: 1,
                                 bytesPerRow: 625, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                 decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try encode(largeImage, oversized)
        try await failure("stripMetadata", [oversized], output, contains: "16-megapixel")
        let downsized = try await perform("resizeImage", [oversized], output)[0]
        try dimensions(downsized, 1600, 1600)

        let corrupt = sources.appendingPathComponent("truncated.png")
        let bytes = try Data(contentsOf: png)
        try bytes.prefix(max(50, bytes.count / 2)).write(to: corrupt)
        try await failure("convertImage", [png, corrupt], output, ["format": "png"])
        let missingOutput = sources.appendingPathComponent("should-not-be-created", isDirectory: true)
        do {
            _ = try await perform("ocr", [invalid], missingOutput)
            throw TestFailure(description: "Invalid source accepted")
        } catch let error as TestFailure { throw error } catch {}
        try check(!FileManager.default.fileExists(atPath: missingOutput.path), "Validation precedes output directory creation")
        do {
            _ = try await perform("resizeImage", [png], invalid)
            throw TestFailure(description: "File accepted as output directory")
        } catch let error as TestFailure { throw error } catch {}
        try check(try String(contentsOf: invalid, encoding: .utf8) == "plain text, not a PNG", "Bad output destination remains unchanged")
    }

    private static func cancellation(_ png: URL, _ sources: URL, _ output: URL) async throws {
        let before = try contents(output)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await perform("resizeImage", [png], output)
        }
        do {
            _ = try await cancelled.value
            throw TestFailure(description: "Pre-cancelled operation succeeded")
        } catch is CancellationError { assertions += 1 }
        try check(try contents(output) == before, "Pre-cancellation creates no output")

        let text = sources.appendingPathComponent("readable.png")
        let task = Task { try await perform("ocr", Array(repeating: text, count: 100), output) }
        let deadline = Date().addingTimeInterval(10)
        var started = false
        while Date() < deadline {
            if try contents(output).contains(where: { $0.hasPrefix(".RelayShelf-actions-") }) { started = true; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            throw TestFailure(description: "In-flight cancellation succeeded unexpectedly")
        } catch is CancellationError { assertions += 1 }
        try check(started, "Cancellation test reaches processing after preflight")
        try check(Date().timeIntervalSince(cancelledAt) < 5, "Active OCR cancellation returns promptly")
        try check(try contents(output) == before, "In-flight cancellation rolls back all partial outputs")
        print("PASS pre-cancellation and cancellation during OCR with rollback")
    }
}
