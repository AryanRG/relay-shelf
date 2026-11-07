import AppKit
import WebKit

/// Native drag destinations keep file promises and filesystem paths out of the DOM.
@MainActor
final class DragController: NSObject {
  private let store: ShelfStore
  private let incomingRoot: URL
  private let reveal: () -> Void
  private let notice: (String) -> Void
  private weak var webView: RelayWebView?
  private var nativeOverlay: NativeDragOverlay?
  var onItemClick: ((String, NSEvent) -> Void)?
  var isReceivingExternalDrag: Bool { externalDrag && !nativeDrag && NSEvent.pressedMouseButtons & 1 != 0 }
  let floatingShelf = FloatingShelfLifecycle()
  private let floatingHistoryURL: URL
  private var lastFloatingShelfIDs: [String] = []
  private var persistedFloatingShelfIDs: [String] = []
  private var idleTimer: Timer?
  private var outgoingFromFloatingShelf = false
  private var panel: NSPanel?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var screenObserver: NSObjectProtocol?
  private var lastMouseEvent: NSEvent?
  private var preparedDragIDs: [String] = []
  private var dragOrigin: NSPoint?
  private var activation = "off"
  private var pasteboardChange = NSPasteboard(name: .drag).changeCount
  private var externalDrag = false
  private var nativeDrag = false
  private var samples: [(point: NSPoint, time: TimeInterval)] = []
  private var promises: [UUID: PromiseDrop] = [:]
  private let promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "Relay Shelf file promises"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 2
    return queue
  }()

  static let pasteboardTypes: [NSPasteboard.PasteboardType] = Array(
    Set(
      [.fileURL, .URL, .string, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    ))

  init(
    store: ShelfStore, root: URL, reveal: @escaping () -> Void, notice: @escaping (String) -> Void
  ) {
    self.store = store
    floatingHistoryURL = store.root.appendingPathComponent("floating-shelf.json")
    incomingRoot = root.appendingPathComponent("Files/Promises", isDirectory: true)
    self.reveal = reveal
    self.notice = notice
    super.init()
    if let history = Self.readFloatingHistory(floatingHistoryURL) {
      lastFloatingShelfIDs = committedFloatingIDs(history.ids)
      persistedFloatingShelfIDs = history.ids
    }
    floatingShelf.onChange = { [weak self] in
      self?.floatingShelfChanged()
    }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.floatingShelf.isVisible else { return }
        if self.floatingShelf.dockEdge == nil { self.positionPanel(near: NSEvent.mouseLocation) }
        self.refreshFloatingShelf()
      }
    }
  }

  func attach(to webView: RelayWebView) {
    self.webView = webView
    webView.dragController = self
    webView.registerForDraggedTypes(Self.pasteboardTypes)
    let overlay = NativeDragOverlay(frame: webView.bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.controller = self
    overlay.registerForDraggedTypes(Self.pasteboardTypes)
    overlay.setAccessibilityElement(false)
    webView.superview?.addSubview(overlay, positioned: .above, relativeTo: webView)
    nativeOverlay = overlay
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown,
    ]) { [weak self] event in
      self?.observeLocal(event)
      return event
    }
    refreshFloatingShelf()
  }

  func update(settings: [String: Any]) {
    let mode = settings["activation"] as? String ?? "shake"
    guard activation != mode else { return }
    activation = mode
    resetExternalDrag()
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }
    guard mode != "off" else { return }
    // Mouse monitoring needs no Accessibility or Input Monitoring permission.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .leftMouseDragged, .leftMouseUp,
    ]) { [weak self] event in
      self?.observeDrag(event)
    }
  }

  func stop() {
    if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    globalMonitor = nil
    localMonitor = nil
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    floatingShelf.dismiss()
    idleTimer?.invalidate()
    lastMouseEvent = nil
  }

  private func observeLocal(_ event: NSEvent) {
    if event.type == .keyDown {
      if event.keyCode == 53 { resetExternalDrag() }
      return
    }
    if event.type == .leftMouseUp {
      lastMouseEvent = nil
      preparedDragIDs = []
      dragOrigin = nil
    } else if let webView, event.window === webView.window {
      let point = webView.convert(event.locationInWindow, from: nil)
      if webView.bounds.contains(point) {
        lastMouseEvent = event
        if event.type == .leftMouseDown {
          preparedDragIDs = []
          dragOrigin = event.locationInWindow
        } else if event.type == .leftMouseDragged {
          beginPreparedDragIfNeeded()
        }
      }
    }
    observeDrag(event)
  }

  func prepareDrag(ids: [String]) {
    guard !nativeDrag, NSEvent.pressedMouseButtons & 1 != 0 else { return }
    preparedDragIDs = ids
    beginPreparedDragIfNeeded()
  }

  private func beginPreparedDragIfNeeded() {
    guard !preparedDragIDs.isEmpty, let origin = dragOrigin,
      let event = lastMouseEvent, event.type == .leftMouseDragged,
      hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4
    else { return }
    let ids = preparedDragIDs
    preparedDragIDs = []
    startDrag(ids: ids)
  }

  private func observeDrag(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      resetExternalDrag()
      pasteboardChange = NSPasteboard(name: .drag).changeCount
    case .leftMouseUp:
      // Let the destination receive its drop before resetting transient activation.
      DispatchQueue.main.async { [weak self] in self?.resetExternalDrag() }
    case .leftMouseDragged:
      guard activation != "off", !nativeDrag else { return }
      let pasteboard = NSPasteboard(name: .drag)
      if !externalDrag {
        guard pasteboard.changeCount != pasteboardChange,
          pasteboard.availableType(from: Self.pasteboardTypes) != nil
        else { return }
        externalDrag = true
      }
      if floatingShelf.isVisible {
        floatingShelf.setIncoming(true)
        return
      }
      let point = NSEvent.mouseLocation
      samples.append((point, event.timestamp))
      samples.removeAll { event.timestamp - $0.time > 0.75 }
      if samples.count > 32 { samples.removeFirst(samples.count - 32) }
      let nearEdge = NSScreen.screens.contains { screen in
        let frame = screen.visibleFrame
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else { return false }
        return min(
          point.x - frame.minX, frame.maxX - point.x,
          point.y - frame.minY, frame.maxY - point.y) <= 14
      }
      if activation == "drag" || (activation == "edge" && nearEdge)
        || (activation == "shake" && shookMouse())
      {
        showTarget(near: point)
      }
    default:
      break
    }
  }

  private func shookMouse() -> Bool {
    guard samples.count >= 4 else { return false }
    return reversals(samples.map { $0.point.x }) >= 3 || reversals(samples.map { $0.point.y }) >= 3
  }

  private func reversals(_ coordinates: [CGFloat]) -> Int {
    guard let first = coordinates.first,
      let low = coordinates.min(), let high = coordinates.max(),
      high - low >= 40, high - low <= 360
    else { return 0 }
    var extreme = first
    var direction: CGFloat = 0
    var count = 0
    for value in coordinates.dropFirst() {
      let delta = value - extreme
      if direction == 0 {
        if abs(delta) >= 12 {
          direction = delta > 0 ? 1 : -1
          extreme = value
        }
      } else if delta * direction >= 0 {
        extreme = value
      } else if abs(delta) >= 12 {
        direction = -direction
        extreme = value
        count += 1
      }
    }
    return count
  }

  private func showTarget(near point: NSPoint) {
    ensurePanel()
    positionPanel(near: point)
    floatingShelf.showTarget()
    floatingShelf.setIncoming(true)
  }

  private func ensurePanel() {
    if panel == nil {
      let target = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 206),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      target.isFloatingPanel = true
      target.becomesKeyOnlyIfNeeded = true
      target.hidesOnDeactivate = false
      target.isReleasedWhenClosed = false
      target.level = .floating
      target.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      target.isOpaque = false
      target.backgroundColor = .clear
      target.hasShadow = true
      let view = ShelfDropView(frame: NSRect(x: 0, y: 0, width: 320, height: 206))
      view.controller = self
      target.contentView = view
      panel = target
    }
  }

  private func positionPanel(near point: NSPoint) {
    guard let panel else { return }
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    let visible =
      screen?.visibleFrame ?? NSRect(x: point.x - 300, y: point.y - 300, width: 600, height: 600)
    var origin = NSPoint(x: point.x + 22, y: point.y - panel.frame.height - 18)
    if origin.x + panel.frame.width > visible.maxX - 8 {
      origin.x = point.x - panel.frame.width - 22
    }
    origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panel.frame.width - 8))
    origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - panel.frame.height - 8))
    panel.setFrameOrigin(origin)
  }

  private func refreshFloatingShelf() {
    idleTimer?.invalidate()
    idleTimer = nil
    guard floatingShelf.isVisible && !floatingShelf.isCapturePresentationHidden else {
      panel?.orderOut(nil)
      return
    }
    // Import/history logic also runs without a web view (e.g. before attachment).
    guard webView != nil else { return }
    ensurePanel()
    if let edge = floatingShelf.dockEdge, let panel {
      panel.setFrame(Self.dockedFrame(panel.frame, edge: edge,
        visibleFrames: NSScreen.screens.map(\.visibleFrame)), display: true)
    } else if panel?.isVisible != true { positionPanel(near: NSEvent.mouseLocation) }
    let ids = floatingShelf.itemIDs
    let items = store.snapshot()["items"] as? [[String: Any]] ?? []
    let name = ids.first.flatMap { id in
      items.first { $0["id"] as? String == id }?["name"] as? String
    }
    (panel?.contentView as? ShelfDropView)?.update(
      ids: ids, name: name, pending: floatingShelf.pendingCount,
      failed: floatingShelf.importFailed, dockEdge: floatingShelf.dockEdge)
    panel?.orderFrontRegardless()
    if let deadline = floatingShelf.deadline {
      let timer = Timer(timeInterval: max(0.01, deadline - ProcessInfo.processInfo.systemUptime),
                        repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.floatingShelf.expire() }
      }
      idleTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func openShelf() { reveal() }
  func closeFloatingShelf() { floatingShelf.dismiss() }

  /// Hide for screen capture without dismissing retained items or import tokens.
  /// The caller must explicitly restore presentation, including after failure/cancellation.
  func setCapturePresentationHidden(_ hidden: Bool) {
    floatingShelf.setCapturePresentationHidden(hidden)
  }

  var canReopenFloatingShelf: Bool { !committedFloatingIDs(lastFloatingShelfIDs).isEmpty }

  /// IDs refer to existing store items; this never imports, moves or deletes membership.
  func showFloatingShelf(ids: [String]) throws {
    guard !nativeDrag else {
      throw RelayFailure(message: "Finish the current drag before opening a floating shelf.")
    }
    let retained = committedFloatingIDs(ids)
    guard !retained.isEmpty else {
      throw RelayFailure(message: "No saved items remain for this floating shelf.")
    }
    try saveFloatingHistory(retained)
    lastFloatingShelfIDs = retained
    floatingShelf.showRetained(ids: retained)
  }

  func reopenFloatingShelf() throws {
    try showFloatingShelf(ids: lastFloatingShelfIDs)
  }

  /// Passing "none" undocks; controls also use this entry point.
  func dockFloatingShelf(edge: String) {
    guard edge == "none" || FloatingShelfLifecycle.DockEdge(rawValue: edge) != nil else { return }
    floatingShelf.setDocked(FloatingShelfLifecycle.DockEdge(rawValue: edge))
  }

  // Screen coordinates can be negative and screens can be separated by gaps.
  // Choose the nearest visible frame, then clamp both axes inside that screen.
  static func dockedFrame(_ frame: NSRect, edge: FloatingShelfLifecycle.DockEdge,
                          visibleFrames: [NSRect]) -> NSRect {
    let center = NSPoint(x: frame.midX, y: frame.midY)
    func distance(_ rect: NSRect) -> CGFloat {
      let dx = max(rect.minX - center.x, 0, center.x - rect.maxX)
      let dy = max(rect.minY - center.y, 0, center.y - rect.maxY)
      return dx * dx + dy * dy
    }
    guard let screen = visibleFrames.filter({ $0.width > 16 && $0.height > 16 })
      .min(by: { distance($0) < distance($1) }) else { return frame }
    let visible = screen.insetBy(dx: 8, dy: 8)
    let size = NSSize(width: min(frame.width, visible.width),
                      height: min(frame.height, visible.height))
    return NSRect(x: edge == .left ? visible.minX : visible.maxX - size.width,
      y: max(visible.minY, min(frame.minY, visible.maxY - size.height)),
      width: size.width, height: size.height)
  }

  private func committedFloatingIDs(_ ids: [String]) -> [String] {
    let snapshot = store.snapshot()
    let shelves = Set((snapshot["shelves"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    let available = Set((snapshot["items"] as? [[String: Any]] ?? []).compactMap { item -> String? in
      guard let shelf = item["shelfId"] as? String, shelves.contains(shelf) else { return nil }
      return item["id"] as? String
    })
    var seen = Set<String>()
    var retained: [String] = []
    for id in ids where available.contains(id) && seen.insert(id).inserted {
      retained.append(id)
      if retained.count == FloatingShelfLifecycle.maximumItems { break }
    }
    return retained
  }

  private func saveFloatingHistory(_ ids: [String]) throws {
    guard ids != persistedFloatingShelfIDs else { return }
    try JSONEncoder().encode(FloatingShelfHistory(ids: ids))
      .write(to: floatingHistoryURL, options: .atomic)
    persistedFloatingShelfIDs = ids
  }

  private static func readFloatingHistory(_ url: URL) -> FloatingShelfHistory? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 128 * 1024 + 1), data.count <= 128 * 1024,
      let history = try? JSONDecoder().decode(FloatingShelfHistory.self, from: data),
      history.version == 1 else { return nil }
    return history
  }

  private func floatingShelfChanged() {
    let ids = committedFloatingIDs(floatingShelf.itemIDs)
    if !ids.isEmpty {
      lastFloatingShelfIDs = ids
      do { try saveFloatingHistory(ids) }
      catch { notice("Could not save floating shelf history. \(error.localizedDescription)") }
    }
    refreshFloatingShelf()
  }

  func resetExternalDrag() {
    externalDrag = false
    samples.removeAll(keepingCapacity: true)
    pasteboardChange = NSPasteboard(name: .drag).changeCount
    floatingShelf.resetExternalDrag()
  }

  func operation(for sender: NSDraggingInfo) -> NSDragOperation {
    guard !nativeDrag,
      sender.draggingSourceOperationMask.contains(.copy),
      sender.draggingPasteboard.availableType(from: Self.pasteboardTypes) != nil
    else { return [] }
    return .copy
  }

  func receive(_ sender: NSDraggingInfo) -> Bool {
    guard operation(for: sender) == .copy else { return false }
    return receive(pasteboard: sender.draggingPasteboard)
  }

  // Also used by regression tests without constructing a system drag session.
  func receive(pasteboard: NSPasteboard) -> Bool {
    if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
      as? [NSFilePromiseReceiver],
      !receivers.isEmpty
    {
      return receivePromises(receivers)
    }
    if let objects = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !objects.isEmpty
    {
      acceptURLs(objects)
      return true
    }
    if let url = pasteboard.string(forType: .URL), !url.isEmpty {
      acceptText(url)
      return true
    }
    for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
      if let data = pasteboard.data(forType: type), !data.isEmpty {
        guard data.count <= 64 * 1024 * 1024 else {
          notice("This image is larger than 64 MB. Drop its file instead.")
          return false
        }
        importDrop { [store] in await store.captureDroppedImage(data, extension: ext) }
        return true
      }
    }
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      acceptText(text)
      return true
    }
    return false
  }

  private func acceptURLs(_ urls: [URL]) {
    importDrop { [store] in await store.addDroppedURLs(urls) }
  }

  private func acceptText(_ text: String) {
    importDrop { [store] in await store.captureDroppedText(text) }
  }

  private func importDrop(_ operation: @escaping @MainActor () async -> [String]) {
    let token = finishDrop()
    Task { [weak self] in
      let ids = await operation()
      self?.floatingShelf.completeImport(token, ids: ids)
    }
  }

  private func finishDrop() -> UUID {
    let token = floatingShelf.beginImport()
    resetExternalDrag()
    return token
  }

  func receivePromises(_ receivers: [NSFilePromiseReceiver]) -> Bool {
    guard !receivers.isEmpty else { return false }
    let identifier = UUID()
    let directory = incomingRoot.appendingPathComponent(identifier.uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      store.protectManagedDirectory(directory)
    } catch {
      notice("Could not receive the promised file. \(error.localizedDescription)")
      return false
    }
    promises[identifier] = PromiseDrop(
      receivers: receivers, directory: directory, remaining: 0, token: finishDrop())
    // A provider can cancel without delivering all its callbacks.
    promises[identifier]?.timeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000_000)
      guard !Task.isCancelled else { return }
      self?.promiseTimedOut(identifier)
    }
    for receiver in receivers {
      receiver.receivePromisedFiles(
        atDestination: directory, options: [:], operationQueue: promiseQueue
      ) { [weak self] url, error in
        Task { @MainActor in self?.receivedPromise(identifier, url: url, error: error) }
      }
      // fileNames is populated only after calling receivePromisedFiles. Callbacks
      // enter the main actor after this synchronous loop has counted every file.
      promises[identifier]?.remaining += max(1, receiver.fileNames.count, receiver.fileTypes.count)
    }
    return true
  }

  private func receivedPromise(_ identifier: UUID, url: URL, error: Error?) {
    guard let drop = promises[identifier] else { return }
    if let error {
      notice("Could not receive a promised file. \(error.localizedDescription)")
    } else {
      drop.urls.append(url)
    }
    drop.remaining -= 1
    guard drop.remaining <= 0 else { return }
    finishPromises(identifier)
  }

  func promiseTimedOut(_ identifier: UUID) {
    guard let drop = promises[identifier] else { return }
    notice("The file provider is taking too long. Files arriving later will still be saved to the shelf.")
    floatingShelf.completeImport(drop.token, ids: [])
    // This is a presentation timeout, not provider cancellation. Keep the receiver
    // and directory protected until ALL callbacks arrive, even after dismissal.
    // A provider that never finishes stays protected for this process's lifetime.
  }

  private func finishPromises(_ identifier: UUID) {
    guard let drop = promises.removeValue(forKey: identifier) else { return }
    drop.timeout?.cancel()
    if drop.urls.isEmpty {
      try? FileManager.default.removeItem(at: drop.directory)
      store.releaseManagedDirectory(drop.directory)
      floatingShelf.completeImport(drop.token, ids: [])
      return
    }
    Task { [weak self, store] in
      defer { store.releaseManagedDirectory(drop.directory) }
      // Keep promise files protected across the store's asynchronous import and commit.
      let ids = await store.addDroppedURLs(drop.urls)
      self?.floatingShelf.completeImport(drop.token, ids: ids)
    }
  }

  func updateDragRegions(_ values: [[String: Any]]) {
    nativeOverlay?.regions = values.prefix(200).compactMap { value in
      guard let id = value["id"] as? String, let ids = value["ids"] as? [String],
        let x = value["x"] as? Double, let y = value["y"] as? Double,
        let width = value["width"] as? Double, let height = value["height"] as? Double,
        [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
      else { return nil }
      return NativeDragRegion(
        id: id, ids: ids, rect: NSRect(x: x, y: y, width: width, height: height))
    }
  }

  func selectNativeItem(_ id: String, event: NSEvent) { onItemClick?(id, event) }

  func startDrag(ids: [String]) {
    guard !nativeDrag, let webView,
      let event = lastMouseEvent, event.window === webView.window,
      event.type == .leftMouseDown || event.type == .leftMouseDragged,
      NSEvent.pressedMouseButtons & 1 != 0
    else {
      notice("Drag an item while holding the mouse button to copy it out.")
      return
    }
    beginNativeDrag(ids: ids, event: event, source: webView)
  }

  func beginNativeDrag(ids: [String], event: NSEvent, source: NSView & NSDraggingSource) {
    guard !nativeDrag else { return }
    let urls = store.fileURLs(for: ids)
    guard !urls.isEmpty else {
      notice("The selected files are unavailable.")
      return
    }
    let point = source.convert(event.locationInWindow, from: nil)
    let fallback =
      NSImage(systemSymbolName: "doc", accessibilityDescription: "File")
      ?? NSImage(size: NSSize(width: 32, height: 32))
    let items = urls.enumerated().map { index, url in
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      let icon = fallback
      let offset = CGFloat(min(index, 3)) * 3
      item.setDraggingFrame(
        NSRect(x: point.x - 16 + offset, y: point.y - 16 + offset, width: 32, height: 32),
        contents: icon)
      return item
    }
    nativeDrag = true
    outgoingFromFloatingShelf = source is ShelfDropView
    floatingShelf.beginOutgoingDrag()
    resetExternalDrag()
    let session = source.beginDraggingSession(with: items, event: event, source: source)
    session.draggingFormation = .stack
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  func dragEnded(operation: NSDragOperation) {
    // Copy-only sessions leave shelf items intact on both success and cancellation.
    nativeDrag = false
    floatingShelf.endOutgoingDrag(succeeded: outgoingFromFloatingShelf
      && !operation.intersection([.copy, .move, .link]).isEmpty)
    outgoingFromFloatingShelf = false
    lastMouseEvent = nil
    preparedDragIDs = []
    dragOrigin = nil
    resetExternalDrag()
  }
}

private struct FloatingShelfHistory: Codable {
  var version = 1
  let ids: [String]
}

@MainActor
private final class PromiseDrop {
  let receivers: [NSFilePromiseReceiver]
  let directory: URL
  var remaining: Int
  var urls: [URL] = []
  let token: UUID
  var timeout: Task<Void, Never>?

  init(receivers: [NSFilePromiseReceiver], directory: URL, remaining: Int, token: UUID) {
    self.receivers = receivers
    self.directory = directory
    self.remaining = remaining
    self.token = token
  }
}

@MainActor
final class RelayWebView: WKWebView, NSDraggingSource {
  weak var dragController: DragController?

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dragController?.operation(for: sender) ?? []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    dragController?.operation(for: sender) ?? []
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dragController?.operation(for: sender) == .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dragController?.receive(sender) ?? false
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    dragController?.dragEnded(operation: operation)
  }
}
