import AppKit
import Foundation
import WebKit

@main
@MainActor
struct DragControllerTests {
  static func main() async throws {
    testLifecycle()
    testDocking()
    testCaptureLifecycle()
    testFloatingControls()
    testFloatingList()
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("RelayDragTests-\(UUID())")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    try await testCapturePanel(at: temporary.appendingPathComponent("Capture"))
    try await testHistory(at: temporary.appendingPathComponent("History"))
    try await testHistoryLimit(at: temporary.appendingPathComponent("Limit"))
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

  private static func testDocking() {
    var now: TimeInterval = 0
    let shelf = FloatingShelfLifecycle(now: { now })
    shelf.showRetained(ids: ["retained"])
    shelf.setDocked(.left)
    now = 180
    shelf.expire()
    shelf.resetExternalDrag()
    precondition(shelf.isVisible && shelf.dockEdge == .left && shelf.deadline == nil)
    let token = shelf.beginImport()
    shelf.completeImport(token, ids: ["new"])
    precondition(shelf.itemIDs == ["retained", "new"] && shelf.dockEdge == .left)
    shelf.beginOutgoingDrag()
    shelf.endOutgoingDrag(succeeded: false)
    precondition(shelf.isVisible && shelf.deadline == nil && shelf.dockEdge == .left)
    shelf.setDocked(.right)
    shelf.setHovered(true)
    shelf.setDocked(nil)
    precondition(shelf.deadline == nil, "Undocking must respect hover/import/drag pauses")
    shelf.setHovered(false)
    precondition(shelf.deadline == 240)
    now = 239
    shelf.expire()
    precondition(shelf.isVisible)
    now = 240
    shelf.expire()
    precondition(!shelf.isVisible && shelf.dockEdge == nil)
    shelf.showTarget()
    shelf.setDocked(.left)
    shelf.resetExternalDrag()
    precondition(shelf.isVisible, "An explicitly docked empty target must stay available")
    shelf.showRetained(ids: ["again"])
    precondition(shelf.dockEdge == .left)
    shelf.beginOutgoingDrag()
    shelf.endOutgoingDrag(succeeded: true)
    precondition(!shelf.isVisible && shelf.dockEdge == nil)
    shelf.showRetained(ids: ["reopened"])
    precondition(shelf.deadline == 300 && shelf.dockEdge == nil)

    let left = NSRect(x: -1440, y: 50, width: 1440, height: 850)
    let right = NSRect(x: 0, y: 25, width: 1920, height: 1055)
    let frame = NSRect(x: -1500, y: 1000, width: 320, height: 206)
    let docked = DragController.dockedFrame(frame, edge: .left, visibleFrames: [right, left])
    precondition(docked.minX == left.minX + 8 && left.contains(docked))
    precondition(docked.maxY == left.maxY - 8)
    let other = DragController.dockedFrame(
      NSRect(x: 2100, y: -400, width: 320, height: 206), edge: .right,
      visibleFrames: [left, right])
    precondition(other.maxX == right.maxX - 8 && right.contains(other))
    // A removed monitor's coordinates clamp onto the nearest remaining monitor.
    let recovered = DragController.dockedFrame(frame, edge: .right, visibleFrames: [right])
    precondition(right.contains(recovered))
    print("PASS docking pauses expiry, undocking rearms, docked drops and nearest visible screen bounds")
  }

  private static func testCaptureLifecycle() {
    var now: TimeInterval = 0
    let shelf = FloatingShelfLifecycle(now: { now })
    shelf.showRetained(ids: ["retained"])
    shelf.setHovered(true)
    shelf.setCapturePresentationHidden(true)
    now = 180
    shelf.expire()
    precondition(shelf.isVisible && shelf.itemIDs == ["retained"] && shelf.deadline == nil)
    let token = shelf.beginImport()
    shelf.completeImport(token, ids: ["imported"])
    shelf.setHovered(true) // Stale tracking events must not leave restoration stuck hovered.
    shelf.setCapturePresentationHidden(false)
    precondition(shelf.itemIDs == ["retained", "imported"] && shelf.deadline == 240)
    now = 200
    shelf.setCapturePresentationHidden(false)
    precondition(shelf.deadline == 240, "Repeated restoration must not extend idle time")
    shelf.setDocked(.right)
    shelf.setCapturePresentationHidden(true)
    now = 400
    shelf.expire()
    shelf.setCapturePresentationHidden(false)
    precondition(shelf.isVisible && shelf.dockEdge == .right && shelf.deadline == nil)
    shelf.setDocked(nil)
    precondition(shelf.deadline == 460)

    shelf.setCapturePresentationHidden(true)
    let old = shelf.beginImport()
    shelf.dismiss()
    shelf.showTarget()
    shelf.resetExternalDrag()
    precondition(!shelf.isVisible && shelf.isCapturePresentationHidden)
    let fresh = shelf.beginImport()
    shelf.completeImport(old, ids: ["stale"])
    precondition(shelf.pendingCount == 1 && shelf.itemIDs.isEmpty)
    now = 600
    shelf.completeImport(fresh, ids: ["fresh"])
    shelf.expire()
    precondition(shelf.isVisible && shelf.isCapturePresentationHidden && shelf.deadline == nil)
    shelf.showRetained(ids: ["reopened"])
    precondition(shelf.isCapturePresentationHidden && shelf.deadline == nil)
    shelf.setCapturePresentationHidden(false)
    precondition(shelf.deadline == 660)
    now = 660
    shelf.expire()
    precondition(!shelf.isVisible)

    shelf.setCapturePresentationHidden(true)
    let pending = shelf.beginImport()
    shelf.setCapturePresentationHidden(false)
    precondition(shelf.pendingCount == 1 && shelf.deadline == nil)
    shelf.completeImport(pending, ids: ["completed"])
    precondition(shelf.deadline == 720)
    shelf.setCapturePresentationHidden(true)
    shelf.dismiss()
    shelf.setCapturePresentationHidden(false)
    precondition(!shelf.isVisible && shelf.deadline == nil)
    print("PASS capture pause survives dismissal/replacement, retains imports/docking and resumes fresh idle expiry")
  }

  private static func testCapturePanel(at root: URL) async throws {
    let store = try ShelfStore(root: root)
    let ids = await store.captureDroppedText("Capture-retained note")
    let controller = DragController(store: store, root: root, reveal: {}, notice: { _ in })
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    let webView = RelayWebView(frame: host.contentView!.bounds, configuration: WKWebViewConfiguration())
    host.contentView!.addSubview(webView)
    controller.attach(to: webView)
    defer { controller.stop(); host.close() }
    try controller.showFloatingShelf(ids: ids)
    guard let panel = NSApp.windows.first(where: {
      ($0.contentView as? ShelfDropView)?.controller === controller
    }) else { preconditionFailure("Floating panel was not created") }
    precondition(panel.isVisible)
    controller.dockFloatingShelf(edge: "left")
    let dockedFrame = panel.frame
    let history = store.root.appendingPathComponent("floating-shelf.json")
    let saved = try Data(contentsOf: history)
    controller.setCapturePresentationHidden(true)
    let hiddenHistory = try Data(contentsOf: history)
    precondition(!panel.isVisible && controller.floatingShelf.isVisible)
    precondition(controller.floatingShelf.dockEdge == .left && saved == hiddenHistory)
    let promise = TestPromiseReceiver(names: ["during-capture.txt"])
    precondition(controller.receivePromises([promise]))
    try promise.deliver(0)
    try await waitFor { controller.floatingShelf.pendingCount == 0 }
    precondition(!panel.isVisible && controller.floatingShelf.itemIDs.count == 2)
    controller.setCapturePresentationHidden(false)
    precondition(panel.isVisible && controller.floatingShelf.dockEdge == .left)
    precondition(panel.frame.minX == dockedFrame.minX
      && panel.frame.size == ShelfDropView.preferredSize(itemCount: 2)
      && controller.floatingShelf.deadline == nil)

    controller.setCapturePresentationHidden(true)
    controller.closeFloatingShelf()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("New drop during capture", forType: .string)
    precondition(controller.receive(pasteboard: board))
    try await waitFor { controller.floatingShelf.pendingCount == 0 }
    precondition(!panel.isVisible && controller.floatingShelf.isVisible)
    precondition(controller.floatingShelf.itemIDs.count == 1 && controller.floatingShelf.deadline == nil)
    let resumedAt = ProcessInfo.processInfo.systemUptime
    controller.setCapturePresentationHidden(false)
    precondition(panel.isVisible && controller.floatingShelf.deadline! >= resumedAt + 60)
    controller.setCapturePresentationHidden(true)
    controller.closeFloatingShelf()
    try controller.reopenFloatingShelf()
    precondition(!panel.isVisible && controller.floatingShelf.isVisible)
    controller.closeFloatingShelf()
    controller.setCapturePresentationHidden(false)
    precondition(!panel.isVisible && !controller.floatingShelf.isVisible)
    print("PASS visible panel capture hiding, hidden promise completion, history retention and explicit restoration")
  }

  private static func testHistory(at root: URL) async throws {
    let store = try ShelfStore(root: root)
    let history = store.root.appendingPathComponent("floating-shelf.json")
    let controller = DragController(store: store, root: root, reveal: {}, notice: { _ in })
    defer { controller.stop() }
    precondition(!controller.canReopenFloatingShelf)
    do {
      try controller.reopenFloatingShelf()
      preconditionFailure("Absent history must not invent a selection")
    } catch {}
    precondition(!controller.floatingShelf.isVisible)
    _ = try await store.handle("addText", payload: ["text": "Retain actual membership"])
    let first = items(store)[0]["id"] as! String
    _ = try await store.handle("createShelf", payload: ["name": "Temporary project"])
    let shelf = (store.snapshot()["shelves"] as! [[String: Any]]).last!["id"] as! String
    _ = try await store.handle("addText", payload: ["text": "Project note", "shelfId": shelf])
    let second = items(store).last!["id"] as! String
    let stateURL = store.root.appendingPathComponent("shelves.json")
    let before = try Data(contentsOf: stateURL)
    try controller.showFloatingShelf(ids: ["/private/source.txt", first, first, "missing", second])
    precondition(controller.floatingShelf.itemIDs == [first, second])
    controller.dockFloatingShelf(edge: "left")
    controller.dockFloatingShelf(edge: "invalid")
    precondition(controller.floatingShelf.dockEdge == .left)
    controller.closeFloatingShelf()
    precondition(controller.canReopenFloatingShelf)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: history)) as! [String: Any]
    precondition(Set(saved.keys) == Set(["version", "ids"]))
    precondition(saved["ids"] as? [String] == [first, second], "History must contain IDs only")
    let restartedStore = try ShelfStore(root: root)
    // Use a different incoming root to verify history is always kept within store.root.
    let restarted = DragController(store: restartedStore,
      root: root.appendingPathComponent("OtherIncomingRoot"), reveal: {}, notice: { _ in })
    defer { restarted.stop() }
    try restarted.reopenFloatingShelf()
    precondition(restarted.floatingShelf.itemIDs == [first, second])
    precondition(restarted.floatingShelf.dockEdge == nil && restarted.floatingShelf.deadline != nil)
    restarted.floatingShelf.beginOutgoingDrag()
    restarted.floatingShelf.endOutgoingDrag(succeeded: true)
    try restarted.reopenFloatingShelf()
    precondition(restarted.floatingShelf.itemIDs == [first, second])
    let after = try Data(contentsOf: stateURL)
    precondition(after == before, "Presentation must not mutate store membership")

    // Reopening while an older provider is pending must invalidate its panel token,
    // while keeping its files protected and allowing its store commit to finish.
    let late = TestPromiseReceiver(names: ["older.txt"])
    precondition(controller.receivePromises([late]))
    try controller.reopenFloatingShelf()
    precondition(controller.floatingShelf.pendingCount == 0)
    let beforeLate = items(store).count
    try late.deliver(0)
    try await waitFor { items(store).count == beforeLate + 1 }
    try await Task.sleep(nanoseconds: 20_000_000)
    precondition(controller.floatingShelf.itemIDs == [first, second])
    controller.closeFloatingShelf()
    let pending = TestPromiseReceiver(names: ["old-timeout.txt"])
    precondition(controller.receivePromises([pending]))
    try controller.reopenFloatingShelf()
    controller.promiseTimedOut(pending.identifier)
    precondition(controller.floatingShelf.itemIDs == [first, second]
      && controller.floatingShelf.pendingCount == 0 && !controller.floatingShelf.importFailed)
    let beforeTimeout = items(store).count
    try pending.deliver(0)
    try await waitFor { items(store).count == beforeTimeout + 1 }
    precondition(controller.floatingShelf.itemIDs == [first, second])
    let beforeText = items(store).count
    let textBoard = NSPasteboard.withUniqueName()
    defer { textBoard.releaseGlobally() }
    textBoard.setString("Pending text import", forType: .string)
    precondition(controller.receive(pasteboard: textBoard))
    try controller.reopenFloatingShelf()
    try await waitFor { items(store).count == beforeText + 1 }
    precondition(controller.floatingShelf.itemIDs == [first, second])
    controller.dockFloatingShelf(edge: "right")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("New drop stays docked", forType: .string)
    precondition(controller.receive(pasteboard: board))
    try await waitFor { controller.floatingShelf.pendingCount == 0 }
    precondition(controller.floatingShelf.dockEdge == .right && controller.floatingShelf.deadline == nil)
    precondition(controller.floatingShelf.itemIDs.count == 3)
    try controller.showFloatingShelf(ids: [first, second])
    controller.closeFloatingShelf()

    _ = try await store.handle("deleteShelf", payload: ["id": shelf])
    try controller.reopenFloatingShelf()
    precondition(controller.floatingShelf.itemIDs == [first], "Deleted shelf IDs must be ignored")
    controller.closeFloatingShelf()
    _ = try await store.handle("remove", payload: ["ids": [first]])
    precondition(!controller.canReopenFloatingShelf)
    do {
      try controller.reopenFloatingShelf()
      preconditionFailure("Removed items must never be recreated")
    } catch {}
    precondition(!controller.floatingShelf.isVisible)

    try Data("{corrupt history".utf8).write(to: history, options: .atomic)
    let migrated = DragController(store: store, root: root, reveal: {}, notice: { _ in })
    defer { migrated.stop() }
    precondition(!migrated.canReopenFloatingShelf)
    let remaining = items(store)[0]["id"] as! String
    try migrated.showFloatingShelf(ids: [remaining])
    migrated.closeFloatingShelf()
    try migrated.reopenFloatingShelf()
    precondition(migrated.floatingShelf.itemIDs == [remaining])
    print("PASS absent/corrupt history, restart recovery, ID-only persistence, removed IDs and stale pending callbacks")
  }

  private static func testHistoryLimit(at root: URL) async throws {
    let seed = try ShelfStore(root: root)
    _ = try await seed.handle("addText", payload: ["text": "Seed for committed IDs"])
    let template = items(seed)[0]
    var snapshot = seed.snapshot()
    let ids = (0..<502).map { "committed-\($0)" }
    snapshot["items"] = ids.map { id -> [String: Any] in
      var item = template
      item["id"] = id
      return item
    }
    try JSONSerialization.data(withJSONObject: snapshot)
      .write(to: root.appendingPathComponent("shelves.json"), options: .atomic)
    let store = try ShelfStore(root: root)
    let controller = DragController(store: store, root: root, reveal: {}, notice: { _ in })
    defer { controller.stop() }
    try controller.showFloatingShelf(ids: ["missing"] + ids + ids)
    precondition(controller.floatingShelf.itemIDs == Array(ids.prefix(500)))
    controller.closeFloatingShelf()
    let recovered = DragController(store: store, root: root, reveal: {}, notice: { _ in })
    defer { recovered.stop() }
    try recovered.reopenFloatingShelf()
    precondition(recovered.floatingShelf.itemIDs == Array(ids.prefix(500)))
    precondition(items(store).count == 502)
    print("PASS floating presentation and persisted history cap at 500 without removing store items")
  }

  private static func testFloatingControls() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 206),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ShelfDropView(frame: NSRect(x: 0, y: 0, width: 320, height: 206))
    window.contentView = view
    func descendants(_ root: NSView) -> [NSView] {
      root.subviews.flatMap { [$0] + descendants($0) }
    }
    for edge: FloatingShelfLifecycle.DockEdge? in [nil, .left, .right] {
      view.update(items: [FloatingShelfItem(id: "item", name: String(repeating: "Long filename ", count: 20), path: "/tmp/example.txt", kind: "file")],
        pending: 0, failed: false, dockEdge: edge)
      view.layoutSubtreeIfNeeded()
      let controls = descendants(view).filter {
        !$0.isHiddenOrHasHiddenAncestor && ($0 is NSButton || $0 is NSTextField)
      }
      for control in controls {
        let rect = view.convert(control.bounds, from: control)
        precondition(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
          "Floating control outside panel: \(control) at \(rect)")
        if let button = control as? NSButton {
          precondition(rect.width >= button.fittingSize.width - 1,
            "Button must remain readable: \(button.title)")
        } else if let label = control as? NSTextField, !label.stringValue.hasPrefix("Long filename") {
          precondition(rect.width >= label.fittingSize.width - 1, "Status must fit: \(label.stringValue)")
        }
      }
      precondition(controls.compactMap { $0 as? NSButton }.count == 4)
    }
    print("PASS native floating controls fit in undocked and both docked layouts")
  }

  private static func testFloatingList() {
    let sample = (0..<12).map { index in
      FloatingShelfItem(id: "item-\(index)", name: "Document \(index).md",
        path: "/tmp/Document \(index).md", kind: "file")
    }
    let size = ShelfDropView.preferredSize(itemCount: sample.count)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ShelfDropView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    view.update(items: sample, pending: 0, failed: false, dockEdge: .right)
    view.layoutSubtreeIfNeeded()
    func descendants(_ root: NSView) -> [NSView] {
      root.subviews.flatMap { [$0] + descendants($0) }
    }
    let scroll = descendants(view).compactMap { $0 as? NSScrollView }.first!
    let rows = descendants(scroll).compactMap { $0 as? FloatingShelfRow }
    precondition(rows.map(\.item) == sample, "Every item must have its own ordered row")
    precondition(scroll.documentView!.frame.height > scroll.contentView.bounds.height)
    precondition(scroll.documentView!.isFlipped, "Scrolling must start at the first item")
    let row = rows[0]
    let hit = view.hitTest(view.convert(NSPoint(x: 30, y: 18), from: row))
    precondition(hit === row, "The shelf must preserve individual row hit testing")
    view.update(items: sample, pending: 1, failed: false)
    precondition(descendants(scroll).compactMap { $0 as? FloatingShelfRow }.first === row,
      "Status updates should reuse rows")
    view.update(items: Array(sample.prefix(2)), pending: 0, failed: false)
    precondition(descendants(scroll).compactMap { $0 as? FloatingShelfRow }.count == 2)
    let lifecycle = FloatingShelfLifecycle()
    lifecycle.showRetained(ids: ["a", "b", "c"])
    lifecycle.setDocked(.right)
    lifecycle.beginOutgoingDrag()
    lifecycle.endOutgoingDrag(succeeded: false, deliveredIDs: ["a"])
    precondition(lifecycle.itemIDs == ["a", "b", "c"])
    lifecycle.beginOutgoingDrag()
    lifecycle.endOutgoingDrag(succeeded: true, deliveredIDs: ["b"])
    precondition(lifecycle.itemIDs == ["a", "c"] && lifecycle.isVisible && lifecycle.dockEdge == .right)
    lifecycle.beginOutgoingDrag()
    lifecycle.endOutgoingDrag(succeeded: true, deliveredIDs: ["a", "c"])
    precondition(!lifecycle.isVisible)
    print("PASS scrollable ordered file rows, row hit testing/reuse, partial drag retention and drag-all dismissal")
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
