import Foundation

/// Presentation state is independent of mouse tracking and of persisted shelf contents.
@MainActor
final class FloatingShelfLifecycle {
  enum DockEdge: String { case left, right }
  static let maximumItems = 500
  static let idleTimeout: TimeInterval = 60
  private let now: () -> TimeInterval
  private var batches: [(token: UUID, ids: [String], pending: Bool)] = []
  private var hovered = false
  private var incoming = false
  private var outgoing = false
  private var acceptedDrop = false
  private(set) var isVisible = false
  // A capture pause belongs to presentation, so dismissal/new drops do not clear it.
  private(set) var isCapturePresentationHidden = false
  private(set) var dockEdge: DockEdge?
  private(set) var deadline: TimeInterval?
  var onChange: (() -> Void)?

  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }

  var itemIDs: [String] {
    var seen = Set<String>()
    return Array(batches.flatMap(\.ids).filter { seen.insert($0).inserted }.prefix(Self.maximumItems))
  }
  var pendingCount: Int { batches.filter(\.pending).count }
  var importFailed: Bool { acceptedDrop && pendingCount == 0 && itemIDs.isEmpty }

  func showTarget() {
    isVisible = true
    rearm()
  }

  /// Replace presentation only. Old import tokens must not enter a reopened shelf.
  func showRetained(ids: [String]) {
    batches = [(UUID(), Array(ids.prefix(Self.maximumItems)), false)]
    isVisible = true
    acceptedDrop = true
    hovered = false
    incoming = false
    outgoing = false
    rearm()
  }

  func setDocked(_ edge: DockEdge?) {
    guard isVisible, dockEdge != edge else { return }
    dockEdge = edge
    rearm()
  }

  func setCapturePresentationHidden(_ hidden: Bool) {
    guard isCapturePresentationHidden != hidden else { return }
    isCapturePresentationHidden = hidden
    // Ordering the panel out may not deliver mouseExited. Resume with fresh hover tracking.
    hovered = false
    rearm()
  }

  @discardableResult
  func beginImport() -> UUID {
    let token = UUID()
    isVisible = true
    acceptedDrop = true
    incoming = false
    batches.append((token, [], true))
    rearm()
    return token
  }

  func completeImport(_ token: UUID, ids: [String]) {
    // Dismissal clears tokens. A late completion still saves to the main shelf,
    // but cannot resurrect this panel or append to a newer floating shelf.
    guard let index = batches.firstIndex(where: { $0.token == token && $0.pending }) else { return }
    batches[index].ids = ids
    batches[index].pending = false
    rearm()
  }

  func resetExternalDrag() {
    let wasIncoming = incoming
    incoming = false
    if !acceptedDrop && dockEdge == nil { dismiss() } else if wasIncoming { rearm() }
  }

  func setHovered(_ value: Bool) {
    guard !isCapturePresentationHidden || !value else { return }
    guard hovered != value else { return }
    hovered = value
    rearm()
  }
  func setIncoming(_ value: Bool) {
    guard incoming != value else { return }
    incoming = value
    rearm()
  }
  func beginOutgoingDrag() { outgoing = true; rearm() }

  func endOutgoingDrag(succeeded: Bool, deliveredIDs: [String]? = nil) {
    outgoing = false
    guard succeeded else { rearm(); return }
    if let deliveredIDs {
      let delivered = Set(deliveredIDs)
      for index in batches.indices { batches[index].ids.removeAll { delivered.contains($0) } }
      if !itemIDs.isEmpty || pendingCount > 0 { rearm(); return }
    }
    dismiss()
  }

  func dismiss() {
    isVisible = false
    dockEdge = nil
    batches.removeAll()
    acceptedDrop = false
    hovered = false
    incoming = false
    outgoing = false
    deadline = nil
    onChange?()
  }

  func expire() {
    guard let deadline else { return }
    guard now() >= deadline else { onChange?(); return }
    dismiss()
  }

  private func rearm() {
    deadline = isVisible && !isCapturePresentationHidden && dockEdge == nil
      && !hovered && !incoming && !outgoing && pendingCount == 0
      ? now() + Self.idleTimeout : nil
    onChange?()
  }
}
