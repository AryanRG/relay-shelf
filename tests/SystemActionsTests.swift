import Foundation
import Darwin

// Standalone, controlled fixtures only. Never invokes screencapture or an installed shortcut.
// swiftc -swift-version 5 native/SystemActions.swift tests/SystemActionsTests.swift -o /tmp/relay-system-actions-tests
// /tmp/relay-system-actions-tests
@main
struct SystemActionsTests {
    struct TestFailure: Error, CustomStringConvertible { let description: String }
    static let manager = FileManager.default

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(description: message) }
    }

    static func failure(_ operation: () async throws -> Void) async throws -> Error {
        do { try await operation() }
        catch { return error }
        throw TestFailure(description: "Expected operation to fail")
    }

    actor Recorder {
        var commands: [SystemActions.Command] = []
        let response: @Sendable (SystemActions.Command) throws -> SystemActions.CommandResult
        init(_ response: @escaping @Sendable (SystemActions.Command) throws -> SystemActions.CommandResult) { self.response = response }
        func run(_ command: SystemActions.Command) throws -> SystemActions.CommandResult {
            commands.append(command)
            return try response(command)
        }
        func all() -> [SystemActions.Command] { commands }
    }

    static func injected(_ recorder: Recorder) -> SystemActions.Dependencies {
        var dependencies = SystemActions.Dependencies()
        dependencies.screencapture = URL(fileURLWithPath: "/fake tools/screen capture")
        dependencies.shortcuts = URL(fileURLWithPath: "/fake tools/short cuts")
        dependencies.canCapture = { true }
        dependencies.requestCaptureAccess = { false }
        dependencies.runner = { try await recorder.run($0) }
        return dependencies
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--fixture" { try fixture(Array(arguments.dropFirst())); return }
        let root = manager.temporaryDirectory.appendingPathComponent("RelayShelf-SystemActions-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try await testNames()
        try await testShortcutArgumentsAndOutput(root)
        try await testScreenshot(root)
        try await testOutputBounds(root)
        try await testRealRunner(root)
        print("PASS SystemActions: names, argv safety, output/no output, permissions, overlap, cancellation, timeouts, log/disk bounds, process cleanup")
    }

    static func testNames() async throws {
        let recorder = Recorder { _ in .init(stdout: Data("Combine Images\r\n資料 🦊\n--help\n  significant spaces  \n\n".utf8)) }
        let names = try await SystemActions.listShortcuts(using: injected(recorder))
        try require(names == ["Combine Images", "資料 🦊", "--help", "  significant spaces  "], "Unicode/CRLF/space/name parsing")
        let commands = await recorder.all()
        try require(commands.count == 1 && commands[0].arguments == ["list"], "Listing never runs a shortcut")
        for bytes in [Data(repeating: 65, count: SystemActions.maximumLogBytes + 1), Data([0xff]), Data((0..<1001).map { "name\($0)\n" }.joined().utf8)] {
            let bad = Recorder { _ in .init(stdout: bytes) }
            _ = try await failure { _ = try await SystemActions.listShortcuts(using: injected(bad)) }
        }
        let denied = Recorder { _ in .init(status: 1, stderr: Data("Shortcuts permission denied".utf8)) }
        let error = try await failure { _ = try await SystemActions.listShortcuts(using: injected(denied)) }
        try require(error.localizedDescription.contains("permission denied"), "Keep CLI diagnostics")
    }

    static func testShortcutArgumentsAndOutput(_ root: URL) async throws {
        let parent = root.appendingPathComponent("shortcut outputs")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("MUST NOT EXIST")
        let inputs = [root.appendingPathComponent("--option 資料.txt"), root.appendingPathComponent("file $(whoami); `id` 'quotes'.txt")]
        for input in inputs { try Data("input".utf8).write(to: input) }
        let existing = parent.appendingPathComponent("existing.txt")
        try Data("leave alone".utf8).write(to: existing)
        let recorder = Recorder { command in
            let output = URL(fileURLWithPath: command.arguments[2])
            try Data("generated result".utf8).write(to: output)
            return .init(stdout: Data("stdout is not a file path".utf8))
        }
        let dependencies = injected(recorder)
        for name in ["Combine Images", "--help", "-i", "--", "資料 🦊", "$(touch \(sentinel.path)); `whoami` & 'quote'"] {
            let files = try await SystemActions.runShortcut(name: name, urls: inputs, outputDirectory: parent, using: dependencies)
            try require(files.count == 1 && files[0].lastPathComponent == "Result.txt", "Return actual file with inferred text extension, not stdout: \(files)")
            let commands = await recorder.all()
            let command = commands.last!
            try require(command.executable == dependencies.shortcuts, "Injected executable used")
            let expected = ["run", "--output-path", command.outputDirectory!.appendingPathComponent("Result").path, "--input-path"] + inputs.map { $0.standardizedFileURL.path } + ["--", name]
            try require(command.arguments == expected, "All flags before separator, names/paths remain individual argv: \(command.arguments) vs \(expected)")
            try require(files[0].deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == parent.resolvingSymlinksInPath(), "Fresh child of supplied parent")
            try require(UUID(uuidString: files[0].deletingLastPathComponent().lastPathComponent) != nil, "UUID output directory")
        }
        let commands = await recorder.all()
        try require(Set(commands.map { $0.outputDirectory! }).count == 6, "Fresh directory per invocation")
        try require(!manager.fileExists(atPath: sentinel.path), "No injection executed")
        try require(try Data(contentsOf: existing) == Data("leave alone".utf8), "Existing outputs untouched")

        let noOutputParent = root.appendingPathComponent("no-output")
        let empty = Recorder { _ in .init(stdout: Data("a successful message, not output".utf8)) }
        let noOutput = try await SystemActions.runShortcut(name: "None", urls: inputs, outputDirectory: noOutputParent, using: injected(empty))
        try require(noOutput.isEmpty, "Successful no-output shortcut returns []")
        try require(try manager.contentsOfDirectory(atPath: noOutputParent.path).isEmpty, "No-output staging cleaned")
        let failed = Recorder { command in
            try Data("partial".utf8).write(to: command.outputDirectory!.appendingPathComponent("partial"))
            return .init(status: 1, stderr: Data("Specific shortcut failure".utf8))
        }
        let error = try await failure { _ = try await SystemActions.runShortcut(name: "Bad", urls: inputs, outputDirectory: noOutputParent, using: injected(failed)) }
        try require(error.localizedDescription.contains("Specific shortcut failure"), "Shortcut failure diagnostic")
        try require(try manager.contentsOfDirectory(atPath: noOutputParent.path).isEmpty, "Partial outputs cleaned on failure")
        for badName in ["", "NUL\0name", "line\nname"] {
            _ = try await failure { _ = try await SystemActions.runShortcut(name: badName, urls: inputs, outputDirectory: parent, using: dependencies) }
        }
        _ = try await failure { _ = try await SystemActions.runShortcut(name: "Valid", urls: [], outputDirectory: parent, using: dependencies) }
        _ = try await failure { _ = try await SystemActions.runShortcut(name: "Valid", urls: [URL(string: "https://example.com/input")!], outputDirectory: parent, using: dependencies) }
        let validatedCommands = await recorder.all()
        try require(validatedCommands.count == 6, "Invalid inputs never invoke a tool")

        let multi = Recorder { command in
            let directory = command.outputDirectory!.appendingPathComponent("Result", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data().write(to: directory.appendingPathComponent("b.txt"))
            try Data("a".utf8).write(to: directory.appendingPathComponent("a.txt"))
            return .init()
        }
        let multiple = try await SystemActions.runShortcut(name: "Multiple", urls: inputs, outputDirectory: parent, using: injected(multi))
        try require(multiple.map(\.lastPathComponent) == ["a.txt", "b.txt"], "Return nested file outputs in stable order, including empty files")

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=")!
        for (data, ext) in [(Data("%PDF-1.7\nfixture".utf8), "pdf"), (Data("{\"test\":true}".utf8), "json"), (png, "png"), (Data([0xff, 0, 0x80]), "")] {
            let typed = Recorder { command in
                try data.write(to: command.outputDirectory!.appendingPathComponent("Result"))
                return .init()
            }
            let files = try await SystemActions.runShortcut(name: "Typed", urls: inputs, outputDirectory: parent, using: injected(typed))
            try require(files[0].pathExtension == ext, "Useful extension inferred safely: \(ext)")
            try require(try Data(contentsOf: files[0]) == data, "Extension inference preserves bytes")
        }
    }

    static func testScreenshot(_ root: URL) async throws {
        let parent = root.appendingPathComponent("screenshots")
        let recorder = Recorder { command in
            try require(command.arguments.count == 3 && Array(command.arguments.prefix(2)) == ["-i", "-x"], "Interactive quiet capture; never -c")
            try Data("fake PNG".utf8).write(to: URL(fileURLWithPath: command.arguments[2]))
            return .init()
        }
        var dependencies = injected(recorder)
        let files = try await SystemActions.captureScreenshot(outputDirectory: parent, using: dependencies)
        try require(files.count == 1 && files[0].pathExtension == "png", "Screenshot output")
        dependencies.canCapture = { false }
        let denied = try await failure { _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: dependencies) }
        try require(denied.localizedDescription.contains("Privacy & Security"), "Actionable OS permission error")
        let permissionCommands = await recorder.all()
        try require(permissionCommands.count == 1, "Denied capture does not launch")
        let permission = PermissionProbe()
        var firstUse = injected(recorder)
        firstUse.canCapture = { permission.allowed }
        firstUse.requestCaptureAccess = { permission.request(grant: true) }
        _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: firstUse)
        try require(permission.requestCount == 1 && permission.requestedOnMainThread, "First-use permission requested once on UI thread")
        let deniedPermission = PermissionProbe()
        firstUse.canCapture = { deniedPermission.allowed }
        firstUse.requestCaptureAccess = { deniedPermission.request(grant: false) }
        let restart = try await failure { _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: firstUse) }
        try require(deniedPermission.requestCount == 1 && restart.localizedDescription.contains("reopen"), "Denial asks once then gives restart/settings guidance")
        let stalePermission = PermissionProbe()
        firstUse.canCapture = { false }
        firstUse.requestCaptureAccess = { stalePermission.request(grant: true) }
        let stale = try await failure { _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: firstUse) }
        try require(stalePermission.requestCount == 1 && stale.localizedDescription.contains("reopen"), "Approval with stale preflight requires restart, never captures without access")
        for status: Int32 in [0, 1] {
            let cancel = Recorder { _ in .init(status: status) }
            let result = try await SystemActions.captureScreenshot(outputDirectory: parent, using: injected(cancel))
            try require(result.isEmpty, "Escape returns []")
        }
        let failing = Recorder { _ in .init(status: 1, stderr: Data("could not create image from display".utf8)) }
        let error = try await failure { _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: injected(failing)) }
        try require(error.localizedDescription.contains("could not create image") && error.localizedDescription.contains("Screen Recording"), "Permission hint with failure diagnostic")
        let gate = Started()
        var slow = injected(recorder)
        slow.runner = { _ in
            await gate.mark()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init()
        }
        let first = Task { try await SystemActions.captureScreenshot(outputDirectory: parent, using: slow) }
        while !(await gate.value) { try await Task.sleep(nanoseconds: 1_000_000) }
        let overlap = try await failure { _ = try await SystemActions.captureScreenshot(outputDirectory: parent, using: injected(recorder)) }
        try require(overlap.localizedDescription.contains("already open"), "Only one interactive capture at once")
        first.cancel()
        let cancelled = try await first.value
        try require(cancelled.isEmpty, "Task cancellation returns [] for screenshot")
        let afterCancellation = try await SystemActions.captureScreenshot(outputDirectory: parent, using: injected(recorder))
        try require(afterCancellation.count == 1, "Gate released after cancellation")
        try require(try manager.contentsOfDirectory(atPath: parent.path).count == 3, "Only successful screenshots retained")
    }

    final class PermissionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = false
        private var calls = 0
        private var onMain = false
        var allowed: Bool { lock.lock(); defer { lock.unlock() }; return granted }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var requestedOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
        func request(grant: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1; onMain = Thread.isMainThread; granted = grant
            return grant
        }
    }

    actor Started {
        var value = false
        func mark() { value = true }
    }

    static func testOutputBounds(_ root: URL) async throws {
        let directory = root.appendingPathComponent("bounds")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: root)
        _ = try await failure { _ = try SystemActions.outputFiles(in: directory) }
        try manager.removeItem(at: link)
        let large = directory.appendingPathComponent("large")
        manager.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(SystemActions.maximumOutputBytes + 1))
        try handle.close()
        _ = try await failure { _ = try SystemActions.outputFiles(in: directory) }
        try manager.removeItem(at: large)
        for index in 0...SystemActions.maximumOutputFiles { try Data().write(to: directory.appendingPathComponent("\(index)")) }
        _ = try await failure { _ = try SystemActions.outputFiles(in: directory) }
        try manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        var nested = directory
        for _ in 0..<17 { nested.appendPathComponent("sub"); try manager.createDirectory(at: nested, withIntermediateDirectories: false) }
        _ = try await failure { _ = try SystemActions.outputFiles(in: directory) }
    }

    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }
    static func command(_ args: [String], timeout: TimeInterval = 2, directory: URL? = nil) -> SystemActions.Command {
        .init(executable: executable, arguments: ["--fixture"] + args, timeout: timeout, outputDirectory: directory)
    }

    static func testRealRunner(_ root: URL) async throws {
        let special = ["space name", "--help", "--", "$(touch nope); `id`", "資料 🦊"]
        let result = try await SystemActions.runProcess(command(["args"] + special))
        let echoed = try JSONDecoder().decode([String].self, from: result.stdout)
        try require(echoed == special, "Actual spawn preserves argv literally")
        let failed = try await SystemActions.runProcess(command(["fail"]))
        try require(failed.status == 7 && String(decoding: failed.stderr, as: UTF8.self) == "fixture failure", "Exit code and stderr")
        let exact = try await SystemActions.runProcess(command(["exact"]))
        try require(exact.stdout.count == SystemActions.maximumLogBytes && exact.stderr.count == SystemActions.maximumLogBytes, "Simultaneous streams drained at exact bound")
        for stream in ["stdout", "stderr"] {
            let overflow = try await failure { _ = try await SystemActions.runProcess(command(["flood", stream])) }
            try require(overflow.localizedDescription.contains("64 KB"), "\(stream) overflow fails clearly")
        }
        _ = try await failure { _ = try await SystemActions.runProcess(.init(executable: root.appendingPathComponent("missing"), arguments: [], timeout: 1)) }
        _ = try await failure { _ = try await SystemActions.runProcess(command(["args", "nul\0bad"])) }
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemActions.runProcess(command(["args"]))
        }
        let cancellation = try await failure { _ = try await preCancelled.value }
        try require(cancellation is CancellationError, "Already-cancelled task never launches")

        for mode in ["timeout", "cancel", "orphan"] {
            let pidFile = root.appendingPathComponent("\(mode)-pids")
            let task = Task { try await SystemActions.runProcess(command([mode, pidFile.path], timeout: mode == "timeout" ? 0.15 : 3)) }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !manager.fileExists(atPath: pidFile.path), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            try require(manager.fileExists(atPath: pidFile.path), "Fixture started")
            let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
            if mode == "cancel" { task.cancel() }
            if mode == "orphan" { _ = try await task.value }
            else {
                let error = try await failure { _ = try await task.value }
                try require(mode == "cancel" ? error is CancellationError : error.localizedDescription.contains("timed out"), "Correct stop error")
            }
            try require(pids.count == 2, "Recorded leader and descendant")
            // launchd can briefly retain a reparented zombie, which is already dead.
            for pid in pids {
                let ps = try await SystemActions.runProcess(.init(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", String(pid), "-o", "stat="], timeout: 2))
                let state = String(decoding: ps.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                try require(state.isEmpty || state.hasPrefix("Z"), "No running process leaked after \(mode): \(pid) \(state)")
            }
        }
        let disk = root.appendingPathComponent("runner-disk")
        try manager.createDirectory(at: disk, withIntermediateDirectories: false)
        let diskError = try await failure { _ = try await SystemActions.runProcess(command(["disk", disk.path], directory: disk)) }
        try require(diskError.localizedDescription.contains("128 MB"), "Live disk bounds terminate subprocess")

        // Exercise APIs through a real controlled executable, including launch cancellation cleanup.
        var dependencies = SystemActions.Dependencies()
        dependencies.shortcuts = executable
        dependencies.screencapture = executable
        dependencies.canCapture = { true }
        dependencies.runner = { original in
            var args = ["--fixture"]
            args += original.arguments.first == "-i" ? ["capture"] + original.arguments : original.arguments
            return try await SystemActions.runProcess(.init(executable: original.executable, arguments: args,
                timeout: original.timeout, outputDirectory: original.outputDirectory))
        }
        let names = try await SystemActions.listShortcuts(using: dependencies)
        try require(names == ["Fixture 資料", "--help"], "Real fixture listing")
        let input = root.appendingPathComponent("fixture input.txt")
        try Data("selected".utf8).write(to: input)
        let parent = root.appendingPathComponent("fixture outputs")
        for name in ["--help", "name with spaces $(id)"] {
            let files = try await SystemActions.runShortcut(name: name, urls: [input], outputDirectory: parent, using: dependencies)
            let decoded = try JSONDecoder().decode([String].self, from: Data(contentsOf: files[0]))
            try require(decoded.last == name && decoded.suffix(2).first == "--", "Real API arguments keep name after separator")
        }
        let screenshot = try await SystemActions.captureScreenshot(outputDirectory: parent, using: dependencies)
        try require(screenshot.count == 1, "Real controlled capture executable")

        // The API waits for process teardown before deleting partial output.
        let cancelParent = root.appendingPathComponent("cancel outputs")
        let ready = root.appendingPathComponent("api-cancel-ready")
        dependencies.runner = { original in
            try Data("partial".utf8).write(to: original.outputDirectory!.appendingPathComponent("partial"))
            return try await SystemActions.runProcess(command(["cancel", ready.path], timeout: 3, directory: original.outputDirectory))
        }
        let apiTask = Task { try await SystemActions.runShortcut(name: "Cancel", urls: [input], outputDirectory: cancelParent, using: dependencies) }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !manager.fileExists(atPath: ready.path), ProcessInfo.processInfo.systemUptime < readyDeadline { try await Task.sleep(nanoseconds: 2_000_000) }
        try require(manager.fileExists(atPath: ready.path), "API subprocess launched")
        apiTask.cancel()
        let apiCancel = try await failure { _ = try await apiTask.value }
        try require(apiCancel is CancellationError, "Shortcut API propagates cancellation")
        try require(try manager.contentsOfDirectory(atPath: cancelParent.path).isEmpty, "Cancellation removes staging after process cleanup")
    }

    static func fixture(_ args: [String]) throws {
        func write(_ data: Data, _ fd: Int32) {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count <= 0 { return }
                    offset += count
                }
            }
        }
        switch args.first {
        case "args": write(try JSONEncoder().encode(Array(args.dropFirst())), STDOUT_FILENO)
        case "fail": write(Data("fixture failure".utf8), STDERR_FILENO); exit(7)
        case "exact":
            write(Data(repeating: 65, count: SystemActions.maximumLogBytes), STDOUT_FILENO)
            write(Data(repeating: 66, count: SystemActions.maximumLogBytes), STDERR_FILENO)
        case "flood":
            let fd = args[1] == "stdout" ? STDOUT_FILENO : STDERR_FILENO
            while true { write(Data(repeating: 65, count: 8192), fd) }
        case "timeout", "cancel", "orphan":
            signal(SIGTERM, SIG_IGN)
            var child: pid_t = 0
            let values = [strdup("/bin/sleep"), strdup("30"), nil]
            defer { for value in values { free(value) } }
            var argv = values
            try require(posix_spawn(&child, "/bin/sleep", nil, nil, &argv, nil) == 0, "Spawn controlled descendant")
            try Data("\(getpid()) \(child)".utf8).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
            if args[0] == "orphan" { return }
            while true { pause() }
        case "disk":
            let file = URL(fileURLWithPath: args[1]).appendingPathComponent("large")
            manager.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(SystemActions.maximumOutputBytes + 1)); try handle.close()
            while true { pause() }
        case "list": write(Data("Fixture 資料\n--help\n".utf8), STDOUT_FILENO)
        case "run":
            try require(args.count >= 7 && args[1] == "--output-path" && args[3] == "--input-path", "Fixture run options")
            try JSONEncoder().encode(args).write(to: URL(fileURLWithPath: args[2]))
        case "capture":
            try require(args.count == 4 && args[1] == "-i" && args[2] == "-x", "Fixture capture arguments")
            try Data("fake screenshot".utf8).write(to: URL(fileURLWithPath: args[3]))
        default: throw TestFailure(description: "Unknown fixture: \(args)")
        }
    }
}
