import AppKit
import Foundation

@main
@MainActor
struct DragControllerTests {
  static func main() async throws {
    testLifecycle()
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("RelayDragTests-\(UUID())")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("Store")
    let store = try ShelfStore(root: root)
    var reveals = 0
    var notices: [String] = []
    store.onNotice = { notices.append($0) }
    let controller = DragController(store: store, root: root, reveal: { reveals += 1 },
                                    notice: { notices.append($0) })
    defer { controller.stop() }
    let floating = controller.floatingShelf
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }

    let source = temporary.appendingPathComponent("example.txt")
    try Data("Keep this file available".utf8).write(to: source)
    board.writeObjects([source as NSURL])
    precondition(controller.receive(pasteboard: board))
    controller.resetExternalDrag() // deferred mouse-up / unrelated mouse-down
    precondition(floating.isVisible && floating.pendingCount == 1)
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.itemIDs.count == 1 && floating.isVisible && reveals == 0)
    let firstIDs = floating.itemIDs
    precondition(store.fileURLs(for: firstIDs) == [source])
    precondition(controller.receive(pasteboard: board)) // duplicate reuses committed ID
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.itemIDs == firstIDs)

    board.clearContents()
    board.setString("A dropped note", forType: .string)
    precondition(controller.receive(pasteboard: board))
    board.clearContents()
    board.setString("https://example.com/relay", forType: .URL)
    precondition(controller.receive(pasteboard: board))
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.itemIDs.count == 3)
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    board.clearContents()
    board.setData(image.representation(using: .png, properties: [:])!, forType: .png)
    precondition(controller.receive(pasteboard: board))
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.itemIDs.count == 4)
    precondition(store.fileURLs(for: floating.itemIDs).count == 4)
    controller.openShelf()
    precondition(reveals == 1 && floating.isVisible)
    print("PASS URLs, text, links and images retain draggable IDs without revealing main")

    // A real import completes after manual dismissal, without showing the panel again.
    board.clearContents()
    board.setString("Late import remains saved", forType: .string)
    let beforeDismissal = items(store).count
    precondition(controller.receive(pasteboard: board))
    controller.closeFloatingShelf()
    try await waitFor { items(store).count == beforeDismissal + 1 }
    precondition(!floating.isVisible && floating.itemIDs.isEmpty)

    board.clearContents()
    board.setData(Data("invalid image".utf8), forType: .png)
    precondition(controller.receive(pasteboard: board))
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.importFailed && floating.deadline != nil && !notices.isEmpty)
    controller.closeFloatingShelf()
    print("PASS asynchronous import failure and manual dismissal preserve saved shelf contents")

    // File names become available only when receivePromisedFiles is called.
    let promised = TestPromiseReceiver(names: ["first.txt", "second.txt"])
    precondition(controller.receivePromises([promised]))
    precondition(floating.isVisible && floating.pendingCount == 1 && floating.deadline == nil)
    try promised.deliver(0)
    try await Task.sleep(nanoseconds: 20_000_000)
    precondition(floating.pendingCount == 1, "Multi-file promise finished after only one callback")
    try promised.deliver(1)
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.itemIDs.count == 2)
    let promisedIDs = floating.itemIDs
    let cancelled = TestPromiseReceiver(names: ["cancelled.txt"])
    precondition(controller.receivePromises([cancelled]))
    try cancelled.deliver(0, cancelled: true)
    try await waitFor { floating.pendingCount == 0 }
    precondition(floating.isVisible && floating.itemIDs == promisedIDs)

    let late = TestPromiseReceiver(names: ["late.txt"])
    let beforePromise = items(store).count
    precondition(controller.receivePromises([late]))
    controller.closeFloatingShelf()
    try late.deliver(0)
    try await waitFor { items(store).count == beforePromise + 1 }
    precondition(!floating.isVisible)

    let slow = TestPromiseReceiver(names: ["slow.txt"])
    let beforeSlow = items(store).count
    precondition(controller.receivePromises([slow]))
    controller.promiseTimedOut(slow.identifier)
    precondition(floating.pendingCount == 0 && floating.importFailed)
    controller.closeFloatingShelf()
    let orphan = slow.directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: orphan, withIntermediateDirectories: true)
    store.startWatching()
    try await waitFor { !files.fileExists(atPath: orphan.path) }
    precondition(files.fileExists(atPath: slow.directory.path),
      "Presentation timeout must not let cleanup delete an active provider's destination")
    try slow.deliver(0)
    try await waitFor { items(store).count == beforeSlow + 1 }
    precondition(!floating.isVisible)
    let reopened = try ShelfStore(root: root) // unchanged persisted settings decode
    precondition(items(reopened).count == items(store).count)
    precondition(store.fileURLs(for: firstIDs) == [source])
    print("PASS multi-file promises, cancellation, late completion, protected timeout and persistence")
  }

  private static func testLifecycle() {
    var now: TimeInterval = 0
    let shelf = FloatingShelfLifecycle(now: { now })
    shelf.showTarget()
    shelf.resetExternalDrag()
    precondition(!shelf.isVisible, "Unused activation target should close on mouse-up")
    let first = shelf.beginImport()
    shelf.resetExternalDrag()
    now = 100
    shelf.expire()
    precondition(shelf.isVisible && shelf.deadline == nil)
    let second = shelf.beginImport()
    shelf.completeImport(second, ids: ["b", "shared"])
    shelf.completeImport(first, ids: ["a", "shared"])
    precondition(shelf.itemIDs == ["a", "shared", "b"], "Append order must follow drops")
    precondition(shelf.deadline == 160)
    now = 159
    shelf.resetExternalDrag()
    precondition(shelf.deadline == 160, "Unrelated clicks must not restart the idle clock")
    shelf.expire()
    precondition(shelf.isVisible)
    shelf.setHovered(true)
    now = 300
    shelf.expire()
    precondition(shelf.isVisible && shelf.deadline == nil)
    shelf.setHovered(false)
    precondition(shelf.deadline == 360)
    shelf.setIncoming(true)
    now = 400
    shelf.expire()
    precondition(shelf.isVisible)
    shelf.resetExternalDrag()
    precondition(shelf.isVisible && shelf.deadline == 460)
    shelf.beginOutgoingDrag()
    now = 500
    shelf.expire()
    precondition(shelf.isVisible && shelf.deadline == nil)
    shelf.endOutgoingDrag(succeeded: false)
    precondition(shelf.isVisible && shelf.deadline == 560)
    shelf.beginOutgoingDrag()
    shelf.endOutgoingDrag(succeeded: true)
    precondition(!shelf.isVisible)

    let old = shelf.beginImport()
    shelf.dismiss()
    let fresh = shelf.beginImport()
    shelf.completeImport(old, ids: ["stale"])
    precondition(shelf.pendingCount == 1 && shelf.itemIDs.isEmpty)
    shelf.completeImport(fresh, ids: ["fresh"])
    now = 560
    shelf.expire()
    precondition(!shelf.isVisible)
    shelf.completeImport(fresh, ids: ["late"])
    precondition(!shelf.isVisible && shelf.itemIDs.isEmpty)
    print("PASS 60-second expiry, hover/drag/import pauses, drag outcomes and stale completion guards")
  }

  private static func items(_ store: ShelfStore) -> [[String: Any]] {
    store.snapshot()["items"] as? [[String: Any]] ?? []
  }

  private static func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    preconditionFailure("Timed out waiting for drop import")
  }
}

private final class TestPromiseReceiver: NSFilePromiseReceiver {
  private let names: [String]
  private var destination: URL?
  private var reader: ((URL, Error?) -> Void)?
  var directory: URL { destination! }
  var identifier: UUID { UUID(uuidString: directory.lastPathComponent)! }
  override var fileNames: [String] { destination == nil ? [] : names }
  override var fileTypes: [String] { ["public.plain-text"] }

  init(names: [String]) { self.names = names; super.init() }
  required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
    fatalError("Test receivers are constructed with file names")
  }

  override func receivePromisedFiles(atDestination destinationDir: URL,
    options: [AnyHashable: Any] = [:], operationQueue: OperationQueue,
    reader: @escaping (URL, Error?) -> Void) {
    destination = destinationDir
    self.reader = reader
  }

  func deliver(_ index: Int, cancelled: Bool = false) throws {
    let url = destination!.appendingPathComponent(names[index])
    if !cancelled { try Data("Promised contents".utf8).write(to: url) }
    reader?(url, cancelled ? CocoaError(.userCancelled) : nil)
  }
}
