import Foundation
import Darwin

@MainActor
final class DirectoryWatcher {
    private struct Stamp: Equatable, Sendable {
        let size: UInt64
        let modified: TimeInterval
        let isFile: Bool
    }
    private struct Pending {
        let stamp: Stamp
        let stableSince: TimeInterval
        var attempts = 0
        var nextAttemptAt: TimeInterval = 0
    }

    private static let batchSize = 100
    private static let maximumAttempts = 3
    private static let settleInterval: TimeInterval = 1.5
    let url: URL
    /// Return only absolute paths durably imported (or intentionally ignored).
    var onFiles: (([URL]) async -> Set<String>)?
    var onError: ((String) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var scanTask: Task<Void, Never>?
    private var known: [String: Stamp]?
    private var pending: [String: Pending] = [:]
    private var failed: [String: Stamp] = [:]
    private var failedSources: [String: DispatchSourceFileSystemObject] = [:]
    private var retryOnRestart = Set<String>()
    private var rescanNeeded = false
    private var generation: UInt64 = 0

    // Internal diagnostics also let the standalone tests verify that polling actually stops.
    private(set) var scanCount = 0
    var pendingCount: Int { pending.count }
    var isIdle: Bool { scanTask == nil && pending.isEmpty && !rescanNeeded }

    init(url: URL) { self.url = url.standardizedFileURL }

    func start() -> Bool {
        guard source == nil else { return true }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { onError?("Could not watch \(url.lastPathComponent). Check folder access."); return false }
        generation &+= 1
        let currentGeneration = generation
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, self.generation == currentGeneration, let source = self.source else { return }
            if !source.data.isDisjoint(with: [.rename, .delete, .revoke]) {
                self.stop()
                self.onError?("Watching paused because \(self.url.lastPathComponent) became unavailable. Toggle the watcher to reconnect it.")
                return
            }
            self.requestScan()
        }
        watcher.setCancelHandler { close(descriptor) }
        source = watcher
        watcher.resume()
        schedule(delay: 0)
        return true
    }

    func stop() {
        generation &+= 1
        // Retain exhausted arrivals for a stop/start toggle of this watcher instance.
        retryOnRestart.formUnion(failed.keys)
        scanTask?.cancel(); scanTask = nil
        source?.cancel(); source = nil
        for source in failedSources.values { source.cancel() }
        failedSources.removeAll()
        known = nil; pending.removeAll(); failed.removeAll()
        rescanNeeded = false
    }

    private func requestScan() {
        guard source != nil else { return }
        if scanTask == nil { schedule(delay: 0.25) } else { rescanNeeded = true }
    }

    private func schedule(delay: TimeInterval) {
        guard source != nil, scanTask == nil else { return }
        let folder = url
        let currentGeneration = generation
        rescanNeeded = false
        scanTask = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            guard let self, self.isActive(currentGeneration) else { return }
            self.scanCount += 1
            let listing = await Task.detached(priority: .utility) { Self.list(folder) }.value
            guard !Task.isCancelled, self.isActive(currentGeneration) else { return }
            // Keep scanTask occupied across awaits: callbacks and scans must not overlap.
            await self.apply(listing, generation: currentGeneration)
            guard !Task.isCancelled, self.isActive(currentGeneration) else { return }
            self.scanTask = nil
            if self.rescanNeeded { self.schedule(delay: 0.25) }
            else if let delay = self.nextDelay() { self.schedule(delay: delay) }
        }
    }

    private func isActive(_ value: UInt64) -> Bool { generation == value && source != nil }

    private func nextDelay() -> TimeInterval? {
        let now = ProcessInfo.processInfo.systemUptime
        return pending.values.map { item in
            item.attempts == 0
                ? max(0.01, min(0.5, Self.settleInterval - (now - item.stableSince)))
                : max(0.01, item.nextAttemptAt - now)
        }.min()
    }

    private func apply(_ entries: [String: Stamp]?, generation currentGeneration: UInt64) async {
        guard let entries else {
            stop(); onError?("The watched folder \(url.lastPathComponent) could not be read."); return
        }
        guard let known else {
            // New arrivals only: pre-existing files, including later edits to them, are ignored.
            // Exhausted arrivals retained by a stop/start toggle are the sole baseline exception.
            self.known = entries.filter { !retryOnRestart.contains($0.key) }
            let now = ProcessInfo.processInfo.systemUptime
            for name in retryOnRestart {
                if let stamp = entries[name], stamp.isFile { pending[name] = Pending(stamp: stamp, stableSince: now) }
            }
            retryOnRestart.removeAll()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        for name in Array(pending.keys) where entries[name]?.isFile != true || known[name] != nil {
            pending.removeValue(forKey: name)
        }
        for (name, stamp) in failed where entries[name] != stamp || entries[name]?.isFile != true {
            failed.removeValue(forKey: name)
            cancelFailedSource(name)
        }
        var ready: [(name: String, stamp: Stamp)] = []
        for (name, stamp) in entries where known[name] == nil && stamp.isFile {
            guard failed[name] != stamp else { continue }
            if let previous = pending[name], previous.stamp == stamp {
                if now - previous.stableSince >= Self.settleInterval && now >= previous.nextAttemptAt {
                    ready.append((name, stamp))
                }
            } else { pending[name] = Pending(stamp: stamp, stableSince: now) }
        }
        // An observed deletion permits a later recreation; edits to known names do not.
        self.known = self.known?.filter { entries[$0.key] != nil }
        ready.sort { $0.name < $1.name }
        for start in stride(from: 0, to: ready.count, by: Self.batchSize) {
            let batch = Array(ready[start..<min(start + Self.batchSize, ready.count)])
            let urls = batch.map { url.appendingPathComponent($0.name) }
            let acknowledged = await onFiles?(urls) ?? []
            guard !Task.isCancelled, isActive(currentGeneration) else { return }
            var exhausted: [String] = []
            for (entry, location) in zip(batch, urls) {
                guard var item = pending[entry.name], item.stamp == entry.stamp else { continue }
                if acknowledged.contains(location.path) {
                    self.known?[entry.name] = entry.stamp
                    pending.removeValue(forKey: entry.name)
                } else {
                    item.attempts += 1
                    if item.attempts >= Self.maximumAttempts {
                        pending.removeValue(forKey: entry.name)
                        failed[entry.name] = entry.stamp
                        observeFailedFile(entry.name, generation: currentGeneration)
                        exhausted.append(entry.name)
                    } else {
                        // Three total attempts, with one- and two-second retry backoffs.
                        item.nextAttemptAt = ProcessInfo.processInfo.systemUptime + pow(2, Double(item.attempts - 1))
                        pending[entry.name] = item
                    }
                }
            }
            if !exhausted.isEmpty {
                onError?("Could not import \(exhausted.count) file(s) after \(Self.maximumAttempts) attempts: \(exhausted.prefix(5).joined(separator: ", ")). Waiting for a file change or watcher toggle.")
                guard !Task.isCancelled, isActive(currentGeneration) else { return }
            }
        }
    }

    private func cancelFailedSource(_ name: String) {
        failedSources.removeValue(forKey: name)?.cancel()
    }

    private func observeFailedFile(_ name: String, generation currentGeneration: UInt64) {
        cancelFailedSource(name)
        let descriptor = open(url.appendingPathComponent(name).path, O_EVTONLY)
        // One final reconciliation catches changes during the callback/registration window.
        rescanNeeded = true
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self, self.isActive(currentGeneration), self.failed[name] != nil else { return }
            self.failed.removeValue(forKey: name)
            self.cancelFailedSource(name)
            self.requestScan()
        }
        watcher.setCancelHandler { close(descriptor) }
        failedSources[name] = watcher
        watcher.resume()
    }

    nonisolated private static func list(_ directory: URL) -> [String: Stamp]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var result: [String: Stamp] = [:]
        for name in names where !name.hasPrefix(".") && ![".download", ".crdownload", ".part", ".tmp", ".partial"].contains(where: { name.lowercased().hasSuffix($0) }) {
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            // Foundation attributes can read extended attributes and block on File Provider files.
            // No-follow POSIX metadata keeps symlinks distinct from regular files.
            var metadata = Darwin.stat()
            guard path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0 else { continue }
            result[name] = Stamp(size: UInt64(max(0, metadata.st_size)),
                                 modified: TimeInterval(metadata.st_mtimespec.tv_sec)
                                    + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000,
                                 isFile: metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        }
        return result
    }
}
