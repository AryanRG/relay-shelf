import AppKit
import Darwin
import UniformTypeIdentifiers
import WebKit

/// Independent of WebKit so byte limits, encodings, and link policy can be tested directly.
enum MarkdownViewerSupport {
  static let byteLimit = 2 * 1024 * 1024
  static let imageByteLimit = 20 * 1024 * 1024

  struct Document: Sendable {
    let name: String
    let path: String
    let text: String
    let truncated: Bool
    let modifiedAt: String

    var payload: [String: Any] {
      ["name": name, "path": path, "text": text, "truncated": truncated,
       "modifiedAt": modifiedAt]
    }
  }

  enum Link: Equatable, Sendable {
    case anchor(String)
    case external(URL)
    case local(URL)
  }

  static func localFile(_ url: URL) -> Bool {
    url.isFileURL && [nil, "", "localhost"].contains(url.host?.lowercased())
      && url.user == nil && url.password == nil && url.port == nil
      && !url.path.contains("\0")
  }

  static func fileURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.path).standardizedFileURL
  }

  static func isEntry(_ candidate: URL, entry: URL) -> Bool {
    // Do not authorize remote file hosts, sibling pages, queries, or subframes.
    localFile(candidate) && candidate.query == nil
      && candidate.standardizedFileURL.path == entry.standardizedFileURL.path
  }

  /// Validate the panel selection without filesystem I/O: resolving symlinks or checking
  /// metadata here could itself wait on the macOS permission request being recovered.
  static func accessScope(_ chosen: URL, covers document: URL) -> Bool {
    guard localFile(chosen), localFile(document), chosen.query == nil,
      chosen.fragment == nil else { return false }
    let selected = fileURL(chosen).pathComponents
    let requested = fileURL(document).pathComponents
    return requested.starts(with: selected)
  }

  static func link(_ href: String, document: URL) throws -> Link {
    guard !href.isEmpty, href.utf8.count <= 16_384,
      !href.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !href.hasPrefix("//"), !href.contains("\\"),
      let components = URLComponents(string: href)
    else { throw RelayFailure(message: "This link is not a supported local or web location.") }
    if href.hasPrefix("#") {
      return .anchor(components.fragment ?? "")
    }
    if let scheme = components.scheme?.lowercased() {
      if ["http", "https"].contains(scheme),
        let url = components.url, let host = url.host, !host.isEmpty,
        url.user == nil, url.password == nil {
        return .external(url)
      }
      guard scheme == "file", let url = components.url, localFile(url),
        !components.percentEncodedPath.isEmpty
      else { throw RelayFailure(message: "This link scheme is blocked.") }
      var resolved = URLComponents(url: fileURL(url), resolvingAgainstBaseURL: false)!
      resolved.percentEncodedFragment = components.percentEncodedFragment
      resolved.percentEncodedQuery = components.percentEncodedQuery
      guard let target = resolved.url else { throw RelayFailure(message: "This local link is invalid.") }
      return .local(target)
    }
    guard components.host == nil, !components.percentEncodedPath.isEmpty,
      let path = components.percentEncodedPath.removingPercentEncoding,
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !path.contains("//"), !path.contains("\\")
    else { throw RelayFailure(message: "This local link is invalid.") }
    let target = path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : fileURL(document).deletingLastPathComponent().appendingPathComponent(path)
    var resolved = URLComponents(url: target.standardizedFileURL, resolvingAgainstBaseURL: false)!
    resolved.percentEncodedFragment = components.percentEncodedFragment
    resolved.percentEncodedQuery = components.percentEncodedQuery
    guard let url = resolved.url else { throw RelayFailure(message: "This local link is invalid.") }
    return .local(url)
  }

  static func read(_ url: URL) throws -> Document {
    guard localFile(url) else { throw RelayFailure(message: "Choose a local Markdown document.") }
    // NONBLOCK avoids hanging on FIFOs and device paths before fstat can reject them.
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw RelayFailure(message: "Markdown reading requires a regular file.")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= byteLimit {
      try Task.checkCancellation()
      let count = min(buffer.count, byteLimit + 1 - data.count)
      let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
      if received == 0 { break }
      if received < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      data.append(contentsOf: buffer.prefix(received))
    }
    let truncated = data.count > byteLimit || info.st_size > byteLimit
    try Task.checkCancellation()
    let text = try decode(Data(data.prefix(byteLimit)), truncated: truncated)
    let modified = Date(timeIntervalSince1970:
      Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    return Document(name: url.lastPathComponent, path: fileURL(url).path, text: text,
      truncated: truncated, modifiedAt: modified.ISO8601Format())
  }

  static func decode(_ input: Data, truncated: Bool) throws -> String {
    var data = input
    var encoding = String.Encoding.utf8
    if data.starts(with: [0xFF, 0xFE]) {
      encoding = .utf16LittleEndian; data.removeFirst(2)
    } else if data.starts(with: [0xFE, 0xFF]) {
      encoding = .utf16BigEndian; data.removeFirst(2)
    } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      data.removeFirst(3)
    } else {
      // Recognize BOM-less UTF-16 ASCII Markdown while rejecting ordinary binary NULs.
      let sample = Array(data.prefix(4096))
      let pairs = sample.count / 2
      if pairs > 0 {
        let evenNULs = (0..<pairs).filter { sample[$0 * 2] == 0 }.count
        let oddNULs = (0..<pairs).filter { sample[$0 * 2 + 1] == 0 }.count
        if oddNULs * 2 > pairs && evenNULs == 0 { encoding = .utf16LittleEndian }
        else if evenNULs * 2 > pairs && oddNULs == 0 { encoding = .utf16BigEndian }
      }
    }
    if encoding != .utf8 {
      if data.count % 2 != 0 {
        guard truncated else { throw RelayFailure(message: "The UTF-16 document is incomplete.") }
        data.removeLast()
      }
      if truncated, data.count >= 2 {
        let bytes = Array(data.suffix(2))
        let last = encoding == .utf16LittleEndian
          ? UInt16(bytes[0]) | UInt16(bytes[1]) << 8 : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        if (0xD800...0xDBFF).contains(last) { data.removeLast(2) }
      }
    } else if truncated {
      // Drop only an incomplete final UTF-8 scalar, never repair malformed interior bytes.
      for length in 1...3 where data.count >= length {
        let tail = Array(data.suffix(length))
        let expected = tail[0] >= 0xF0 && tail[0] <= 0xF4 ? 4
          : tail[0] >= 0xE0 && tail[0] <= 0xEF ? 3
          : tail[0] >= 0xC2 && tail[0] <= 0xDF ? 2 : 0
        if expected > length && tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) {
          data.removeLast(length); break
        }
      }
    }
    guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
      throw RelayFailure(message: "This document is not valid UTF-8 or UTF-16 text.")
    }
    return text
  }

  static func validateImage(_ url: URL) throws {
    let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard metadata.isRegularFile == true, let size = metadata.fileSize,
      size > 0, size <= imageByteLimit,
      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image)
    else { throw RelayFailure(message: "Image previews require an image file of at most 20 MiB.") }
  }
}

/// Timed-out/cancelled work retains its slot until the actual OS read finishes. A stalled
/// filesystem therefore cannot spawn an unbounded number of detached readers.
@MainActor
final class MarkdownViewerFileIO {
  static let shared = MarkdownViewerFileIO()
  private(set) var activeCount = 0
  private let limit: Int
  init(limit: Int = 4) { self.limit = limit }

  private final class Completion<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var cancelWorker: (() -> Void)?
    func finish(_ result: Result<Value, Error>) {
      let pending = continuation
      continuation = nil
      cancelWorker = nil
      pending?.resume(with: result)
    }
    func cancel(_ error: Error) {
      cancelWorker?()
      finish(.failure(error))
    }
  }

  func run<Value: Sendable>(timeout: UInt64 = 5_000_000_000,
    _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    guard activeCount < limit else {
      throw RelayFailure(message:
        "File access is waiting on macOS. Choose the document or its containing folder to allow access, then retry.")
    }
    activeCount += 1
    let completion = Completion<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        completion.continuation = continuation
        let worker = Task.detached(priority: .userInitiated) { Result { try operation() } }
        completion.cancelWorker = { worker.cancel() }
        let deadline = Task {
          do { try await Task.sleep(nanoseconds: timeout) } catch { return }
          completion.cancel(RelayFailure(message:
            "File access timed out. Choose the document or its containing folder to allow macOS access, then retry."))
        }
        Task {
          let result = await worker.value
          self.activeCount -= 1
          deadline.cancel()
          completion.finish(result)
        }
        if Task.isCancelled { completion.cancel(CancellationError()) }
      }
    } onCancel: {
      Task { @MainActor in completion.cancel(CancellationError()) }
    }
  }
}

/// Both vnodes are observed. Parent writes reconnect the document vnode after atomic
/// replacement or deletion/recreation. There are no periodic scans or retry timers.
final class MarkdownViewerWatcher: @unchecked Sendable {
  private struct Fingerprint: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
  }
  private let queue = DispatchQueue(label: "local.aryan.relay.markdown-watch", qos: .utility)
  private let url: URL
  private let changed: @MainActor @Sendable () -> Void
  private var sources: [DispatchSourceFileSystemObject] = []
  private var debounce: DispatchWorkItem?
  private var stopped = false
  private var fingerprint: Fingerprint?
  private var fileEventPending = false

  private func currentFingerprint() -> Fingerprint? {
    var info = stat()
    guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
    return Fingerprint(device: info.st_dev, inode: info.st_ino, size: info.st_size,
      modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec)
  }

  init(url: URL, changed: @escaping @MainActor @Sendable () -> Void) {
    self.url = MarkdownViewerSupport.fileURL(url)
    self.changed = changed
    queue.async { [weak self] in self?.reconnect() }
  }

  private func reconnect() {
    guard !stopped else { return }
    let oldSources = sources
    sources = []
    for path in [url.path, url.deletingLastPathComponent().path] {
      let isDocument = path == url.path
      let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
      source.setEventHandler { [weak self] in self?.scheduleChange(fileEvent: isDocument) }
      source.setCancelHandler { Darwin.close(descriptor) }
      sources.append(source)
      source.resume()
    }
    fingerprint = currentFingerprint()
    oldSources.forEach { $0.cancel() }
  }

  private func scheduleChange(fileEvent: Bool) {
    guard !stopped else { return }
    fileEventPending = fileEventPending || fileEvent
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped else { return }
      self.debounce = nil
      let changed = self.fileEventPending || self.currentFingerprint() != self.fingerprint
      self.fileEventPending = false
      guard changed else { return }
      self.reconnect()
      let callback = self.changed
      Task { @MainActor in callback() }
    }
    debounce = work
    queue.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
  }

  func stop() {
    queue.async { [self] in
      stopped = true
      debounce?.cancel(); debounce = nil
      sources.forEach { $0.cancel() }; sources.removeAll()
    }
  }

  deinit {
    debounce?.cancel()
    sources.forEach { $0.cancel() }
  }
}

/// Retain the original panel URL, including its access token, and balance only successful
/// scope starts. This also releases access if a controller is discarded without closing.
private final class MarkdownViewerAccessScope {
  private let url: URL
  init?(_ url: URL) {
    guard url.startAccessingSecurityScopedResource() else { return nil }
    self.url = url
  }
  deinit { url.stopAccessingSecurityScopedResource() }
}

@MainActor
final class MarkdownViewerController: NSObject, NSWindowDelegate, WKNavigationDelegate,
  WKUIDelegate, WKScriptMessageHandler {
  public let url: URL
  public let window: NSWindow
  private let entryURL: URL
  private let store: ShelfStore
  private let showShelf: () -> Void
  private let openMarkdown: (URL) -> Void
  private var onClose: (() -> Void)?
  private(set) var webView: WKWebView?
  private var watcher: MarkdownViewerWatcher?
  private var tasks: [String: Task<Void, Never>] = [:]
  private var loadTask: Task<Void, Never>?
  private var closed = false
  private var ready = false
  private var pendingChange = false
  private var anchor: String?
  private var pendingAnchor: String?
  private var exporting = false
  private var choosingAccess = false
  private var accessScopes: [String: MarkdownViewerAccessScope] = [:]

  init(url: URL, entryURL: URL, store: ShelfStore, showShelf: @escaping () -> Void,
    openMarkdown: @escaping (URL) -> Void, onClose: @escaping () -> Void) throws {
    guard MarkdownViewerSupport.localFile(url), MarkdownSupport.isMarkdown(url),
      MarkdownViewerSupport.localFile(entryURL) else {
      throw RelayFailure(message: "Choose a local .md or .markdown document.")
    }
    self.url = MarkdownViewerSupport.fileURL(url)
    self.entryURL = MarkdownViewerSupport.fileURL(entryURL)
    self.store = store
    self.showShelf = showShelf
    self.openMarkdown = openMarkdown
    self.onClose = onClose
    self.anchor = url.fragment.map { $0.removingPercentEncoding ?? $0 }
    self.pendingAnchor = self.anchor
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = self.url.lastPathComponent
    window.representedURL = self.url
    window.level = .normal
    window.contentMinSize = NSSize(width: 560, height: 380)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.center()

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.add(MarkdownViewerScriptHandler(delegate: self), name: "relay")
    configuration.userContentController.addUserScript(WKUserScript(
      source: "window.__relayMarkdownViewer=true;", injectionTime: .atDocumentStart,
      forMainFrameOnly: true))
    configuration.userContentController.addUserScript(WKUserScript(
      source: RelayAppDelegate.bridgeScript(for: self.entryURL), injectionTime: .atDocumentStart,
      forMainFrameOnly: true))
    configuration.setURLSchemeHandler(RelayResourceHandler(store: store), forURLScheme: "relay-file")
    let view = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
    view.navigationDelegate = self
    view.uiDelegate = self
    view.autoresizingMask = [.width, .height]
    view.allowsBackForwardNavigationGestures = false
    view.setAccessibilityLabel("Markdown document: \(self.url.lastPathComponent)")
    window.contentView = view
    webView = view
    watcher = MarkdownViewerWatcher(url: self.url) { [weak self] in self?.documentChanged() }

    // Install a network block before loading any renderer code. Even a raw <img> in a
    // document cannot issue a remote request; local previews travel through markdownImage.
    loadTask = Task { [weak self] in
      do {
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
          forIdentifier: "RelayMarkdownNoNetwork-v1",
          encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#)
        guard !Task.isCancelled, let self, !self.closed, let rules else { return }
        self.webView?.configuration.userContentController.add(rules)
        self.webView?.loadFileURL(self.entryURL,
          allowingReadAccessTo: self.entryURL.deletingLastPathComponent())
      } catch {
        guard let self, !self.closed else { return }
        let label = NSTextField(wrappingLabelWithString:
          "The Markdown interface could not load safely. Close this window and try again.")
        label.frame = NSRect(x: 24, y: 24, width: 500, height: 80)
        self.window.contentView?.addSubview(label)
      }
    }
  }

  func show() {
    guard !closed else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  public func navigateToAnchor(_ anchor: String) {
    guard !closed, anchor.utf8.count <= 16_384 else { return }
    let decoded = anchor.removingPercentEncoding ?? anchor
    self.anchor = decoded
    pendingAnchor = decoded
    if ready { dispatchAnchor() }
  }

  func windowWillClose(_ notification: Notification) {
    guard !closed else { return }
    closed = true
    loadTask?.cancel(); loadTask = nil
    tasks.values.forEach { $0.cancel() }; tasks.removeAll()
    watcher?.stop(); watcher = nil
    accessScopes.removeAll()
    for sheet in window.sheets { window.endSheet(sheet, returnCode: .cancel) }
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "relay")
    webView?.configuration.userContentController.removeAllUserScripts()
    webView?.configuration.userContentController.removeAllContentRuleLists()
    window.contentView = nil
    webView = nil
    window.delegate = nil
    let callback = onClose
    onClose = nil
    callback?()
  }

  private func ensureOpen() throws {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
  }

  // Internal for native integration tests; all callers still pass through this whitelist.
  func handle(_ command: String, payload: [String: Any]) async throws -> Any {
    try ensureOpen()
    switch command {
    case "markdownChooseAccess": return try await chooseAccess()
    case "markdownDocument":
      let location = url
      let document = try await MarkdownViewerFileIO.shared.run { try MarkdownViewerSupport.read(location) }
      try ensureOpen()
      var payload = document.payload
      if let anchor { payload["anchor"] = anchor }
      return payload
    case "markdownImage":
      guard let source = payload["source"] as? String,
        case .local(let target) = try MarkdownViewerSupport.link(source, document: url) else { return [:] }
      let location = MarkdownViewerSupport.fileURL(target)
      try await MarkdownViewerFileIO.shared.run { try MarkdownViewerSupport.validateImage(location) }
      try ensureOpen()
      let resolved = try await resolve(location)
      let preview = try await store.handle("preview", payload: ["path": resolved.path]) as? [String: Any]
      try ensureOpen()
      guard preview?["type"] as? String == "image", let result = preview?["url"] as? String,
        result.hasPrefix("data:image/png;base64,"), result.utf8.count <= 16 * 1024 * 1024 else { return [:] }
      return ["url": result]
    case "markdownOpenLink":
      guard let href = payload["href"] as? String else {
        throw RelayFailure(message: "A link location is required.")
      }
      switch try MarkdownViewerSupport.link(href, document: url) {
      case .anchor(let anchor):
        self.anchor = anchor
        pendingAnchor = anchor
        if ready { dispatchAnchor() }
      case .external(let target):
        guard NSWorkspace.shared.open(target) else { throw RelayFailure(message: "Could not open this link.") }
      case .local(let target):
        let resolved = try await resolve(MarkdownViewerSupport.fileURL(target))
        try ensureOpen()
        if MarkdownSupport.isMarkdown(resolved) {
          var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false)!
          parts.percentEncodedFragment = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedFragment
          openMarkdown(parts.url ?? resolved)
        } else if !NSWorkspace.shared.open(resolved) {
          throw RelayFailure(message: "Could not open this file.")
        }
      }
    case "markdownCopy":
      let value: String
      switch payload["kind"] as? String {
      case "path": value = url.path
      case "source":
        let location = url
        let document = try await MarkdownViewerFileIO.shared.run { try MarkdownViewerSupport.read(location) }
        try ensureOpen()
        guard !document.truncated else {
          throw RelayFailure(message: "This document exceeds 2 MiB. Open it in an editor to copy the complete source.")
        }
        value = document.text
      default: throw RelayFailure(message: "Choose source or path to copy.")
      }
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(value, forType: .string) else {
        throw RelayFailure(message: "Could not copy to the clipboard.")
      }
    case "markdownReveal": NSWorkspace.shared.activateFileViewerSelecting([url])
    case "markdownOpenShelf": showShelf()
    case "markdownExportPDF": return try await exportPDF(payload)
    case "markdownMakeDefault":
      try await MarkdownSupport.makeDefault(applicationURL: Bundle.main.bundleURL)
    case "markdownOpenInEditor":
      guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
        throw RelayFailure(message: "TextEdit is not available.")
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: configuration)
    default: throw RelayFailure(message: "This command is not available in a Markdown window.")
    }
    return NSNull()
  }

  private func chooseAccess() async throws -> Bool {
    guard !choosingAccess, window.attachedSheet == nil else {
      throw RelayFailure(message: "Finish or cancel the current file dialog first.")
    }
    choosingAccess = true
    defer { choosingAccess = false }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = url.deletingLastPathComponent()
    panel.message = "Choose \(url.lastPathComponent) to allow reading, or its containing folder to also allow linked documents and images."
    panel.prompt = "Allow Access"
    guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
    try ensureOpen()
    guard MarkdownViewerSupport.accessScope(chosen, covers: url) else {
      throw RelayFailure(message: "Choose this document or a folder containing it.")
    }
    let key = MarkdownViewerSupport.fileURL(chosen).path
    if accessScopes[key] == nil, let scope = MarkdownViewerAccessScope(chosen) {
      accessScopes[key] = scope
    }
    // A non-sandboxed app may receive its TCC grant from the panel even when starting a
    // security scope returns false. Do not probe the file or enter a saturated reader pool
    // here; the explicit refresh retries normal bounded reads after the panel has granted access.
    documentChanged()
    return true
  }

  private func resolve(_ location: URL) async throws -> URL {
    let entries = try await store.handle("resolve", payload: ["text": location.absoluteString]) as? [[String: Any]] ?? []
    try ensureOpen()
    guard let entry = entries.first, entries.count == 1, entry["exists"] as? Bool == true,
      let path = entry["path"] as? String, path == location.path else {
      throw RelayFailure(message: "This local file could not be resolved.")
    }
    return URL(fileURLWithPath: path)
  }

  private func exportPDF(_ payload: [String: Any]) async throws -> [String: Any] {
    guard !exporting else { throw RelayFailure(message: "Finish the current PDF export first.") }
    guard let html = payload["html"] as? String, html.utf8.count <= 2_000_000 else {
      throw RelayFailure(message: "The rendered document exceeds the PDF export limit.")
    }
    exporting = true
    defer { exporting = false }
    let location = url
    let document = try await MarkdownViewerFileIO.shared.run { try MarkdownViewerSupport.read(location) }
    try ensureOpen()
    guard !document.truncated else {
      throw RelayFailure(message: "This document exceeds 2 MiB. Open it in an editor to export the complete document.")
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
    guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return [:] }
    try ensureOpen()
    try await DocumentPDFExporter().export(html: html, to: destination)
    try ensureOpen()
    return ["path": destination.path]
  }

  func userContentController(_ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage) {
    guard !closed, message.webView === webView, message.name == "relay",
      message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "file",
      ["", "localhost"].contains(message.frameInfo.securityOrigin.host.lowercased()),
      let source = message.frameInfo.request.url, MarkdownViewerSupport.isEntry(source, entry: entryURL),
      let current = webView?.url, MarkdownViewerSupport.isEntry(current, entry: entryURL),
      let body = message.body as? [String: Any], body["kind"] as? String == "invoke",
      let id = body["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
      let command = body["command"] as? String, command.utf8.count <= 128,
      tasks[id] == nil else { return }
    guard tasks.count < 32 else {
      send(["kind": "reply", "id": id, "error": "Too many pending Markdown requests."])
      return
    }
    let payload = body["payload"] as? [String: Any] ?? [:]
    tasks[id] = Task { [weak self] in
      guard let self else { return }
      defer { self.tasks.removeValue(forKey: id) }
      do {
        let value = try await self.handle(command, payload: payload)
        try self.ensureOpen()
        self.send(["kind": "reply", "id": id, "value": value])
      } catch {
        self.send(["kind": "reply", "id": id, "error": error.localizedDescription])
      }
    }
  }

  private func send(_ message: [String: Any]) {
    guard !closed, let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8) else { return }
    webView?.callAsyncJavaScript("window.__relayReceive(JSON.parse(json))",
      arguments: ["json": json], in: nil, in: .page) { _ in }
  }

  private func documentChanged() {
    guard !closed else { return }
    pendingChange = true
    if ready { dispatchChange() }
  }

  private func dispatchChange() {
    pendingChange = false
    webView?.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('relay-markdown-changed'))",
      arguments: [:], in: nil, in: .page) { _ in }
  }

  private func dispatchAnchor() {
    guard let anchor = pendingAnchor else { return }
    pendingAnchor = nil
    webView?.callAsyncJavaScript(
      "window.dispatchEvent(new CustomEvent('relay-markdown-anchor', {detail: anchor}))",
      arguments: ["anchor": anchor], in: nil, in: .page) { _ in }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard !closed, let target = navigationAction.request.url,
      navigationAction.targetFrame?.isMainFrame == true,
      MarkdownViewerSupport.isEntry(target, entry: entryURL) else {
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { ready = false }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !closed else { return }
    ready = true
    if pendingChange { dispatchChange() }
    dispatchAnchor()
  }
}

@MainActor
private final class MarkdownViewerScriptHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: MarkdownViewerController?
  init(delegate: MarkdownViewerController) { self.delegate = delegate }
  func userContentController(_ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage) {
    delegate?.userContentController(userContentController, didReceive: message)
  }
}
