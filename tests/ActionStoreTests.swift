import AppKit
import Foundation
import PDFKit

@main
@MainActor
struct ActionStoreTests {
  static func main() async throws {
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("RelayActionStore-\(UUID())")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("Store")
    let store = try ShelfStore(root: root)
    let destination = temporary.appendingPathComponent("Destination")
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("example.txt")
    try Data("Original content".utf8).write(to: source)
    _ = try await store.handle("add", payload: ["paths": [source.path], "shelfId": "inbox"])
    let sourceID = items(store)[0]["id"] as! String
    _ = try await store.handle("addDestination", payload: ["path": destination.path, "name": "Project"])
    _ = try await store.handle("addDestination", payload: ["path": destination.path, "name": "Outputs"])
    let destinations = store.snapshot()["destinations"] as! [[String: Any]]
    precondition(destinations.count == 1 && destinations[0]["name"] as? String == "Outputs")
    let destinationID = destinations[0]["id"] as! String
    let payload: [String: Any] = ["ids": [sourceID], "destinationId": destinationID]
    _ = try await store.handle("copyToDestination", payload: payload)
    async let first = store.handle("copyToDestination", payload: payload)
    async let second = store.handle("copyToDestination", payload: payload)
    _ = try await (first, second)
    let copied = try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
    precondition(copied.count == 3 && Set(copied.map(\.lastPathComponent)).count == 3)
    for url in copied { try check(try String(contentsOf: url, encoding: .utf8) == "Original content") }
    try check(try String(contentsOf: source, encoding: .utf8) == "Original content")
    let reopened = try ShelfStore(root: root)
    precondition((reopened.snapshot()["destinations"] as! [[String: Any]]).count == 1)
    _ = try await reopened.handle("removeDestination", payload: ["id": destinationID])
    precondition((reopened.snapshot()["destinations"] as! [[String: Any]]).isEmpty)
    try check(try files.contentsOfDirectory(atPath: destination.path).count == 3)
    print("PASS saved destinations, duplicate naming, concurrent copies and original retention")

    let failureDestination = temporary.appendingPathComponent("Failure")
    try files.createDirectory(at: failureDestination, withIntermediateDirectories: true)
    do {
      _ = try await DestinationCopier.copy([source, temporary.appendingPathComponent("missing.txt")], to: failureDestination)
      preconditionFailure("Missing input should fail before publication")
    } catch {}
    try check(try files.contentsOfDirectory(atPath: failureDestination.path).isEmpty)
    let child = failureDestination.appendingPathComponent("Child")
    try files.createDirectory(at: child, withIntermediateDirectories: true)
    do {
      _ = try await DestinationCopier.copy([failureDestination], to: child)
      preconditionFailure("Cannot copy a folder into its child")
    } catch {}
    do {
      _ = try await DestinationCopier.copy([URL(fileURLWithPath: "/")], to: child)
      preconditionFailure("Every local destination is inside the filesystem root")
    } catch {}
    do {
      _ = try await store.handle("addDestination", payload: ["path": store.root.appendingPathComponent("Files").path])
      preconditionFailure("Managed data folders cannot be saved destinations")
    } catch {}
    print("PASS copy failures clean staging and reject recursive or managed destinations")

    // Version 1.0.1 stores have no destinations field.
    let stateURL = root.appendingPathComponent("shelves.json")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    legacy.removeValue(forKey: "destinations")
    let migratedRoot = temporary.appendingPathComponent("MigratedStore")
    try files.createDirectory(at: migratedRoot, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacy).write(to: migratedRoot.appendingPathComponent("shelves.json"))
    let migrated = try ShelfStore(root: migratedRoot)
    precondition((migrated.snapshot()["destinations"] as! [[String: Any]]).isEmpty)
    precondition(items(migrated).count == 1)
    _ = try await migrated.handle("addDestination", payload: ["path": destination.path])
    try check((try ShelfStore(root: migratedRoot)).snapshot()["destinations"] is [[String: Any]])
    print("PASS existing shelves migrate without losing files or settings")

    let a = temporary.appendingPathComponent("A.pdf")
    let b = temporary.appendingPathComponent("B.pdf")
    try writePDF(a, title: "ALPHA")
    try writePDF(b, title: "BETA")
    let originalA = try Data(contentsOf: a)
    _ = try await migrated.handle("add", payload: ["paths": [a.path, b.path], "shelfId": "inbox"])
    let byName = Dictionary(uniqueKeysWithValues: items(migrated).map { ($0["name"] as! String, $0["id"] as! String) })
    let before = Set(items(migrated).map { $0["id"] as! String })
    _ = try await migrated.handle("processFiles", payload: [
      "ids": [byName["B.pdf"]!, byName["A.pdf"]!], "shelfId": "inbox", "operation": "mergePDF",
    ])
    let output = items(migrated).filter { !before.contains($0["id"] as! String) }
    precondition(output.count == 1 && output[0]["storage"] as? String == "copy")
    let outputURL = URL(fileURLWithPath: output[0]["path"] as! String)
    let pdf = PDFDocument(url: outputURL)!
    precondition(pdf.pageCount == 2)
    precondition(pdf.page(at: 0)?.string?.contains("BETA") == true)
    precondition(pdf.page(at: 1)?.string?.contains("ALPHA") == true)
    try check(try Data(contentsOf: a) == originalA)
    let outputID = output[0]["id"] as! String
    _ = try await migrated.handle("remove", payload: ["ids": [outputID]])
    _ = try await migrated.handle("undo", payload: [:])
    precondition(items(migrated).contains { $0["id"] as? String == outputID })
    precondition(files.fileExists(atPath: outputURL.path))
    do {
      _ = try await migrated.handle("processFiles", payload: [
        "ids": ["unknown"], "shelfId": "inbox", "operation": "mergePDF",
      ])
      preconditionFailure("Missing selection was accepted")
    } catch {}
    print("PASS native action entry point, PDF order, managed output persistence and undo")

    // A single release must not remove another operation's protection of the same file.
    let protected = migrated.root.appendingPathComponent("Files").appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: protected, withIntermediateDirectories: true)
    let input = protected.appendingPathComponent("held.txt")
    try Data("in flight".utf8).write(to: input)
    migrated.protectManagedDirectory(input)
    migrated.protectManagedDirectory(input)
    migrated.startWatching()
    migrated.releaseManagedDirectory(input)
    try await Task.sleep(nanoseconds: 1_300_000_000)
    precondition(files.fileExists(atPath: input.path))
    migrated.releaseManagedDirectory(input)
    try await Task.sleep(nanoseconds: 1_300_000_000)
    precondition(!files.fileExists(atPath: protected.path))
    print("PASS shared in-flight inputs remain protected until their last operation completes")
  }

  private static func check(_ condition: @autoclosure () throws -> Bool) throws {
    let result = try condition()
    precondition(result)
  }

  private static func items(_ store: ShelfStore) -> [[String: Any]] {
    store.snapshot()["items"] as! [[String: Any]]
  }

  private static func writePDF(_ url: URL, title: String) throws {
    let data = NSMutableData()
    var page = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &page, nil)!
    context.beginPDFPage(nil)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    (title as NSString).draw(at: NSPoint(x: 30, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: url)
  }
}
