import AppKit
import Carbon
import Darwin
import UniformTypeIdentifiers
import WebKit

#if !RELAY_TESTING
  @main
  struct RelayShelfApp {
    @MainActor
    static func main() {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      do {
        let root = RelayInstance.dataRoot()
        let request = RelayLaunchRequest(arguments: Array(CommandLine.arguments.dropFirst()))
        let instance = try RelayInstance(root: root)
        guard instance.ownsLock else {
          let delivered = instance.forward(request)
          if !delivered {
            fputs(
              "Relay Shelf is running but did not acknowledge the request. Try again.\n", stderr)
          }
          exit(delivered ? 0 : 1)
        }
        let delegate = try RelayAppDelegate(root: root, instance: instance, request: request)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
      } catch {
        let alert = NSAlert()
        alert.messageText = "Relay Shelf could not start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        app.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(1)
      }
    }
  }
#endif

struct RelayLaunchRequest {
  var paths: [String] = []
  var shelf: String?
  var show = true

  init(paths: [String] = [], shelf: String? = nil, show: Bool = true) {
    self.paths = paths
    self.shelf = shelf
    self.show = show
  }

  init(arguments: [String]) {
    var adding = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--add": adding = true
      case "--shelf":
        if index + 1 < arguments.count {
          index += 1
          shelf = arguments[index]
        }
      case "--show": show = true
      case "--": adding = true
      default:
        if adding {
          let expanded = (argument as NSString).expandingTildeInPath
          let base = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
          paths.append(URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path)
        }
      }
      index += 1
    }
  }
}

/// The file lock is acquired before constructing ShelfStore, including CLI launches.
@MainActor
final class RelayInstance {
  static let notificationName = Notification.Name("local.aryan.relay-shelf.request")
  static let acknowledgmentName = Notification.Name("local.aryan.relay-shelf.acknowledgment")
  let ownsLock: Bool
  private let descriptor: Int32
  private let scope: String
  private var observer: NSObjectProtocol?
  private var pending: [RelayLaunchRequest] = []
  private var recentIDs: [String] = []
  var onRequest: ((RelayLaunchRequest) -> Void)? {
    didSet {
      guard let onRequest else { return }
      let requests = pending
      pending.removeAll()
      requests.forEach(onRequest)
    }
  }

  static func dataRoot() -> URL {
    if let path = ProcessInfo.processInfo.environment["RELAY_SHELF_DATA_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        .standardizedFileURL
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RelayShelf", isDirectory: true)
  }

  init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    scope = root.resolvingSymlinksInPath().standardizedFileURL.path
    let openedDescriptor = Darwin.open(
      root.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard openedDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let acquiredLock = flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0
    if !acquiredLock && errno != EWOULDBLOCK {
      let code = errno
      Darwin.close(openedDescriptor)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    descriptor = openedDescriptor
    ownsLock = acquiredLock
    if ownsLock {
      observer = DistributedNotificationCenter.default().addObserver(
        forName: Self.notificationName, object: scope, queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated { self?.receive(notification) }
      }
    }
  }

  deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    Darwin.close(descriptor)
  }

  private func receive(_ notification: Notification) {
    guard let json = notification.userInfo?["request"] as? String,
      json.utf8.count <= 1_048_576,
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let identifier = object["id"] as? String,
      let paths = object["paths"] as? [String]
    else { return }
    if !recentIDs.contains(identifier) {
      recentIDs.append(identifier)
      if recentIDs.count > 128 { recentIDs.removeFirst() }
      let request = RelayLaunchRequest(
        paths: paths, shelf: object["shelf"] as? String, show: object["show"] as? Bool ?? true)
      if let onRequest { onRequest(request) } else { pending.append(request) }
    }
    DistributedNotificationCenter.default().postNotificationName(
      Self.acknowledgmentName, object: identifier, userInfo: nil, deliverImmediately: true)
  }

  func forward(_ request: RelayLaunchRequest) -> Bool {
    let identifier = UUID().uuidString
    let payload: [String: Any] = [
      "id": identifier, "paths": request.paths,
      "shelf": request.shelf as Any? ?? NSNull(), "show": request.show,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return false }
    var acknowledged = false
    let center = DistributedNotificationCenter.default()
    let token = center.addObserver(
      forName: Self.acknowledgmentName, object: identifier, queue: .main
    ) { _ in
      acknowledged = true
    }
    defer { center.removeObserver(token) }
    // Bounded startup delivery covers the existing process still initializing.
    for _ in 0..<15 {
      center.postNotificationName(
        Self.notificationName, object: scope, userInfo: ["request": json], deliverImmediately: true)
      CFRunLoopRunInMode(.defaultMode, 0.2, false)
      if acknowledged { return true }
    }
    return false
  }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler
{
  let store: ShelfStore
  var window: NSWindow!
  var webView: RelayWebView!
  private(set) var pageURL: URL!
  private let instance: RelayInstance?
  private let initialRequest: RelayLaunchRequest
  private var statusItem: NSStatusItem?
  private var dragController: DragController!
  private var resourceHandler: RelayResourceHandler!
  private var hotKeys: RelayHotKeys?
  private var rendererReady = false
  private var pendingState: [String: Any]?
  private var stateDeliveryScheduled = false
  private var notices: [String] = []
  private var capturePending = false
  private var requests: [RelayLaunchRequest] = []
  private var processingRequests = false
  private var inFlightCommands = Set<String>()

  init(
    root: URL, instance: RelayInstance? = nil, request: RelayLaunchRequest = RelayLaunchRequest()
  ) throws {
    store = try ShelfStore(root: root)
    self.instance = instance
    initialRequest = request
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenus()
    do {
      try makeWindow()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Relay Shelf could not load its interface"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    store.onChange = { [weak self] state in
      self?.applySettings(state["settings"] as? [String: Any] ?? [:])
      self?.queueState(state)
    }
    store.onNotice = { [weak self] message in self?.showNotice(message) }
    store.onSettingsChange = { [weak self] in
      guard let self else { return }
      self.applySettings(self.store.snapshot()["settings"] as? [String: Any] ?? [:])
    }
    applySettings(store.snapshot()["settings"] as? [String: Any] ?? [:])
    store.startWatching()
    hotKeys = RelayHotKeys { [weak self] identifier in
      if identifier == 1 { self?.showWindow() } else { self?.capture() }
    }
    for message in hotKeys?.failures ?? [] { showNotice(message) }
    enqueue(initialRequest)
    instance?.onRequest = { [weak self] request in self?.enqueue(request) }
    // Metadata/bookmark work runs once on launch, independently of rendering.
    Task {
      do { _ = try await store.handle("refresh", payload: [:]) } catch {
        showNotice(error.localizedDescription)
      }
    }
  }

  private func makeWindow() throws {
    let bundle = Bundle.main
    let candidates: [URL]
    if bundle.bundleURL.pathExtension == "app" {
      candidates = [bundle.resourceURL!.appendingPathComponent("web/index.html")]
    } else {
      candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
          "dist/index.html")
      ]
    }
    guard let entry = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw NSError(
        domain: "RelayShelf", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The bundled web/index.html is missing. Rebuild the app with its React assets."
        ])
    }
    pageURL = entry.standardizedFileURL
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.add(RelayScriptHandler(delegate: self), name: "relay")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: bridgeScript(for: pageURL), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    )
    resourceHandler = RelayResourceHandler(store: store)
    configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "relay-file")
    webView = RelayWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.setAccessibilityLabel("Relay Shelf")

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1024, height: 690),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Relay Shelf"
    window.contentMinSize = NSSize(width: 620, height: 420)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.titlebarSeparatorStyle = .none
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.delegate = self
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 690))
    content.wantsLayer = true
    webView.frame = content.bounds
    webView.autoresizingMask = [.width, .height]
    content.addSubview(webView)
    window.contentView = content
    window.center()
    window.setFrameAutosaveName("RelayShelfMainWindow")
    dragController = DragController(
      store: store, root: store.root,
      reveal: { [weak self] in self?.showWindow() },
      notice: { [weak self] message in self?.showNotice(message) })
    dragController.attach(to: webView)
    dragController.onItemClick = { [weak self] id, event in
      let arguments: [String: Any] = [
        "id": id, "meta": event.modifierFlags.contains(.command),
        "shift": event.modifierFlags.contains(.shift),
        "ctrl": event.modifierFlags.contains(.control), "double": event.clickCount > 1,
      ]
      self?.webView.callAsyncJavaScript(
        "const row = document.getElementById('item-' + id); if (row) { row.closest('[role=\"listbox\"]')?.focus(); row.dispatchEvent(new MouseEvent('click', {bubbles:true, metaKey:meta, shiftKey:shift, ctrlKey:ctrl})); if (double) row.dispatchEvent(new MouseEvent('dblclick', {bubbles:true})); }",
        arguments: arguments, in: nil, in: .page
      ) { _ in }
    }
    webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
  }

  private func installMenus() {
    let main = NSMenu()
    let appMenu = NSMenu(title: "Relay Shelf")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    main.addItem(appItem)
    addMenuItem("Open Relay Shelf", to: appMenu, action: #selector(openFromMenu))
    addMenuItem("Add Clipboard", to: appMenu, action: #selector(addClipboard))
    addMenuItem("New Shelf…", to: appMenu, action: #selector(newShelf), key: "n")
    appMenu.addItem(.separator())
    addMenuItem("Hide Relay Shelf", to: appMenu, action: #selector(hideWindow), key: "h")
    appMenu.addItem(.separator())
    addMenuItem("Quit Relay Shelf", to: appMenu, action: #selector(quit), key: "q")
    let edit = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"),
      ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] {
      edit.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    let editItem = NSMenuItem()
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main

    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let icon = NSImage(
      systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Relay Shelf")
    icon?.isTemplate = true
    status.button?.image = icon
    status.button?.toolTip = "Relay Shelf"
    let menu = NSMenu(title: "Relay Shelf")
    addMenuItem("Open Relay Shelf", to: menu, action: #selector(openFromMenu))
    addMenuItem("Add Clipboard", to: menu, action: #selector(addClipboard))
    addMenuItem("New Shelf…", to: menu, action: #selector(newShelf))
    menu.addItem(.separator())
    addMenuItem("Quit Relay Shelf", to: menu, action: #selector(quit), key: "q")
    status.menu = menu
    statusItem = status
  }

  private func addMenuItem(_ title: String, to menu: NSMenu, action: Selector, key: String = "") {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
    item.target = self
  }

  func showWindow() {
    guard let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openFromMenu() { showWindow() }
  @objc private func hideWindow() { window?.orderOut(nil) }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func addClipboard() {
    showWindow()
    Task {
      do { _ = try await store.handle("captureClipboard", payload: [:]) } catch {
        showNotice(error.localizedDescription)
      }
    }
  }

  @objc private func newShelf() {
    showWindow()
    let alert = NSAlert()
    alert.messageText = "New shelf"
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.placeholderString = "Shelf name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        do { _ = try await self.store.handle("createShelf", payload: ["name": name]) } catch {
          self.showNotice(error.localizedDescription)
        }
      }
    }
  }

  private func capture() {
    showWindow()
    if rendererReady { send(["kind": "capture"]) } else { capturePending = true }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    enqueue(RelayLaunchRequest(paths: urls.filter(\.isFileURL).map(\.path)))
  }

  func applicationWillTerminate(_ notification: Notification) {
    dragController?.stop()
    hotKeys?.stop()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "relay")
    store.onChange = nil
    store.onNotice = nil
    store.onSettingsChange = nil
    instance?.onRequest = nil
  }

  private func applySettings(_ settings: [String: Any]) {
    window?.level = settings["alwaysOnTop"] as? Bool == true ? .floating : .normal
    switch settings["theme"] as? String {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: NSApp.appearance = nil
    }
    dragController?.update(settings: settings)
  }

  private func enqueue(_ request: RelayLaunchRequest) {
    requests.append(request)
    guard !processingRequests, window != nil else { return }
    processingRequests = true
    Task {
      while !requests.isEmpty {
        let next = requests.removeFirst()
        do { try await process(next) } catch { showNotice(error.localizedDescription) }
      }
      processingRequests = false
    }
  }

  private func process(_ request: RelayLaunchRequest) async throws {
    if request.show { showWindow() }
    guard !request.paths.isEmpty || request.shelf != nil else { return }
    var shelfID: String?
    if let name = request.shelf?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      let shelves = store.snapshot()["shelves"] as? [[String: Any]] ?? []
      shelfID =
        shelves.first {
          ($0["name"] as? String)?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }?["id"] as? String
      if shelfID == nil {
        _ = try await store.handle("createShelf", payload: ["name": name])
        shelfID = (store.snapshot()["shelves"] as? [[String: Any]])?.last?["id"] as? String
      }
    }
    guard !request.paths.isEmpty else { return }
    // Resolve individual arguments so spaces, quotes and line suffixes retain CLI meaning.
    var paths: [String] = []
    var lines: [String: Int] = [:]
    for path in request.paths {
      let resolved =
        try await store.handle("resolve", payload: ["text": path]) as? [[String: Any]] ?? []
      for entry in resolved {
        if entry["exists"] as? Bool == true, let resolvedPath = entry["path"] as? String {
          paths.append(resolvedPath)
          if let line = entry["line"] as? Int { lines[resolvedPath] = line }
        } else if let error = entry["error"] as? String {
          showNotice(error)
        }
      }
    }
    guard !paths.isEmpty else {
      showNotice("No existing files were found in the supplied paths.")
      return
    }
    var payload: [String: Any] = ["paths": paths, "lines": lines]
    if let shelfID { payload["shelfId"] = shelfID }
    _ = try await store.handle("add", payload: payload)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == "relay", message.frameInfo.isMainFrame,
      let url = message.frameInfo.request.url, isBundledPage(url),
      let body = message.body as? [String: Any], let kind = body["kind"] as? String
    else { return }
    if kind == "dragRegions" {
      dragController.updateDragRegions(body["regions"] as? [[String: Any]] ?? [])
      return
    }
    if kind == "prepareDrag" {
      dragController.prepareDrag(ids: body["ids"] as? [String] ?? [])
      return
    }
    if kind == "startDrag" {
      dragController.startDrag(ids: body["ids"] as? [String] ?? [])
      return
    }
    guard kind == "invoke", let identifier = body["id"] as? String,
      let command = body["command"] as? String
    else { return }
    guard !inFlightCommands.contains(identifier) else { return }
    guard inFlightCommands.count < 128 else {
      send([
        "kind": "reply", "id": identifier, "error": "Too many pending requests. Try again shortly.",
      ])
      return
    }
    inFlightCommands.insert(identifier)
    let payload = body["payload"] as? [String: Any] ?? [:]
    Task {
      defer { inFlightCommands.remove(identifier) }
      do {
        let result = try await store.handle(command, payload: payload)
        let value: Any = result is Void ? NSNull() : result
        send(["kind": "reply", "id": identifier, "value": value])
      } catch {
        send(["kind": "reply", "id": identifier, "error": error.localizedDescription])
      }
    }
  }

  private func queueState(_ state: [String: Any]) {
    pendingState = state
    guard rendererReady, !stateDeliveryScheduled else { return }
    stateDeliveryScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.stateDeliveryScheduled = false
      guard let state = self.pendingState, self.rendererReady else { return }
      self.pendingState = nil
      self.send(["kind": "state", "value": state])
    }
  }

  func showNotice(_ message: String) {
    if rendererReady {
      send(["kind": "notice", "value": message])
    } else {
      notices.append(message)
      if notices.count > 20 { notices.removeFirst() }
    }
  }

  private func send(_ message: [String: Any]) {
    do {
      let data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
      guard let json = String(data: data, encoding: .utf8) else { return }
      // Arguments are passed as data, never interpolated into executable JavaScript.
      webView?.callAsyncJavaScript(
        "window.__relayReceive(JSON.parse(json))", arguments: ["json": json], in: nil, in: .page
      ) { _ in }
    } catch {
      if let identifier = message["id"] as? String {
        send([
          "kind": "reply", "id": identifier, "error": "The native response could not be encoded.",
        ])
      }
    }
  }

  private func isBundledPage(_ url: URL) -> Bool {
    url.isFileURL && url.standardizedFileURL.path == pageURL?.path
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if navigationAction.targetFrame?.isMainFrame == true && isBundledPage(url) {
      decisionHandler(.allow)
    } else if navigationAction.targetFrame?.isMainFrame == false,
      url.scheme == "relay-file", store.resourceURL(for: url) != nil
    {
      decisionHandler(.allow)
    } else {
      // External navigation is available only through the store's openExternal command.
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }

  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) { decisionHandler(.deny) }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    rendererReady = false
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    rendererReady = true
    queueState(pendingState ?? store.snapshot())
    notices.forEach { send(["kind": "notice", "value": $0]) }
    notices.removeAll()
    if capturePending {
      capturePending = false
      send(["kind": "capture"])
    }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code != NSURLErrorCancelled { showLoadError(error) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showLoadError(error)
  }

  private func showLoadError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "The Relay Shelf interface could not load"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Reload")
    alert.addButton(withTitle: "Close")
    showWindow()
    alert.beginSheetModal(for: window) { [weak self] result in
      if result == .alertFirstButtonReturn { self?.webView.reload() }
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    rendererReady = false
    inFlightCommands.removeAll()
    webView.reload()
  }

  private func bridgeScript(for url: URL) -> String {
    let literal = String(
      data: try! JSONSerialization.data(
        withJSONObject: url.absoluteString, options: .fragmentsAllowed), encoding: .utf8)!
    return """
      (() => {
        if (window !== window.top || location.href.split('#')[0].split('?')[0] !== \(literal)) return;
        let serial = 0;
        const generation = globalThis.crypto.randomUUID();
        const pending = new Map();
        const listeners = {state: new Set(), notice: new Set(), capture: new Set()};
        const backlog = {state: null, notice: [], capture: false};
        const post = value => window.webkit.messageHandlers.relay.postMessage(value);
        const listen = (kind, callback) => {
          listeners[kind].add(callback);
          if (kind === 'state' && backlog.state) queueMicrotask(() => { if (listeners.state.has(callback)) callback(backlog.state); });
          if (kind === 'capture' && backlog.capture) { backlog.capture = false; queueMicrotask(() => { if (listeners.capture.has(callback)) callback(); }); }
          if (kind === 'notice' && backlog.notice.length) { const messages = backlog.notice.splice(0); queueMicrotask(() => messages.forEach(message => { if (listeners.notice.has(callback)) callback(message); })); }
          return () => listeners[kind].delete(callback);
        };
        Object.defineProperty(window, '__relayReceive', { value: message => {
          if (message.kind === 'reply') {
            const request = pending.get(message.id);
            if (!request) return;
            pending.delete(message.id);
            if (typeof message.error === 'string') request.reject(new Error(message.error));
            else request.resolve(message.value);
            return;
          }
          const group = listeners[message.kind];
          if (!group) return;
          if (message.kind === 'state') backlog.state = message.value;
          if (!group.size && message.kind === 'capture') backlog.capture = true;
          if (!group.size && message.kind === 'notice') { backlog.notice.push(message.value); if (backlog.notice.length > 20) backlog.notice.shift(); }
          group.forEach(callback => { try { callback(message.value); } catch (error) { console.error(error); } });
        }});
        Object.defineProperty(window, 'relay', { value: Object.freeze({
          invoke: (command, payload = {}) => new Promise((resolve, reject) => {
            if (pending.size >= 128) { reject(new Error('Too many pending requests.')); return; }
            const id = generation + ":" + String(++serial);
            pending.set(id, {resolve, reject});
            try { post({kind: 'invoke', id, command, payload}); }
            catch (error) { pending.delete(id); reject(error); }
          }),
          onState: callback => listen('state', callback),
          onNotice: callback => listen('notice', callback),
          onCapture: callback => listen('capture', callback),
          filePath: _file => '',
          startDrag: ids => post({kind: 'startDrag', ids}),
          prepareDrag: ids => post({kind: 'prepareDrag', ids}),
          setDragRegions: regions => post({kind:'dragRegions', regions})
        })});
        window.addEventListener('pagehide', () => {
          pending.forEach(request => request.reject(new Error('The interface was reloaded.')));
          pending.clear();
        }, {once: true});
      })();
      """
  }
}

@MainActor
private final class RelayScriptHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: RelayAppDelegate?
  init(delegate: RelayAppDelegate) { self.delegate = delegate }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    delegate?.userContentController(userContentController, didReceive: message)
  }
}

@MainActor
private final class RelayHotKeys {
  private var handler: EventHandlerRef?
  private var registrations: [EventHotKeyRef] = []
  private let action: (UInt32) -> Void
  private(set) var failures: [String] = []

  init(action: @escaping (UInt32) -> Void) {
    self.action = action
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard result == noErr else { return result }
        let keys = Unmanaged<RelayHotKeys>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { keys.action(identifier.id) }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else {
      failures.append("Global shortcuts are unavailable. Use the Relay Shelf menu bar icon.")
      return
    }
    for (id, key, modifiers, label) in [
      (UInt32(1), UInt32(kVK_Space), UInt32(cmdKey | shiftKey), "⌘⇧Space"),
      (UInt32(2), UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | shiftKey), "⌘⌥⇧V"),
    ] {
      var reference: EventHotKeyRef?
      let result = RegisterEventHotKey(
        key, modifiers, EventHotKeyID(signature: 0x524C_5953, id: id),
        GetApplicationEventTarget(), 0, &reference)
      if result == noErr, let reference {
        registrations.append(reference)
      } else {
        failures.append(
          "\(label) is already in use or unavailable. Use the menu bar to open Relay Shelf.")
      }
    }
  }

  func stop() {
    registrations.forEach { UnregisterEventHotKey($0) }
    registrations.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}

/// Token authorization runs on the store actor. File reads use bounded chunks off-main.
@MainActor
final class RelayResourceHandler: NSObject, WKURLSchemeHandler {
  private let store: ShelfStore
  private var transfers: [ObjectIdentifier: Task<Void, Never>] = [:]

  init(store: ShelfStore) { self.store = store }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url,
      let file = store.resourceURL(for: requestURL), file.isFileURL,
      ["GET", "HEAD"].contains(urlSchemeTask.request.httpMethod ?? "GET")
    else {
      urlSchemeTask.didFailWithError(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile))
      return
    }
    let identifier = ObjectIdentifier(urlSchemeTask)
    let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
    let headOnly = urlSchemeTask.request.httpMethod == "HEAD"
    transfers[identifier] = Task.detached(priority: .utility) { [weak self] in
      do {
        try Task.checkCancellation()
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // Inspect the same descriptor we stream, without requesting extended attributes.
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size >= 0 else {
          throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile)
        }
        let size = UInt64(metadata.st_size)
        let bounds = RelayByteRange.parse(range, size: size)
        let mime =
          UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
          ?? "application/octet-stream"
        var headers = [
          "Content-Type": mime, "Accept-Ranges": "bytes", "Cache-Control": "no-store",
          "Access-Control-Allow-Origin": "*",
        ]
        let status: Int
        if let bounds {
          status = range == nil ? 200 : 206
          headers["Content-Length"] = String(bounds.length)
          if range != nil {
            headers["Content-Range"] =
              "bytes \(bounds.offset)-\(bounds.offset + bounds.length - 1)/\(size)"
          }
        } else {
          status = 416
          headers["Content-Range"] = "bytes */\(size)"
          headers["Content-Length"] = "0"
        }
        guard
          let response = HTTPURLResponse(
            url: requestURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers),
          await self?.respond(response, task: urlSchemeTask, identifier: identifier) == true
        else { return }
        if let bounds, !headOnly, bounds.length > 0 {
          try handle.seek(toOffset: bounds.offset)
          var remaining = bounds.length
          while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))),
              !data.isEmpty
            else {
              throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
            }
            guard await self?.deliver(data, task: urlSchemeTask, identifier: identifier) == true
            else { return }
            remaining -= UInt64(data.count)
          }
        }
        await self?.finish(task: urlSchemeTask, identifier: identifier, error: nil)
      } catch {
        await self?.finish(task: urlSchemeTask, identifier: identifier, error: error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    transfers.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
  }

  private func respond(_ response: URLResponse, task: WKURLSchemeTask, identifier: ObjectIdentifier)
    -> Bool
  {
    guard transfers[identifier] != nil else { return false }
    task.didReceive(response)
    return true
  }

  private func deliver(_ data: Data, task: WKURLSchemeTask, identifier: ObjectIdentifier) -> Bool {
    guard transfers[identifier] != nil else { return false }
    task.didReceive(data)
    return true
  }

  private func finish(task: WKURLSchemeTask, identifier: ObjectIdentifier, error: Error?) {
    guard transfers.removeValue(forKey: identifier) != nil else { return }
    if let error { task.didFailWithError(error) } else { task.didFinish() }
  }
}

struct RelayByteRange {
  let offset: UInt64
  let length: UInt64

  static func parse(_ header: String?, size: UInt64) -> RelayByteRange? {
    guard let header else { return RelayByteRange(offset: 0, length: size) }
    guard header.hasPrefix("bytes="), size > 0 else { return nil }
    let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    if parts[0].isEmpty {
      guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
      let length = min(suffix, size)
      return RelayByteRange(offset: size - length, length: length)
    }
    guard let start = UInt64(parts[0]), start < size else { return nil }
    let end: UInt64
    if parts[1].isEmpty {
      end = size - 1
    } else {
      guard let supplied = UInt64(parts[1]), supplied >= start else { return nil }
      end = min(supplied, size - 1)
    }
    return RelayByteRange(offset: start, length: end - start + 1)
  }
}
