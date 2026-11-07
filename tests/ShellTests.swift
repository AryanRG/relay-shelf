import AppKit
import Foundation

@main
struct ShellTests {
  @MainActor
  static func main() throws {
    let path = "/tmp/Example document.md"
    let first = RelayLaunchRequest(arguments: ["--add", "--shelf", "Project", path])
    precondition(
      first.paths == [path] && first.shelf == "Project", "--shelf must preserve add mode")
    let second = RelayLaunchRequest(arguments: ["--shelf", "Project", "--add", path])
    precondition(second.paths == [path] && second.shelf == "Project")
    let third = RelayLaunchRequest(arguments: ["--add", path, "--shelf", "Project"])
    precondition(third.paths == [path] && third.shelf == "Project")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RelayLockTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = try RelayInstance(root: root)
    let contender = try RelayInstance(root: root)
    precondition(owner.ownsLock)
    precondition(!contender.ownsLock)
    withExtendedLifetime((owner, contender)) {
      print("PASS CLI argument ordering and single-writer instance lock")
    }
  }
}
