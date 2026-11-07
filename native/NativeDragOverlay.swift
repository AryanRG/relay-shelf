import AppKit

struct NativeDragRegion {
  let id: String
  let ids: [String]
  let rect: NSRect
}

/// A small native destination becomes a drag source once its imports commit.
@MainActor
final class ShelfDropView: NSVisualEffectView, NSDraggingSource {
  weak var controller: DragController?
  private var ids: [String] = []
  private var tracking: NSTrackingArea?
  private let title = NSTextField(labelWithString: "Drop into Relay Shelf")
  private let subtitle = NSTextField(labelWithString: "Files, links, images & text")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .hudWindow
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 18
    toolTip = "Drag items from the center. Drag the top edge to move this shelf."
    resetHighlight()
    registerForDraggedTypes(DragController.pasteboardTypes)

    let icon = NSImageView(image: NSImage(
      systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Relay Shelf")
      ?? NSImage())
    icon.contentTintColor = .controlAccentColor
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingMiddle
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    // Labels pass mouse events to the panel's drag source.
    for label in [title, subtitle] { label.isSelectable = false }
    let open = NSButton(title: "Open shelf", target: self, action: #selector(openShelf))
    let close = NSButton(title: "Close", target: self, action: #selector(closeShelf))
    let controls = NSStackView(views: [open, close])
    controls.spacing = 8
    let stack = NSStackView(views: [icon, title, subtitle, controls])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -28),
      title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      icon.heightAnchor.constraint(equalToConstant: 26),
      icon.widthAnchor.constraint(equalToConstant: 30),
    ])
    setAccessibilityLabel("Relay Shelf floating shelf")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    var ancestor: NSView? = hit
    while let view = ancestor, view !== self {
      if view is NSButton { return hit }
      ancestor = view.superview
    }
    return self
  }

  func update(ids: [String], name: String?, pending: Int, failed: Bool) {
    self.ids = ids
    title.stringValue = ids.isEmpty
      ? (pending > 0 ? "Adding to Relay Shelf…" : "Drop into Relay Shelf")
      : (ids.count == 1 ? (name ?? "1 item") : "\(ids.count) items · \(name ?? "Relay Shelf")")
    subtitle.stringValue = pending > 0 ? "Receiving \(pending) drop\(pending == 1 ? "" : "s")…"
      : (ids.isEmpty ? "Files, links, images & text" : "Drag items out · closes after 60s idle")
    if failed { subtitle.stringValue = "Nothing added · try dropping again" }
    setAccessibilityValue(title.stringValue)
  }

  @objc private func openShelf() { controller?.openShelf() }
  @objc private func closeShelf() { controller?.closeFloatingShelf() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) { controller?.floatingShelf.setHovered(true) }
  override func mouseExited(with event: NSEvent) { controller?.floatingShelf.setHovered(false) }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    if convert(event.locationInWindow, from: nil).y >= bounds.maxY - 18 {
      window.performDrag(with: event)
      return
    }
    let draggable = !ids.isEmpty
    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
      dequeue: true)
    {
      if next.type == .leftMouseUp { return }
      if hypot(next.locationInWindow.x - event.locationInWindow.x,
               next.locationInWindow.y - event.locationInWindow.y) >= 4 {
        if draggable { controller?.beginNativeDrag(ids: ids, event: next, source: self) }
        else { window.performDrag(with: next) }
        return
      }
    }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let operation = controller?.operation(for: sender) ?? []
    controller?.floatingShelf.setIncoming(operation == .copy)
    layer?.borderColor = operation == .copy
      ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
    layer?.borderWidth = operation == .copy ? 2 : 1
    return operation
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.operation(for: sender) ?? []
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    controller?.floatingShelf.setIncoming(false)
    resetHighlight()
  }
  override func draggingEnded(_ sender: NSDraggingInfo) {
    controller?.floatingShelf.setIncoming(false)
    resetHighlight()
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    controller?.operation(for: sender) == .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    resetHighlight()
    let accepted = controller?.receive(sender) ?? false
    controller?.floatingShelf.setIncoming(false)
    return accepted
  }
  private func resetHighlight() {
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
  }
  func draggingSession(_ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
    operation: NSDragOperation) { controller?.dragEnded(operation: operation) }
}

@MainActor
final class NativeDragOverlay: NSView, NSDraggingSource {
  weak var controller: DragController?
  var regions: [NativeDragRegion] = []
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    return controller?.isReceivingExternalDrag == true
      || regions.contains(where: { $0.rect.contains(local) }) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let region = regions.first(where: { $0.rect.contains(point) }), let window else { return }
    controller?.selectNativeItem(region.id, event: event)
    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
      dequeue: true)
    {
      if next.type == .leftMouseUp { return }
      if hypot(
        next.locationInWindow.x - event.locationInWindow.x,
        next.locationInWindow.y - event.locationInWindow.y) >= 4
      {
        controller?.beginNativeDrag(ids: region.ids, event: next, source: self)
        return
      }
    }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.operation(for: sender) ?? []
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.operation(for: sender) ?? []
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    controller?.operation(for: sender) == .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    controller?.receive(sender) ?? false
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) { controller?.dragEnded(operation: operation) }
}
