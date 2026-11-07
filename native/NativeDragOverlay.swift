import AppKit

struct NativeDragRegion {
  let id: String
  let ids: [String]
  let rect: NSRect
}

struct FloatingShelfItem: Equatable {
  let id: String
  let name: String
  let path: String
  let kind: String
}

@MainActor
private final class FloatingShelfRows: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor
final class FloatingShelfRow: NSView, NSDraggingSource {
  let item: FloatingShelfItem
  weak var controller: DragController?
  private var mouseOrigin: NSPoint?

  init(item: FloatingShelfItem) {
    self.item = item
    super.init(frame: .zero)
    let icon = NSImageView(image: NSImage(systemSymbolName: item.kind == "folder" ? "folder" : "doc",
      accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    let name = NSTextField(labelWithString: item.name)
    name.font = .systemFont(ofSize: 12)
    name.lineBreakMode = .byTruncatingMiddle
    name.maximumNumberOfLines = 1
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for child in [icon, name] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 36),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 20),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    toolTip = item.path.isEmpty ? item.name : item.path
    setAccessibilityElement(true)
    setAccessibilityRole(.row)
    setAccessibilityLabel(item.name)
    setAccessibilityHelp("Drag this file from the shelf")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow }
  override func mouseUp(with event: NSEvent) { mouseOrigin = nil }
  override func mouseDragged(with event: NSEvent) {
    guard let origin = mouseOrigin,
      hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 else { return }
    mouseOrigin = nil
    controller?.beginNativeDrag(ids: [item.id], event: event, source: self)
  }
  func draggingSession(_ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
    operation: NSDragOperation) { controller?.dragEnded(operation: operation) }
}

/// A small native destination becomes a drag source once its imports commit.
@MainActor
final class ShelfDropView: NSVisualEffectView, NSDraggingSource {
  weak var controller: DragController?
  private var ids: [String] = []
  private var listedItems: [FloatingShelfItem] = []
  private let fileList = NSScrollView()
  private let rows = FloatingShelfRows()
  private var listHeight: NSLayoutConstraint!
  private var tracking: NSTrackingArea?
  private let title = NSTextField(labelWithString: "Drop into Relay Shelf")
  private let subtitle = NSTextField(labelWithString: "Files, links, images & text")
  private let dockLeft = NSButton(title: "Dock left", target: nil, action: nil)
  private let dockRight = NSButton(title: "Dock right", target: nil, action: nil)
  private let undock = NSButton(title: "Undock", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .hudWindow
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 18
    toolTip = "Drag a file row individually or drag the heading for all files. Drag the top edge to move this shelf."
    resetHighlight()
    registerForDraggedTypes(DragController.pasteboardTypes)

    let icon = NSImageView(image: NSImage(
      systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Relay Shelf")
      ?? NSImage())
    icon.contentTintColor = .controlAccentColor
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingMiddle
    title.maximumNumberOfLines = 1
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    // Labels pass mouse events to the panel's drag source.
    for label in [title, subtitle] { label.isSelectable = false }
    let open = NSButton(title: "Open shelf", target: self, action: #selector(openShelf))
    let close = NSButton(title: "Close", target: self, action: #selector(closeShelf))
    let controls = NSStackView(views: [open, close])
    controls.spacing = 8
    dockLeft.target = self
    dockLeft.action = #selector(dockLeftShelf)
    dockRight.target = self
    dockRight.action = #selector(dockRightShelf)
    undock.target = self
    undock.action = #selector(undockShelf)
    dockLeft.toolTip = "Keep this shelf at the left edge of the nearest screen"
    dockRight.toolTip = "Keep this shelf at the right edge of the nearest screen"
    undock.toolTip = "Resume closing after 60 seconds idle"
    let docking = NSStackView(views: [dockLeft, dockRight, undock])
    docking.spacing = 8
    undock.isHidden = true
    fileList.hasVerticalScroller = true
    fileList.autohidesScrollers = true
    fileList.drawsBackground = false
    fileList.borderType = .noBorder
    fileList.wantsLayer = true
    fileList.layer?.cornerRadius = 8
    fileList.layer?.borderWidth = 1
    fileList.layer?.borderColor = NSColor.separatorColor.cgColor
    fileList.layer?.masksToBounds = true
    fileList.setAccessibilityLabel("Files on floating shelf")
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 0
    rows.translatesAutoresizingMaskIntoConstraints = false
    fileList.documentView = rows
    rows.leadingAnchor.constraint(equalTo: fileList.contentView.leadingAnchor).isActive = true
    rows.topAnchor.constraint(equalTo: fileList.contentView.topAnchor).isActive = true
    rows.widthAnchor.constraint(equalTo: fileList.contentView.widthAnchor).isActive = true
    listHeight = fileList.heightAnchor.constraint(equalToConstant: 0)
    listHeight.isActive = true
    fileList.isHidden = true
    let stack = NSStackView(views: [icon, title, fileList, subtitle, docking, controls])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -28),
      fileList.widthAnchor.constraint(equalTo: stack.widthAnchor),
      title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      subtitle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
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
      if view is NSButton || view is NSScrollView { return hit }
      ancestor = view.superview
    }
    return self
  }

  static func preferredSize(itemCount: Int) -> NSSize {
    NSSize(width: itemCount > 1 ? 360 : 320,
      height: itemCount > 1 ? 214 + min(itemCount, 5) * 36 : 206)
  }

  func update(items: [FloatingShelfItem], pending: Int, failed: Bool,
              dockEdge: FloatingShelfLifecycle.DockEdge? = nil) {
    ids = items.map(\.id)
    if items != listedItems {
      for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
      for item in items {
        let row = FloatingShelfRow(item: item)
        row.controller = controller
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
      }
      listedItems = items
    }
    fileList.isHidden = items.count < 2
    listHeight.constant = items.count > 1 ? CGFloat(min(items.count, 5) * 36 + 2) : 0
    title.stringValue = ids.isEmpty
      ? (pending > 0 ? "Adding to Relay Shelf…" : "Drop into Relay Shelf")
      : (ids.count == 1 ? items[0].name : "Drag all \(ids.count) items")
    subtitle.stringValue = pending > 0 ? "Receiving \(pending) drop\(pending == 1 ? "" : "s")…"
      : (ids.isEmpty ? "Files, links, images & text" : "Drag items out · closes after 60s idle")
    if items.count > 1 && pending == 0 { subtitle.stringValue = "Drag a row or all items · 60s idle" }
    if dockEdge != nil && pending == 0 {
      subtitle.stringValue = items.count > 1 ? "Docked · drag a row or all items" : "Docked · stays until closed or dragged out"
    }
    if failed { subtitle.stringValue = "Nothing added · try dropping again" }
    dockLeft.isHidden = dockEdge == .left
    dockRight.isHidden = dockEdge == .right
    undock.isHidden = dockEdge == nil
    title.toolTip = title.stringValue
    subtitle.toolTip = subtitle.stringValue
    setAccessibilityValue(title.stringValue)
  }

  @objc private func openShelf() { controller?.openShelf() }
  @objc private func closeShelf() { controller?.closeFloatingShelf() }
  @objc private func dockLeftShelf() { controller?.dockFloatingShelf(edge: "left") }
  @objc private func dockRightShelf() { controller?.dockFloatingShelf(edge: "right") }
  @objc private func undockShelf() { controller?.dockFloatingShelf(edge: "none") }

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
      controller?.dockFloatingShelf(edge: "none")
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
        else {
          controller?.dockFloatingShelf(edge: "none")
          window.performDrag(with: next)
        }
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
