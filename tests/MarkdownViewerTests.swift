import AppKit
import Darwin
import Foundation
import WebKit

@main
@MainActor
struct MarkdownViewerTests {
  private static var assertions = 0
  private final class Weak<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
  }

  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RelayMarkdownTests-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try readers(root)
        try links(root)
        try accessScopes(root)
        try await boundedIO()
        try await watching(root)
        try await controller(root)
        print("PASS MarkdownViewerTests (\(assertions) assertions): bounded UTF-8/16 reads, link policy, timeout/concurrency, vnode replacement, authenticated WebKit bridge, command isolation, and close cleanup")
        exit(0)
      } catch {
        fputs("MarkdownViewerTests failed: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
    application.run()
  }

  private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !condition() { throw RelayFailure(message: message) }
  }

  private static func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { assertions += 1; return }
    throw RelayFailure(message: "Expected rejection: \(message)")
  }

  private static func rejectsAsync(_ message: String, _ body: () async throws -> Void) async throws {
    do { try await body() } catch { assertions += 1; return }
    throw RelayFailure(message: "Expected rejection: \(message)")
  }

  private static func wait(_ message: String, _ predicate: () async throws -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(8))
    while ContinuousClock.now < until {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw RelayFailure(message: "Timed out waiting for \(message)")
  }

  private static func readers(_ root: URL) throws {
    let file = root.appendingPathComponent("reader.md")
    func read(_ data: Data) throws -> MarkdownViewerSupport.Document {
      try data.write(to: file)
      return try MarkdownViewerSupport.read(file)
    }
    let text = "# Hello\nUnicode: 🦊 café 日本語\n"
    let first = try read(Data(text.utf8))
    try require(first.text == text && !first.truncated, "Complete UTF-8 content")
    try require(first.name == "reader.md" && first.path == file.path, "Document identity")
    try require(ISO8601DateFormatter().date(from: first.modifiedAt) != nil, "ISO modification time")
    try require(Set(first.payload.keys) == ["name", "path", "text", "truncated", "modifiedAt"], "Document schema")
    try require(try read(Data()).text.isEmpty, "Empty document")
    try require(try read(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).text == text, "UTF-8 BOM")
    try require(try read(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).text == text, "UTF-16 LE BOM")
    try require(try read(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!).text == text, "UTF-16 BE BOM")
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      try require(try read("# Plain Markdown\n".data(using: encoding)!).text == "# Plain Markdown\n", "BOM-less UTF-16")
    }
    let limit = MarkdownViewerSupport.byteLimit
    let exact = try read(Data(repeating: 0x61, count: limit))
    try require(exact.text.utf8.count == limit && !exact.truncated, "Exactly 2 MiB is complete")
    let large = try read(Data(repeating: 0x61, count: limit + 1))
    try require(large.text.utf8.count == limit && large.truncated, "One byte over limit is honestly truncated")
    for offset in 1...3 {
      let prefix = Data(repeating: 0x61, count: limit - offset)
      let document = try read(prefix + Data("🦊end".utf8))
      try require(document.truncated && document.text.utf8.count == limit - offset,
        "Truncated UTF-8 scalar drops only incomplete bytes \(offset)")
      try require(!document.text.contains("�"), "No replacement characters at truncation")
    }
    let utf16Prefix = String(repeating: "a", count: (limit - 4) / 2)
    let le = Data([0xFF, 0xFE]) + (utf16Prefix + "🦊z").data(using: .utf16LittleEndian)!
    let utf16 = try read(le)
    try require(utf16.truncated && utf16.text == utf16Prefix, "Trim incomplete UTF-16 surrogate pair")
    try require(try MarkdownViewerSupport.decode(Data([0xFF, 0xFE, 0x61, 0, 0x62]), truncated: true) == "a", "Trim partial UTF-16 code unit")
    for invalid in [Data([0x61, 0, 0x62]), Data([0xC0, 0xAF]), Data([0xFF, 0xFE, 0x61]),
      Data([0xFF, 0xFE, 0, 0xD8]), Data([0x61, 0xFF, 0x62])] {
      try rejects("invalid or binary document") { _ = try read(invalid) }
    }
    try rejects("invalid interior UTF-8 with truncated tail") {
      _ = try MarkdownViewerSupport.decode(Data([0xFF, 0x61, 0xF0]), truncated: true)
    }
    try rejects("directory") { _ = try MarkdownViewerSupport.read(root) }
    try rejects("missing document") { _ = try MarkdownViewerSupport.read(root.appendingPathComponent("absent.md")) }
    try rejects("remote document") { _ = try MarkdownViewerSupport.read(URL(string: "https://example.com/a.md")!) }
    let fifo = root.appendingPathComponent("pipe.md")
    try require(mkfifo(fifo.path, 0o600) == 0, "Create FIFO fixture")
    let start = ContinuousClock.now
    try rejects("FIFO") { _ = try MarkdownViewerSupport.read(fifo) }
    try require(ContinuousClock.now - start < .seconds(1), "FIFO rejected without blocking")
  }

  private static func links(_ root: URL) throws {
    let document = root.appendingPathComponent("folder/README.md")
    let cases: [(String, URL)] = [
      ("other%20notes.md#part%202", root.appendingPathComponent("folder/other notes.md#unused")),
      ("../other.md", root.appendingPathComponent("other.md")),
      ("./literal%23name.md#title", root.appendingPathComponent("folder/literal#name.md")),
      ("./percent%2520.md", root.appendingPathComponent("folder/percent%20.md")),
      ("two words.md", root.appendingPathComponent("folder/two words.md")),
      ("./a%3Fb.md?ignored=yes#section", root.appendingPathComponent("folder/a?b.md")),
    ]
    for (reference, expected) in cases {
      guard case .local(let result) = try MarkdownViewerSupport.link(reference, document: document) else {
        throw RelayFailure(message: "Expected local URL for \(reference)")
      }
      if reference.hasPrefix("other") {
        try require(result.path == root.appendingPathComponent("folder/other notes.md").path, "Percent-encoded spaces")
        try require(result.fragment?.removingPercentEncoding == "part 2", "Keep encoded anchor")
      } else { try require(result.path == expected.path, "Relative URL resolution: \(reference)") }
    }
    try require(try MarkdownViewerSupport.link("#part%202", document: document) == .anchor("part 2"), "Same-document anchor")
    for reference in ["https://example.com/a.md#title", "http://example.com"] {
      guard case .external(let result) = try MarkdownViewerSupport.link(reference, document: document) else {
        throw RelayFailure(message: "Expected explicit web link")
      }
      try require(result.absoluteString == reference, "Explicit HTTP(S) links")
    }
    let anchoredFile = URL(string: "file:///tmp/other.md#target")!
    try require(try MarkdownViewerSupport.link(anchoredFile.absoluteString, document: document) == .local(anchoredFile), "Absolute file links retain anchors")
    let local = root.appendingPathComponent("local # name.md")
    try require(try MarkdownViewerSupport.link(local.absoluteString, document: document) == .local(local), "File URL escaping")
    if case .local(let anchored) = try MarkdownViewerSupport.link(local.absoluteString + "#part%202", document: document) {
      try require(anchored.fragment?.removingPercentEncoding == "part 2", "Absolute file URL retains anchor")
    } else { throw RelayFailure(message: "Expected anchored local file URL") }
    for reference in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "shell:echo", "data:text/html,hello",
      "mailto:a@example.com", "tel:123", "relay-file://preview/token", "x-custom:payload",
      "file://remote/tmp/a.md", "file://user@localhost/tmp/a.md", "file://localhost:80/tmp/a.md",
      "//example.com/a.md", "\\\\server\\file.md", "https://user:secret@example.com/a",
      "https:///", "https://", "\nhttps://example.com", "./bad%00name.md", "./%2F%2Fhost/share.md",
      "", String(repeating: "a", count: 16_385)] {
      try rejects("blocked link: \(reference.prefix(60))") { _ = try MarkdownViewerSupport.link(reference, document: document) }
    }
    let entry = root.appendingPathComponent("web/index.html")
    try require(MarkdownViewerSupport.isEntry(entry, entry: entry), "Exact bundled entry")
    try require(MarkdownViewerSupport.isEntry(URL(string: entry.absoluteString + "#heading")!, entry: entry), "Entry anchor")
    for candidate in [URL(string: entry.absoluteString + "?page=other")!,
      root.appendingPathComponent("web/other.html"), URL(string: "file://evil" + entry.path)!,
      URL(string: "https://localhost" + entry.path)!] {
      try require(!MarkdownViewerSupport.isEntry(candidate, entry: entry), "Reject unauthenticated entry")
    }
  }

  private static func boundedIO() async throws {
    let pool = MarkdownViewerFileIO(limit: 1)
    let gate = DispatchSemaphore(value: 0)
    let began = ContinuousClock.now
    try await rejectsAsync("bounded timeout") {
      let _: Int = try await pool.run(timeout: 25_000_000) { gate.wait(); return 7 }
    }
    try require(ContinuousClock.now - began < .seconds(1), "Timeout returns promptly")
    try require(pool.activeCount == 1, "Timed-out reader retains concurrency slot")
    try await rejectsAsync("concurrency limit") { let _: Int = try await pool.run { 9 } }
    gate.signal()
    try await wait("timed-out worker cleanup") { pool.activeCount == 0 }
    let success: Int = try await pool.run { 42 }
    try require(success == 42 && pool.activeCount == 0, "Reader slot reused after actual completion")
    let cancellationGate = DispatchSemaphore(value: 0)
    let task = Task { try await pool.run { cancellationGate.wait(); return 3 } }
    try await wait("cancellable reader startup") { pool.activeCount == 1 }
    task.cancel()
    try await rejectsAsync("read cancellation") { _ = try await task.value }
    try require(pool.activeCount == 1, "Cancellation retains occupied slot")
    cancellationGate.signal()
    try await wait("cancelled reader cleanup") { pool.activeCount == 0 }
  }

  private static func accessScopes(_ root: URL) throws {
    let parent = root.appendingPathComponent("Access scope", isDirectory: true)
    let document = parent.appendingPathComponent("Reader # notes.md")
    for selection in [document, parent, root, URL(fileURLWithPath: "/", isDirectory: true),
      parent.appendingPathComponent("child/../", isDirectory: true)] {
      try require(MarkdownViewerSupport.accessScope(selection, covers: document),
        "Picker accepts exact document or ancestor: \(selection.path)")
    }
    for selection in [parent.appendingPathComponent("Linked.md"),
      parent.appendingPathComponent("subfolder", isDirectory: true),
      root.appendingPathComponent("Access", isDirectory: true),
      root.appendingPathComponent("Access scope sibling", isDirectory: true),
      URL(string: "file://remote" + parent.path)!,
      URL(string: "https://example.com/Reader.md")!,
      URL(string: document.absoluteString + "#heading")!,
      URL(string: parent.absoluteString + "?query")!] {
      try require(!MarkdownViewerSupport.accessScope(selection, covers: document),
        "Picker rejects unrelated or nonlocal scope: \(selection.absoluteString)")
    }
    let outside = root.appendingPathComponent("Access scope suffix/Reader # notes.md")
    try require(!MarkdownViewerSupport.accessScope(parent, covers: outside),
      "Ancestor validation uses path components, not a string prefix")
    try require(!MarkdownViewerSupport.accessScope(parent,
      covers: URL(string: "https://example.com/Reader.md")!), "Reject remote target document")
  }

  private static func watching(_ root: URL) async throws {
    let directory = root.appendingPathComponent("watch", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("watched.md")
    try Data("initial".utf8).write(to: file)
    var events = 0
    let baseline = descriptorCount()
    let watcher = MarkdownViewerWatcher(url: file) { events += 1 }
    try await wait("both vnode descriptors") { descriptorCount() >= baseline + 2 }
    let unrelated = directory.appendingPathComponent("unrelated.txt")
    try Data("unrelated sibling".utf8).write(to: unrelated)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(events == 0, "Unrelated parent-directory writes do not reload the document")
    try Data("in place".utf8).write(to: file)
    try await wait("in-place write event") { events > 0 }
    let afterWrite = events
    try Data("atomic replacement".utf8).write(to: file, options: .atomic)
    try await wait("atomic replacement event") { events > afterWrite }
    let afterReplace = events
    try Data("new vnode edit".utf8).write(to: file)
    try await wait("replacement vnode reconnected") { events > afterReplace }
    let afterEdit = events
    try FileManager.default.removeItem(at: file)
    try await wait("deletion event") { events > afterEdit }
    let afterDelete = events
    try Data("recreated".utf8).write(to: file)
    try await wait("recreated document event") { events > afterDelete }
    // A burst is coalesced into one notification and does not produce periodic events.
    let beforeBurst = events
    for index in 0..<10 { try Data("burst \(index)".utf8).write(to: file) }
    try await wait("debounced burst") { events > beforeBurst }
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(events == beforeBurst + 1, "Write burst debounced, no idle polling")
    watcher.stop()
    try await wait("vnode descriptors closed") { descriptorCount() <= baseline }
    let afterStop = events
    try Data("after stop".utf8).write(to: file)
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(events == afterStop, "No change events after stop")
    withExtendedLifetime(watcher) {}
  }

  private static func javascript(_ view: WKWebView, _ source: String) async throws -> Any {
    let bounded = """
      return await Promise.race([
        (async () => { \(source) })(),
        new Promise((_, reject) => setTimeout(() => reject(new Error('Native bridge test timed out')), 5000))
      ]);
      """
    return try await withCheckedThrowingContinuation { continuation in
      view.callAsyncJavaScript(bounded, arguments: [:], in: nil, in: .page) { result in
        continuation.resume(with: result)
      }
    }
  }

  private static func descriptorCount() -> Int {
    (0..<2048).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
  }

  private static func controller(_ root: URL) async throws {
    let web = root.appendingPathComponent("web", isDirectory: true)
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let entry = web.appendingPathComponent("index.html")
    let fixture = """
      <!doctype html><html><head><meta charset="utf-8"></head><body>
      <script>
      window.testReady = window.__relayMarkdownViewer === true && !!window.relay;
      window.testChanges = 0;
      window.testAnchors = [];
      window.addEventListener('relay-markdown-changed', () => ++window.testChanges);
      window.addEventListener('relay-markdown-anchor', event => window.testAnchors.push(event.detail));
      </script></body></html>
      """
    try Data(fixture.utf8).write(to: entry)
    let document = root.appendingPathComponent("viewer.md")
    let sibling = root.appendingPathComponent("other notes.MD")
    try Data("# Viewer smoke\nHello 🦊\n".utf8).write(to: document)
    try Data("# Sibling".utf8).write(to: sibling)
    let store = try ShelfStore(root: root.appendingPathComponent("Store"))
    let before = store.snapshot()["items"] as? [[String: Any]] ?? []
    var opened: [URL] = []
    var shelfRequests = 0
    var closeCount = 0
    var initial = URLComponents(url: document, resolvingAgainstBaseURL: false)!
    initial.fragment = "initial heading"
    var viewer: MarkdownViewerController? = try MarkdownViewerController(url: initial.url!,
      entryURL: entry, store: store, showShelf: { shelfRequests += 1 },
      openMarkdown: { opened.append($0) }, onClose: { closeCount += 1 })
    let weakViewer = Weak(viewer)
    let weakWebView = Weak(viewer?.webView)
    guard let view = viewer?.webView else { throw RelayFailure(message: "Missing WKWebView") }
    try require(viewer?.url == document && viewer?.window.representedURL == document, "Window document identity")
    try require(viewer?.window.title == "viewer.md" && viewer?.window.level == .normal, "Filename title and normal level")
    try require(viewer?.window.styleMask.contains(.resizable) == true, "Resizable document window")
    try require(view.configuration.userContentController.userScripts.count == 2, "Viewer marker and shared bridge injected")
    let beforeReady = try await viewer!.handle("markdownDocument", payload: [:]) as? [String: Any]
    try require(beforeReady?["anchor"] as? String == "initial heading", "Initial URL anchor in document payload")
    viewer!.navigateToAnchor("queued%20heading")
    try await wait("renderer and bridge") {
      (try? await view.evaluateJavaScript("window.testReady === true")) as? Bool == true
    }
    try await wait("queued anchor event") {
      (try? await view.evaluateJavaScript("window.testAnchors.includes('queued heading')")) as? Bool == true
    }
    let response = try await javascript(view, "return await window.relay.invoke('markdownDocument')") as? [String: Any]
    try require(response?["text"] as? String == "# Viewer smoke\nHello 🦊\n", "Authenticated real bridge reads current document")
    try require(response?["anchor"] as? String == "queued heading", "Latest anchor in document payload")
    viewer!.navigateToAnchor("later%20heading")
    try await wait("ready renderer anchor event") {
      (try? await view.evaluateJavaScript("window.testAnchors.includes('later heading')")) as? Bool == true
    }
    let blocked = try await javascript(view, """
      try { await window.relay.invoke('addText', {text: 'must not add'}); return false; }
      catch (error) { return String(error).includes('not available'); }
      """) as? Bool
    try require(blocked == true, "Arbitrary store mutation rejected over real bridge")
    try await rejectsAsync("store state read") { _ = try await viewer!.handle("getState", payload: [:]) }
    _ = try await viewer!.handle("markdownOpenLink", payload: ["href": "other%20notes.MD#title%202"])
    try require(opened.count == 1 && opened[0].path == sibling.path,
      "Relative Markdown link routed through parent callback")
    try require(opened[0].fragment?.removingPercentEncoding == "title 2", "Markdown callback retains anchor")
    _ = try await viewer!.handle("markdownOpenLink", payload: ["href": "#same-document"])
    try require(opened.count == 1, "Same-document anchor does not open another window")
    _ = try await viewer!.handle("markdownOpenShelf", payload: [:])
    try require(shelfRequests == 1, "Shelf callback")
    for href in ["javascript:alert(1)", "custom:bad", "file://remote/tmp/a.md", "missing.md"] {
      try await rejectsAsync("controller blocks invalid link") {
        _ = try await viewer!.handle("markdownOpenLink", payload: ["href": href])
      }
    }
    let remoteImage = try await viewer!.handle("markdownImage", payload: ["source": "https://example.com/image.png"]) as? [String: Any]
    try require(remoteImage?.isEmpty == true, "Remote images omitted")
    let image = root.appendingPathComponent("pixel image.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: image)
    let imageResponse = try await viewer!.handle("markdownImage", payload: ["source": "pixel%20image.png"]) as? [String: Any]
    try require((imageResponse?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true,
      "Relative image validated, resolved, and previewed")
    let notImage = root.appendingPathComponent("fake.png")
    try Data("not an image".utf8).write(to: notImage)
    try await rejectsAsync("fake image") { _ = try await viewer!.handle("markdownImage", payload: ["source": "fake.png"]) }
    let hugeImage = root.appendingPathComponent("oversized.png")
    let oversized = open(hugeImage.path, O_CREAT | O_RDWR, 0o600)
    try require(oversized >= 0, "Create oversized image fixture")
    try require(ftruncate(oversized, off_t(MarkdownViewerSupport.imageByteLimit + 1)) == 0, "Sparse image fixture")
    close(oversized)
    try await rejectsAsync("oversized image") { _ = try await viewer!.handle("markdownImage", payload: ["source": "oversized.png"]) }
    try await rejectsAsync("oversized PDF HTML before panel") {
      _ = try await viewer!.handle("markdownExportPDF", payload: ["html": String(repeating: "a", count: 2_000_001)])
    }
    // Atomic replacements exercise the actual JavaScript change event, not only the watcher.
    try Data("# Replacement".utf8).write(to: document, options: .atomic)
    try await wait("JavaScript change notification") {
      (try? await view.evaluateJavaScript("window.testChanges")) as? Int ?? 0 > 0
    }
    let refreshed = try await viewer!.handle("markdownDocument", payload: [:]) as? [String: Any]
    try require(refreshed?["text"] as? String == "# Replacement", "Re-read after atomic replacement")
    try Data(repeating: 0x61, count: MarkdownViewerSupport.byteLimit + 1).write(to: document)
    try await rejectsAsync("truncated source copy must not silently copy prefix") {
      _ = try await viewer!.handle("markdownCopy", payload: ["kind": "source"])
    }
    try await rejectsAsync("truncated source PDF before panel") {
      _ = try await viewer!.handle("markdownExportPDF", payload: ["html": "<p>partial</p>"])
    }
    let after = store.snapshot()["items"] as? [[String: Any]] ?? []
    try require(before.count == after.count && after.isEmpty, "Opening, resolving links and previewing images adds no shelf items")
    viewer!.window.close()
    try require(closeCount == 1 && viewer?.webView == nil && viewer?.window.contentView == nil,
      "Close tears down WebKit and calls parent once")
    try require(view.navigationDelegate == nil && view.uiDelegate == nil,
      "WebKit delegates detached")
    try require(view.configuration.userContentController.userScripts.isEmpty,
      "Injected scripts removed on close")
    try await rejectsAsync("closed controller") { _ = try await viewer!.handle("markdownDocument", payload: [:]) }
    viewer!.window.close()
    try require(closeCount == 1, "Close callback is idempotent")
    viewer = nil
    try await wait("controller release") { weakViewer.value == nil }
    // `view` deliberately keeps the WKWebView alive for the assertions above.
    try require(weakWebView.value === view, "No unexpected replacement web view")
  }
}
