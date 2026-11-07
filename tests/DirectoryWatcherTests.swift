import Foundation

// swiftc -swift-version 5 native/DirectoryWatcher.swift tests/DirectoryWatcherTests.swift -o /tmp/DirectoryWatcherTests
@main
@MainActor
struct DirectoryWatcherTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw Failure(description: message) }
    }

    private static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func until(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(description: "Timed out: \(message)") }
            try await pause(0.02)
        }
        assertions += 1
    }

    private static func directory(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ url: URL, _ text: String = "fixture", atomic: Bool = false) throws {
        try Data(text.utf8).write(to: url, options: atomic ? .atomic : [])
    }

    private static func checkIdle(_ watcher: DirectoryWatcher) async throws {
        try await until("watcher becomes idle") { watcher.isIdle }
        let scans = watcher.scanCount
        try await pause(0.8)
        try check(watcher.isIdle && watcher.pendingCount == 0, "No pending work while idle")
        try check(watcher.scanCount == scans, "Idle watcher does not poll")
    }

    static func main() async throws {
        let root = try directory(FileManager.default.temporaryDirectory, "RelayShelf-WatcherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await batchesAndBaseline(try directory(root, "batches"))
        try await boundedRetryAndRecovery(try directory(root, "retry"))
        try await nonregularPendingCleanup(try directory(root, "nonregular"))
        try await stopAndRestartDuringCallback(try directory(root, "restart"))
        print("DirectoryWatcherTests passed (\(assertions) assertions)")
    }

    private static func batchesAndBaseline(_ folder: URL) async throws {
        let existing = folder.appendingPathComponent("old.txt")
        try write(existing)
        let watcher = DirectoryWatcher(url: folder)
        defer { watcher.stop() }
        var deliveries: [String: Int] = [:]
        var batchSizes: [Int] = []
        var errors: [String] = []
        watcher.onError = { errors.append($0) }
        watcher.onFiles = { urls in
            batchSizes.append(urls.count)
            for url in urls { deliveries[url.path, default: 0] += 1 }
            return Set(urls.map(\.path))
        }
        try check(watcher.start(), "Start directory watcher")
        try await until("initial listing") { watcher.scanCount > 0 && watcher.isIdle }
        try check(deliveries.isEmpty, "Ignore the initial listing")
        let baselineScans = watcher.scanCount
        try await pause(0.4)
        try check(watcher.scanCount == baselineScans, "Baseline watcher has no recurring timer")
        for index in 0..<501 { try write(folder.appendingPathComponent("arrival-\(index).txt")) }
        try write(folder.appendingPathComponent("ignored.tmp"))
        try write(folder.appendingPathComponent(".hidden.txt"))
        try await until("501 arrivals acknowledged") { deliveries.count == 501 && watcher.isIdle }
        try check(batchSizes.count == 6, "501 arrivals require six bounded deliveries")
        try check(batchSizes.allSatisfy { (1...100).contains($0) }, "Callbacks contain at most 100 URLs")
        try check(deliveries.values.allSatisfy { $0 == 1 }, "Acknowledged paths are not redelivered")
        try check(deliveries.keys.allSatisfy { $0.hasPrefix("/") }, "Delivery paths are absolute")
        try check(deliveries[existing.path] == nil, "Old files remain ignored")
        let calls = batchSizes.count
        try write(existing, "changed old contents", atomic: true)
        try write(folder.appendingPathComponent("arrival-0.txt"), "changed acknowledged contents", atomic: true)
        try await pause(0.8)
        try await checkIdle(watcher)
        try check(batchSizes.count == calls, "Modified or replaced known filenames are not reimported")
        try check(errors.isEmpty, "Successful batches do not report errors")
    }

    private static func boundedRetryAndRecovery(_ folder: URL) async throws {
        let watcher = DirectoryWatcher(url: folder)
        defer { watcher.stop() }
        let success = folder.appendingPathComponent("success.txt")
        let failure = folder.appendingPathComponent("failure.txt")
        var attempts: [String: Int] = [:]
        var failureTimes: [TimeInterval] = []
        var errors: [String] = []
        var recover = false
        watcher.onError = { errors.append($0) }
        watcher.onFiles = { urls in
            var acknowledged: Set<String> = [folder.appendingPathComponent("not-delivered.txt").path]
            for url in urls {
                attempts[url.path, default: 0] += 1
                if url.path == failure.path {
                    failureTimes.append(ProcessInfo.processInfo.systemUptime)
                    if recover { acknowledged.insert(url.path) }
                } else { acknowledged.insert(url.path) }
            }
            return acknowledged
        }
        try check(watcher.start(), "Start retry watcher")
        try await until("retry baseline") { watcher.scanCount > 0 && watcher.isIdle }
        try write(success)
        try write(failure)
        try await until("retry exhaustion") { errors.count == 1 && watcher.isIdle }
        try check(attempts[success.path] == 1, "Partial acknowledgments prevent successful-file retries")
        try check(attempts[failure.path] == 3, "Exactly three total failed attempts")
        try check(failureTimes[1] - failureTimes[0] >= 0.95, "First retry backs off one second")
        try check(failureTimes[2] - failureTimes[1] >= 1.95, "Second retry backs off two seconds")
        try check(errors[0].contains("failure.txt"), "Exhaustion identifies the failed file")
        try await checkIdle(watcher)
        try await pause(1.3)
        try check(attempts[failure.path] == 3 && errors.count == 1, "No eternal retries or repeated error notices")

        watcher.stop()
        try check(watcher.start(), "Toggle exhausted watcher")
        try await until("toggle rearms exhausted arrivals") { attempts[failure.path] == 6 && errors.count == 2 && watcher.isIdle }
        try check(attempts[success.path] == 1, "Toggle still ignores acknowledged and pre-existing files")
        try await checkIdle(watcher)

        // In-place writes do not change the parent directory, so failed files need their own event source.
        recover = true
        let handle = try FileHandle(forWritingTo: failure)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()
        try await until("failed-file change rearms delivery") { attempts[failure.path] == 7 && watcher.isIdle }
        try check(errors.count == 2, "Successful recovery does not report another error")
        try await checkIdle(watcher)
    }

    private static func nonregularPendingCleanup(_ folder: URL) async throws {
        let target = folder.appendingPathComponent("old-target.txt")
        try write(target)
        let watcher = DirectoryWatcher(url: folder)
        defer { watcher.stop() }
        var deliveries = 0
        watcher.onFiles = { urls in deliveries += urls.count; return Set(urls.map(\.path)) }
        try check(watcher.start(), "Start nonregular watcher")
        try await until("nonregular baseline") { watcher.scanCount > 0 && watcher.isIdle }
        for symlink in [false, true] {
            let candidate = folder.appendingPathComponent(symlink ? "becomes-link.txt" : "becomes-directory.txt")
            try write(candidate)
            try await until("file enters pending", timeout: 4) { watcher.pendingCount == 1 }
            try FileManager.default.removeItem(at: candidate)
            if symlink { try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target) }
            else { try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false) }
            try await checkIdle(watcher)
            try check(deliveries == 0, "A pending file replaced by a nonregular entry is never delivered")
        }
    }

    private static func stopAndRestartDuringCallback(_ folder: URL) async throws {
        let watcher = DirectoryWatcher(url: folder)
        defer { watcher.stop() }
        var enteredOld = false
        var enteredNew = false
        var oldGate: CheckedContinuation<Void, Never>?
        var newGate: CheckedContinuation<Void, Never>?
        var calls = 0
        // Always release callbacks if an assertion throws.
        defer { oldGate?.resume(); newGate?.resume() }
        watcher.onFiles = { urls in
            calls += 1
            if urls.contains(where: { $0.lastPathComponent == "old.txt" }) {
                enteredOld = true
                await withCheckedContinuation { oldGate = $0 }
            } else {
                enteredNew = true
                await withCheckedContinuation { newGate = $0 }
            }
            return Set(urls.map(\.path))
        }
        try check(watcher.start(), "Start callback watcher")
        try await until("callback baseline") { watcher.scanCount > 0 && watcher.isIdle }
        try write(folder.appendingPathComponent("old.txt"))
        try await until("first callback suspended") { enteredOld }
        try write(folder.appendingPathComponent("queued.txt"))
        try await pause(0.6)
        try check(calls == 1 && !watcher.isIdle, "Events during a callback do not start overlapping delivery")
        watcher.stop()
        try check(watcher.isIdle && watcher.pendingCount == 0, "Stop clears pending work")
        let scans = watcher.scanCount
        try check(watcher.start(), "Restart watcher")
        try await until("restart baseline") { watcher.scanCount > scans && watcher.isIdle }
        try write(folder.appendingPathComponent("new.txt"))
        try await until("new-generation callback suspended") { enteredNew }
        oldGate?.resume(); oldGate = nil
        try await pause(0.15)
        try check(!watcher.isIdle && watcher.pendingCount == 1, "Stale acknowledgment cannot finish a new-generation task")
        newGate?.resume(); newGate = nil
        try await checkIdle(watcher)
        try check(calls == 2, "Restart ignores the old baseline and delivers only the new arrival")
    }
}
