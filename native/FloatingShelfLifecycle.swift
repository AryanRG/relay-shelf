import Foundation

/// Presentation state is independent of mouse tracking and of persisted shelf contents.
@MainActor
final class FloatingShelfLifecycle {
  static let idleTimeout: TimeInterval = 60
  private let now: () -> TimeInterval
  private var batches: [(token: UUID, ids: [String], pending: Bool)] = []
  private var hovered = false
  private var incoming = false
  private var outgoing = false
  private var acceptedDrop = false
  private(set) var isVisible = false
  private(set) var deadline: TimeInterval?
  var onChange: (() -> Void)?

  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }

  var itemIDs: [String] {
    var seen = Set<String>()
    return batches.flatMap(\.ids).filter { seen.insert($0).inserted }
  }
  var pendingCount: Int { batches.filter(\.pending).count }
  var importFailed: Bool { acceptedDrop && pendingCount == 0 && itemIDs.isEmpty }

  func showTarget() {
    isVisible = true
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
    if !acceptedDrop { dismiss() } else if wasIncoming { rearm() }
  }

  func setHovered(_ value: Bool) {
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

  func endOutgoingDrag(succeeded: Bool) {
    outgoing = false
    if succeeded { dismiss() } else { rearm() }
  }

  func dismiss() {
    isVisible = false
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
    deadline = isVisible && !hovered && !incoming && !outgoing && pendingCount == 0
      ? now() + Self.idleTimeout : nil
    onChange?()
  }
}
