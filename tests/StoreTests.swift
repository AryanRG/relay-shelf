import AppKit
import Foundation

@main
struct StoreTests {
  @MainActor
  static func main() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RelayShelfTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("A quoted document.md")
    try Data("# Example\n\nA table and a document.\n".utf8).write(to: source)
    let root = temporary.appendingPathComponent("Store")
    let store = try ShelfStore(root: root)
    var notices: [String] = []
    store.onNotice = { notices.append($0) }
    let start = Date()
    let resolved =
      try await store.handle("resolve", payload: ["text": "\"\(source.path)\""]) as! [[String: Any]]
    precondition(resolved.count == 1 && resolved[0]["exists"] as? Bool == true)
    let preview =
      try await store.handle("preview", payload: ["path": source.path]) as! [String: Any]
    precondition(preview["type"] as? String == "markdown")
    precondition((preview["text"] as? String)?.contains("# Example") == true)
    print("Path resolution and Markdown preview: \(Int(Date().timeIntervalSince(start) * 1000)) ms")

    _ = try await store.handle(
      "add",
      payload: ["paths": [source.path, source.path], "shelfId": "inbox", "storage": "reference"])
    precondition(items(store).count == 1)
    _ = try await store.handle("add", payload: ["paths": [source.path], "shelfId": "inbox"])
    precondition(items(store).count == 1)
    let id = items(store)[0]["id"] as! String
    _ = try await store.handle("snapshot", payload: ["ids": [id]])
    let copied = items(store)[0]
    precondition(copied["storage"] as? String == "copy")
    let copyPath = copied["path"] as! String
    precondition(copyPath != source.path)
    try FileManager.default.removeItem(at: source)
    precondition(FileManager.default.fileExists(atPath: copyPath))
    _ = try await store.handle("remove", payload: ["ids": [id]])
    precondition(items(store).isEmpty)
    precondition(FileManager.default.fileExists(atPath: copyPath))
    _ = try await store.handle("undo", payload: [:])
    precondition(items(store).count == 1)
    let restored = try ShelfStore(root: root)
    precondition(items(restored).count == 1)

    _ = try await store.handle("createShelf", payload: ["name": "Project"])
    let shelf =
      (store.snapshot()["shelves"] as! [[String: Any]]).first {
        $0["name"] as? String == "Project"
      }!["id"] as! String
    _ = try await store.handle("addText", payload: ["text": "A saved note", "shelfId": shelf])
    _ = try await store.handle(
      "addText", payload: ["text": "https://example.com/docs", "shelfId": shelf])
    precondition(items(store).contains { $0["kind"] as? String == "url" })
    _ = try await store.handle("deleteShelf", payload: ["id": shelf])
    precondition(items(store).count == 1)
    _ = try await store.handle("undo", payload: [:])
    precondition(items(store).count == 3)

    let watched = temporary.appendingPathComponent("Watched")
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: watched.appendingPathComponent("existing.md"))
    _ = try await store.handle("addWatch", payload: ["path": watched.path, "shelfId": "inbox"])
    try await Task.sleep(nanoseconds: 400_000_000)
    let arrival = watched.appendingPathComponent("new.md")
    try Data("# Arrived".utf8).write(to: arrival)
    try await Task.sleep(nanoseconds: 2_500_000_000)
    precondition(
      items(store).contains { $0["name"] as? String == "new.md" },
      "watcher did not import new stable file")
    precondition(
      !items(store).contains { $0["name"] as? String == "existing.md" },
      "watcher imported pre-existing files")
    try FileManager.default.removeItem(at: arrival)
    _ = try await store.handle("refresh", payload: [:])
    precondition(
      items(store).first { $0["name"] as? String == "new.md" }?["exists"] as? Bool == false)

    do {
      _ = try await store.handle("preview", payload: ["path": "/etc/passwd"])
      preconditionFailure("unresolved file was readable through preview")
    } catch {}
    _ = try await store.handle(
      "updateSettings",
      payload: ["settings": ["theme": "dark", "activation": "edge", "defaultStorage": "copy"]])
    let settings = (try ShelfStore(root: root)).snapshot()["settings"] as! [String: Any]
    precondition(settings["theme"] as? String == "dark")
    precondition(settings["activation"] as? String == "edge")

    let big = temporary.appendingPathComponent("large.log")
    try Data(String(repeating: "abc\n", count: 100_000).utf8).write(to: big)
    let largePreview = try ShelfStore.readPreview(big)
    precondition(largePreview["truncated"] as? Bool == true)
    precondition((largePreview["text"] as! String).utf8.count <= 256_000)

    // Undo must never restore a stale whole-state snapshot over later imports.
    let removable = items(store)[0]["id"] as! String
    _ = try await store.handle("remove", payload: ["ids": [removable]])
    _ = try await store.handle(
      "addText", payload: ["text": "Imported after removal", "shelfId": "inbox"])
    _ = try await store.handle("undo", payload: [:])
    precondition(items(store).contains { $0["content"] as? String == "Imported after removal" })
    precondition(!items(store).contains { $0["id"] as? String == removable })

    let target = temporary.appendingPathComponent("target.txt")
    let link = temporary.appendingPathComponent("linked.txt")
    try Data("Independent snapshot".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    _ = try await store.handle(
      "add", payload: ["paths": [link.path], "shelfId": "inbox", "storage": "copy"])
    let savedLink =
      items(store).first { $0["sourcePath"] as? String == link.path }!["path"] as! String
    try FileManager.default.removeItem(at: target)
    let savedContents = try String(contentsOfFile: savedLink, encoding: .utf8)
    precondition(savedContents == "Independent snapshot")

    let utf16 = temporary.appendingPathComponent("unicode.txt")
    try "Unicode document ✓".data(using: .utf16)!.write(to: utf16)
    let unicodePreview = try ShelfStore.readPreview(utf16)
    precondition(unicodePreview["text"] as? String == "Unicode document ✓")

    print(
      "PASS reference/copy persistence, duplicates, undo, named shelves, text/URL capture, directory monitoring, missing files, preview authorization, settings, bounded previews"
    )
    print("Notices: \(notices.count)")
  }

  @MainActor
  static func items(_ store: ShelfStore) -> [[String: Any]] {
    store.snapshot()["items"] as! [[String: Any]]
  }
}
