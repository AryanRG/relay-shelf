import Foundation

@main
@MainActor
struct StoreRaceTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("RelayShelfRaceTests-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("concurrent.txt")
        let secondSource = temporary.appendingPathComponent("second.txt")
        let contents = Data(String(repeating: "Saved-copy race regression\n", count: 128).utf8)
        let secondContents = Data("A second original must survive cleanup.\n".utf8)
        try contents.write(to: source)
        try secondContents.write(to: secondSource)

        let root = temporary.appendingPathComponent("Store", isDirectory: true)
        let managed = root.appendingPathComponent("Files", isDirectory: true)
        let trash = root.appendingPathComponent("Discarded", isDirectory: true)
        let store = try ShelfStore(root: root)
        var notices: [String] = []
        store.onNotice = { notices.append($0) }

        // The orphan proves that a cleanup cycle actually ran before checking retention.
        let orphan = try makeDirectory(in: managed)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    _ = try await store.handle("add", payload: [
                        "paths": [source.path], "shelfId": "inbox", "storage": "copy"
                    ])
                }
            }
            try await group.waitForAll()
        }
        let imported = items(store)
        try require(imported.count == 1, "Concurrent imports created duplicate shelf items")
        try require(imported[0]["storage"] as? String == "copy", "Import did not save a managed copy")
        try require(imported[0]["sourcePath"] as? String == source.path, "Saved copy lost its original source path")
        guard let copiedPath = imported[0]["path"] as? String else { throw Failure(description: "Saved copy has no path") }
        let copied = URL(fileURLWithPath: copiedPath)
        let retainedDirectory = copied.deletingLastPathComponent()
        try require(retainedDirectory.deletingLastPathComponent().resolvingSymlinksInPath() == managed.resolvingSymlinksInPath(), "Copy was stored outside Files")
        try require(UUID(uuidString: retainedDirectory.lastPathComponent) != nil, "Managed copy directory is not a UUID")
        try await waitFor("duplicate staging directories to be collected") {
            try require(files.fileExists(atPath: copied.path), "GC deleted the retained saved copy; check canonical path comparisons")
            let folders = try children(of: managed).map(\.lastPathComponent)
            let discarded = try children(of: trash).map(\.lastPathComponent)
            return !files.fileExists(atPath: orphan.path)
                && Set(folders) == [retainedDirectory.lastPathComponent]
                && discarded.isEmpty
        }
        try require(try Data(contentsOf: copied) == contents, "Cleanup damaged the retained copy")
        print("PASS concurrent saved-copy imports retain one item and one managed directory")

        _ = try await store.handle("add", payload: [
            "paths": [secondSource.path], "shelfId": "inbox", "storage": "copy"
        ])
        let saved = items(store)
        try require(saved.count == 2, "Second saved copy was not added")
        let identifiers = saved.compactMap { $0["id"] as? String }
        let savedPaths = saved.compactMap { $0["path"] as? String }
        try require(identifiers.count == 2 && savedPaths.count == 2, "Saved copies have incomplete identities")
        let undoOrphan = try makeDirectory(in: managed)
        _ = try await store.handle("remove", payload: ["ids": identifiers])
        try require(items(store).isEmpty, "Removal left copied items in the shelf")
        try require(store.snapshot()["canUndo"] as? Bool == true, "Removal did not preserve Undo")
        try await waitFor("cleanup while Undo retains removed copies") {
            try !files.fileExists(atPath: undoOrphan.path) && children(of: trash).isEmpty
        }
        try require(savedPaths.allSatisfy { files.fileExists(atPath: $0) }, "Cleanup discarded a copy retained by Undo")

        _ = try await store.handle("createShelf", payload: ["name": "Unrelated mutation"])
        try require(store.snapshot()["canUndo"] as? Bool == false, "Unrelated mutation left stale Undo available")
        _ = try await store.handle("undo", payload: [:])
        try require(items(store).isEmpty, "Stale Undo restored removed copies after another mutation")
        try await waitFor("removed copies to be collected after Undo clears") {
            try savedPaths.allSatisfy { !files.fileExists(atPath: $0) }
                && children(of: managed).isEmpty
                && children(of: trash).isEmpty
        }
        try require(try Data(contentsOf: source) == contents, "Cleanup changed the original source")
        try require(try Data(contentsOf: secondSource) == secondContents, "Cleanup changed the second original source")
        print("PASS Undo retention, invalidation by unrelated mutation, and source-safe cleanup")

        // Cover both the native promise destination and legacy Incoming staging.
        let promiseParents = [root.appendingPathComponent("Files/Promises"), root.appendingPathComponent("Incoming")]
        var protectedDirectories: [URL] = []
        var unprotectedDirectories: [URL] = []
        for parent in promiseParents {
            let directory = try makeDirectory(in: parent)
            store.protectManagedDirectory(directory)
            protectedDirectories.append(directory)
            try contents.write(to: directory.appendingPathComponent("promised.txt"))
            unprotectedDirectories.append(try makeDirectory(in: parent))
        }
        try require(items(store).isEmpty, "Promise protection test unexpectedly has retained shelf items")
        store.startWatching()
        try await waitFor("unprotected promise staging to be collected") {
            try unprotectedDirectories.allSatisfy { !files.fileExists(atPath: $0.path) }
                && children(of: trash).isEmpty
        }
        for directory in protectedDirectories {
            try require(try Data(contentsOf: directory.appendingPathComponent("promised.txt")) == contents,
                        "Cleanup discarded an in-flight protected promise")
            try require(try children(of: directory.deletingLastPathComponent()).count == 1,
                        "Cleanup left an unprotected promise sibling")
        }
        for directory in protectedDirectories { store.releaseManagedDirectory(directory) }
        try await waitFor("released promise directories to be collected") {
            try protectedDirectories.allSatisfy { !files.fileExists(atPath: $0.path) }
                && children(of: trash).isEmpty
        }
        for parent in promiseParents {
            try require(try children(of: parent).isEmpty, "Released promise staging was not reclaimed")
        }
        try require(items(store).isEmpty, "Protecting or releasing a directory created a shelf item")
        try require(try Data(contentsOf: source) == contents, "Promise cleanup changed the original source")
        try require(notices.isEmpty, "Unexpected store notices: \(notices.joined(separator: "; "))")
        print("PASS protected Incoming and Files/Promises directories survive GC and are reclaimed on release")
    }

    private static func items(_ store: ShelfStore) -> [[String: Any]] {
        store.snapshot()["items"] as? [[String: Any]] ?? []
    }

    private static func makeDirectory(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func children(of directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    private static func waitFor(_ description: String, condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while clock.now < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(description: "Timed out waiting for \(description)")
    }
}
