import AppKit

struct NativeDragRegion {
  let id: String
  let ids: [String]
  let rect: NSRect
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
  ) { controller?.dragEnded() }
}
