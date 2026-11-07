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
  private var panel: NSPanel?
  private var globalMonitor: Any?
  private var localMonitor: Any?
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
    incomingRoot = root.appendingPathComponent("Files/Promises", isDirectory: true)
    self.reveal = reveal
    self.notice = notice
    super.init()
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
    panel?.orderOut(nil)
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
      // Let the destination receive its drop before taking the panel away.
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
      guard panel?.isVisible != true else { return }
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
    if panel == nil {
      let target = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 218, height: 116),
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
      let view = ShelfDropView(frame: NSRect(x: 0, y: 0, width: 218, height: 116))
      view.controller = self
      target.contentView = view
      panel = target
    }
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
    panel.orderFrontRegardless()
  }

  private func resetExternalDrag() {
    externalDrag = false
    samples.removeAll(keepingCapacity: true)
    pasteboardChange = NSPasteboard(name: .drag).changeCount
    panel?.orderOut(nil)
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
    let pasteboard = sender.draggingPasteboard
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
        finishDrop()
        Task { await store.captureDroppedImage(data, extension: ext) }
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
    finishDrop()
    Task { await store.addDroppedURLs(urls) }
  }

  private func acceptText(_ text: String) {
    finishDrop()
    Task { await store.captureDroppedText(text) }
  }

  private func finishDrop() {
    resetExternalDrag()
    reveal()
  }

  private func receivePromises(_ receivers: [NSFilePromiseReceiver]) -> Bool {
    let identifier = UUID()
    let directory = incomingRoot.appendingPathComponent(identifier.uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      store.protectManagedDirectory(directory)
    } catch {
      notice("Could not receive the promised file. \(error.localizedDescription)")
      return false
    }
    let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
    promises[identifier] = PromiseDrop(
      receivers: receivers, directory: directory, remaining: expected)
    finishDrop()
    for receiver in receivers {
      receiver.receivePromisedFiles(
        atDestination: directory, options: [:], operationQueue: promiseQueue
      ) { [weak self] url, error in
        Task { @MainActor in self?.receivedPromise(identifier, url: url, error: error) }
      }
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
    promises.removeValue(forKey: identifier)
    if drop.urls.isEmpty {
      try? FileManager.default.removeItem(at: drop.directory)
      store.releaseManagedDirectory(drop.directory)
      return
    }
    finishDrop()
    Task { [store] in
      defer { store.releaseManagedDirectory(drop.directory) }
      // Keep promise files protected across the store's asynchronous import and commit.
      await store.addDroppedURLs(drop.urls)
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
    resetExternalDrag()
    let session = source.beginDraggingSession(with: items, event: event, source: source)
    session.draggingFormation = .stack
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  func dragEnded() {
    // Copy-only sessions leave shelf items intact on both success and cancellation.
    nativeDrag = false
    lastMouseEvent = nil
    preparedDragIDs = []
    dragOrigin = nil
    resetExternalDrag()
  }
}

@MainActor
private final class PromiseDrop {
  let receivers: [NSFilePromiseReceiver]
  let directory: URL
  var remaining: Int
  var urls: [URL] = []

  init(receivers: [NSFilePromiseReceiver], directory: URL, remaining: Int) {
    self.receivers = receivers
    self.directory = directory
    self.remaining = remaining
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
    dragController?.dragEnded()
  }
}

@MainActor
private final class ShelfDropView: NSVisualEffectView {
  weak var controller: DragController?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .hudWindow
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 18
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    registerForDraggedTypes(DragController.pasteboardTypes)

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Relay Shelf")
        ?? NSImage())
    icon.contentTintColor = .controlAccentColor
    let title = NSTextField(labelWithString: "Drop into Relay Shelf")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    let subtitle = NSTextField(labelWithString: "Files, links, images & text")
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [icon, title, subtitle])
    stack.orientation = .vertical
    stack.spacing = 7
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.heightAnchor.constraint(equalToConstant: 26),
      icon.widthAnchor.constraint(equalToConstant: 30),
    ])
    setAccessibilityLabel("Relay Shelf drop target")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let operation = controller?.operation(for: sender) ?? []
    layer?.borderColor =
      operation == .copy ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
    layer?.borderWidth = operation == .copy ? 2 : 1
    return operation
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.operation(for: sender) ?? []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { resetHighlight() }
  override func draggingEnded(_ sender: NSDraggingInfo) { resetHighlight() }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    controller?.operation(for: sender) == .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    resetHighlight()
    return controller?.receive(sender) ?? false
  }

  private func resetHighlight() {
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
  }
}
