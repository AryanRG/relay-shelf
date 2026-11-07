import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Invoke only from an explicit user action. Returned files belong to the caller:
/// import/copy them, then remove their UUID parent directory when no longer needed.
/// No pasteboard APIs, shell interpolation, or automatic shortcut execution.
enum SystemActions {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Command: Sendable {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
        var outputDirectory: URL? = nil
    }

    struct CommandResult: Sendable {
        var status: Int32 = 0
        var stdout = Data()
        var stderr = Data()
    }

    /// Per-call injection avoids changing global executable paths in a shared app.
    struct Dependencies: Sendable {
        var screencapture = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var shortcuts = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var canCapture: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
        var requestCaptureAccess: @MainActor @Sendable () -> Bool = { CGRequestScreenCaptureAccess() }
        var runner: @Sendable (Command) async throws -> CommandResult = { try await runProcess($0) }
        var captureTimeout: TimeInterval = 120
        var shortcutTimeout: TimeInterval = 180
        var listTimeout: TimeInterval = 15
    }

    static let maximumLogBytes = 64 * 1024 // per stream; exceeding the cap fails, never truncates a name
    static let maximumOutputBytes: Int64 = 128 * 1024 * 1024
    static let maximumOutputFiles = 100
    private static let captureGate = CaptureGate()
    private static let permissionMessage = "Screenshot access is unavailable. Allow Relay Shelf in System Settings → Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS), then reopen the app."

    static func captureScreenshot(outputDirectory: URL) async throws -> [URL] {
        try await captureScreenshot(outputDirectory: outputDirectory, using: Dependencies())
    }

    static func listShortcuts() async throws -> [String] {
        try await listShortcuts(using: Dependencies())
    }

    static func runShortcut(name: String, urls: [URL], outputDirectory: URL) async throws -> [URL] {
        try await runShortcut(name: name, urls: urls, outputDirectory: outputDirectory, using: Dependencies())
    }

    static func captureScreenshot(outputDirectory: URL, using dependencies: Dependencies) async throws -> [URL] {
        guard captureGate.acquire() else { throw Failure(message: "A screenshot selection is already open. Finish or cancel it first.") }
        defer { captureGate.release() }
        if Task.isCancelled { return [] }
        if !dependencies.canCapture() {
            // Only an explicit capture invocation reaches here. The request registers
            // the app with TCC; approval can still require an app restart.
            _ = await dependencies.requestCaptureAccess()
            if Task.isCancelled { return [] }
            guard dependencies.canCapture() else { throw Failure(message: permissionMessage) }
        }
        let directory = try freshDirectory(in: outputDirectory)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        do {
            let destination = directory.appendingPathComponent("Screenshot.png")
            let result = try await dependencies.runner(Command(executable: dependencies.screencapture,
                arguments: ["-i", "-x", destination.path], timeout: dependencies.captureTimeout, outputDirectory: directory))
            try Task.checkCancellation()
            let files = try outputFiles(in: directory)
            try Task.checkCancellation()
            let diagnostic = diagnostic(result)
            // Escape commonly exits 1 with no output or diagnostic. Never hide a permission failure.
            if files.isEmpty, (result.status == 0 || (result.status == 1 && diagnostic.isEmpty)) {
                guard dependencies.canCapture() else { throw Failure(message: permissionMessage) }
                return []
            }
            guard result.status == 0 else {
                throw Failure(message: "Screenshot capture failed (exit \(result.status)). \(diagnostic) \(permissionMessage)")
            }
            keep = !files.isEmpty
            return files
        } catch is CancellationError { return [] }
    }

    static func listShortcuts(using dependencies: Dependencies) async throws -> [String] {
        try Task.checkCancellation()
        let result = try await dependencies.runner(Command(executable: dependencies.shortcuts,
            arguments: ["list"], timeout: dependencies.listTimeout))
        try Task.checkCancellation()
        try requireSuccess(result, action: "Listing Shortcuts")
        guard result.stdout.count <= maximumLogBytes, let text = String(data: result.stdout, encoding: .utf8) else {
            throw Failure(message: "Shortcuts returned an oversized or invalid UTF-8 list.")
        }
        // Preserve Unicode and significant spaces. The CLI has one name per LF/CRLF line.
        var names: [String] = []
        for part in text.components(separatedBy: "\n") {
            var name = part
            if name.hasSuffix("\r") { name.removeLast() }
            if name.isEmpty { continue }
            guard !name.contains("\0"), name.utf8.count <= 4096, names.count < 1000 else {
                throw Failure(message: "Shortcuts returned more than 1,000 names or an invalid shortcut name.")
            }
            names.append(name)
        }
        return names
    }

    static func runShortcut(name: String, urls: [URL], outputDirectory: URL, using dependencies: Dependencies) async throws -> [URL] {
        try Task.checkCancellation()
        guard !name.isEmpty, name.utf8.count <= 4096, !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw Failure(message: "Choose a valid installed shortcut name.")
        }
        guard !urls.isEmpty, urls.count <= 100 else { throw Failure(message: "Select between 1 and 100 files to send to the shortcut.") }
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  !url.path.contains("\0"), url.path.utf8.count <= 4096,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(message: "A selected shortcut input is not an available local file.")
            }
        }
        let directory = try freshDirectory(in: outputDirectory)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        // Apple documents --output-path as a *file* destination, with the extension
        // influencing conversion. An extensionless, initially absent path keeps the
        // content's default type; do not assume stdout is a list of output paths.
        // https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac
        let destination = directory.appendingPathComponent("Result")
        // Options precede the terminator: putting -- before NAME and then appending
        // options would turn those options into additional positional arguments.
        var arguments = ["run", "--output-path", destination.path, "--input-path"]
        arguments.append(contentsOf: urls.map { $0.standardizedFileURL.path })
        arguments += ["--", name]
        let result = try await dependencies.runner(Command(executable: dependencies.shortcuts,
            arguments: arguments, timeout: dependencies.shortcutTimeout, outputDirectory: directory))
        try Task.checkCancellation()
        try requireSuccess(result, action: "Running shortcut “\(name)”")
        let files = try outputFiles(in: directory)
        let typedFiles = try files.map { try addUsefulExtension(to: $0, destination: destination) }
        try Task.checkCancellation()
        keep = !typedFiles.isEmpty
        return typedFiles // A successful shortcut need not produce a file.
    }

    private static func requireSuccess(_ result: CommandResult, action: String) throws {
        guard result.status == 0 else {
            let detail = diagnostic(result)
            throw Failure(message: "\(action) failed (exit \(result.status))." + (detail.isEmpty ? "" : " \(detail)"))
        }
    }

    private static func diagnostic(_ result: CommandResult) -> String {
        let data = result.stderr.isEmpty ? result.stdout : result.stderr
        return String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Do not coerce the shortcut's output type with a predetermined CLI extension.
    /// Only the CLI's generic Result file is renamed; user-supplied names survive.
    /// Unknown binary formats remain extensionless. No external type/preview tools run.
    private static func addUsefulExtension(to file: URL, destination: URL) throws -> URL {
        guard file.standardizedFileURL.path == destination.standardizedFileURL.path, file.pathExtension.isEmpty else { return file }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
        var type: UTType?
        if prefix.starts(with: Data("%PDF-".utf8)) { type = .pdf }
        else if let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                let identifier = CGImageSourceGetType(source) { type = UTType(identifier as String) }
        else if !prefix.isEmpty, let text = String(data: prefix, encoding: .utf8),
                !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size <= prefix.count, (try? JSONSerialization.jsonObject(with: prefix, options: [.fragmentsAllowed])) != nil { type = .json }
            else { type = .plainText }
        }
        guard let ext = type?.preferredFilenameExtension, !ext.isEmpty,
              ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return file }
        let renamed = file.appendingPathExtension(ext)
        guard !FileManager.default.fileExists(atPath: renamed.path) else { return file }
        try FileManager.default.moveItem(at: file, to: renamed)
        return renamed
    }

    private static func freshDirectory(in parent: URL) throws -> URL {
        guard parent.isFileURL, !parent.path.contains("\0"), parent.host == nil || parent.host == "" || parent.host == "localhost" else {
            throw Failure(message: "Choose a local output directory.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.standardizedFileURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Bounded, non-following traversal. Used during the process as well as after it.
    /// These are app limits, not a sandbox for arbitrary user-authored shortcuts.
    static func outputFiles(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var rootStat = stat()
        guard lstat(directory.path, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "The action output directory is unavailable or was replaced.")
        }
        var result: [URL] = []
        var bytes: Int64 = 0
        var entries = 0
        var enumerationError: Error?
        guard let iterator = manager.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw Failure(message: "Could not read action output.")
        }
        while let item = iterator.nextObject() as? URL {
            entries += 1
            guard entries <= 512, iterator.level <= 16 else { throw Failure(message: "Action output exceeds the directory limit.") }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw Failure(message: "Could not inspect action output.") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: break
            case S_IFREG:
                guard info.st_nlink == 1 else { throw Failure(message: "Action output contains an unsupported hard link.") }
                bytes += info.st_size
                result.append(item)
                guard bytes <= maximumOutputBytes, result.count <= maximumOutputFiles else {
                    throw Failure(message: "Action output exceeds 100 files or 128 MB.")
                }
            default: throw Failure(message: "Action output contains a symbolic link or unsupported file type.")
            }
        }
        if enumerationError != nil { throw Failure(message: "Could not read all action output.") }
        return result.sorted { $0.path < $1.path }
    }

    private final class CaptureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        func acquire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !active else { return false }
            active = true
            return true
        }
        func release() { lock.lock(); active = false; lock.unlock() }
    }

    static func runProcess(_ command: Command) async throws -> CommandResult {
        let job = ProcessJob(command)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { job.start($0) }
        }, onCancel: { job.cancel() })
    }

    /// All mutable state lives on one serial queue. posix_spawn creates an isolated
    /// process group atomically; cancellation cannot race a later setpgid call.
    /// Nonblocking pipes + waitpid(WNOHANG) never occupy the caller/main actor.
    private final class ProcessJob: @unchecked Sendable {
        private let command: Command
        private let queue = DispatchQueue(label: "RelayShelf.SystemAction", qos: .userInitiated)
        private var continuation: CheckedContinuation<CommandResult, Error>?
        private var timer: DispatchSourceTimer?
        private var pid: pid_t = 0
        private var readers: [Int32] = []
        private var logs = [Data(), Data()]
        private var cancelled = false
        private var failure: Error?
        private var reaped = false
        private var status: Int32 = 0
        private var started: TimeInterval = 0
        private var stopping: TimeInterval?
        private var lastOutputCheck: TimeInterval = 0

        init(_ command: Command) { self.command = command }
        func cancel() { queue.async { self.cancelled = true; self.stop(CancellationError()) } }
        func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
            queue.async {
                self.continuation = continuation
                if self.cancelled { self.finish(.failure(CancellationError())); return }
                do {
                    try self.spawn()
                    self.started = ProcessInfo.processInfo.systemUptime
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
                    timer.setEventHandler { self.tick() }
                    self.timer = timer
                    timer.resume()
                } catch { self.finish(.failure(error)) }
            }
        }

        private func spawn() throws {
            guard command.executable.isFileURL, !command.executable.path.contains("\0"),
                command.arguments.allSatisfy({ !$0.contains("\0") }),
                command.timeout.isFinite, command.timeout > 0 else { throw Failure(message: "Invalid system action command.") }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure(message: "Could not initialize system action.") }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { throw Failure(message: "Could not initialize system action attributes.") }
            defer { posix_spawnattr_destroy(&attributes) }
            var descriptors: [Int32] = []
            var readEnds: [Int32] = []
            defer { for fd in descriptors { close(fd) } }
            func check(_ code: Int32) throws {
                if code != 0 { throw Failure(message: "Could not launch \(command.executable.lastPathComponent): \(String(cString: strerror(code)))") }
            }
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            for target in [STDOUT_FILENO, STDERR_FILENO] {
                var pair: [Int32] = [0, 0]
                guard pipe(&pair) == 0 else { throw Failure(message: "Could not create system action pipes.") }
                descriptors += pair
                for fd in pair { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure(message: "Could not configure system action pipe.") } }
                guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw Failure(message: "Could not configure nonblocking action output.") }
                try check(posix_spawn_file_actions_adddup2(&actions, pair[1], target))
                try check(posix_spawn_file_actions_addclose(&actions, pair[0]))
                try check(posix_spawn_file_actions_addclose(&actions, pair[1]))
                readEnds.append(pair[0])
            }
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            let argv = ([command.executable.path] + command.arguments).map { strdup($0) }
            defer { for value in argv { free(value) } }
            let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            defer { for value in environment { free(value) } }
            var environmentPointers = environment + [nil]
            var terminated = argv + [nil]
            let code = terminated.withUnsafeMutableBufferPointer { buffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(&pid, command.executable.path, &actions, &attributes, buffer.baseAddress!, environmentBuffer.baseAddress!)
                }
            }
            try check(code)
            readers = readEnds
            // Transfer read-end ownership; close parent write ends immediately.
            descriptors.removeAll { readers.contains($0) }
        }

        private func drain(_ index: Int) {
            guard readers.indices.contains(index) else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Fairness bound allows timeout/cancellation even with infinite output.
            for _ in 0..<8 {
                let count = read(readers[index], &buffer, buffer.count)
                if count > 0 {
                    let remaining = maximumLogBytes - logs[index].count
                    logs[index].append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { stop(Failure(message: "System action exceeded the 64 KB output limit.")); return }
                } else if count < 0 && errno == EINTR { continue }
                else { return }
            }
        }

        private func stop(_ error: Error?) {
            if failure == nil { failure = error }
            guard pid > 0, stopping == nil else { return }
            stopping = ProcessInfo.processInfo.systemUptime
            kill(-pid, SIGTERM)
        }

        private func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            drain(0); drain(1)
            if now - started >= command.timeout { stop(Failure(message: "\(command.executable.lastPathComponent) timed out after \(Int(command.timeout)) seconds.")) }
            if failure == nil, let directory = command.outputDirectory, now - lastOutputCheck >= 0.2 {
                lastOutputCheck = now
                do { _ = try outputFiles(in: directory) } catch { stop(error) }
            }
            if !reaped {
                var raw: Int32 = 0
                let result = waitpid(pid, &raw, WNOHANG)
                if result == pid { reaped = true; status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f) }
                else if result < 0 && errno != EINTR { reaped = true; stop(Failure(message: "Could not collect system action exit status.")) }
            }
            if reaped {
                drain(0); drain(1)
                // Even a successful leader must not leave descendants holding pipes.
                if stopping == nil && kill(-pid, 0) == 0 { stop(nil) }
                if stopping == nil { finishResult(); return }
            }
            if let stopping, now - stopping >= 0.3 {
                kill(-pid, SIGKILL) // escalation also covers a leader ignoring SIGTERM
                if reaped { finishResult() }
            }
        }

        private func finishResult() {
            if let failure {
                if let actionFailure = failure as? Failure, !logs[1].isEmpty {
                    let detail = String(decoding: logs[1].prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(.failure(Failure(message: actionFailure.message + (detail.isEmpty ? "" : " \(detail)"))))
                } else { finish(.failure(failure)) }
            }
            else { finish(.success(CommandResult(status: status, stdout: logs[0], stderr: logs[1]))) }
        }

        private func finish(_ result: Result<CommandResult, Error>) {
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            for fd in readers { close(fd) }
            readers.removeAll()
            pid = 0
            let completion = continuation
            continuation = nil
            completion?.resume(with: result)
        }
    }
}
