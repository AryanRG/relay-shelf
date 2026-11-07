import Foundation
import Darwin

enum DestinationCopier {
  static func copy(_ urls: [URL], to destination: URL) async throws -> [URL] {
    let task = Task.detached(priority: .userInitiated) {
      try copyFiles(urls, to: destination)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func copyFiles(_ urls: [URL], to destination: URL) throws -> [URL] {
    let files = FileManager.default
    let directory = destination.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory = ObjCBool(false)
    guard !urls.isEmpty, urls.count <= 500,
      files.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw RelayFailure(message: "The saved destination folder is unavailable.") }

    // Copying a directory into one of its own children would recursively copy our staging area.
    let sources = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    for source in sources {
      guard source.path != "/", source.path != directory.path,
        !directory.path.hasPrefix(source.path + "/") else {
        throw RelayFailure(message: "Choose a destination outside the selected source folder.")
      }
    }

    let staging = directory.appendingPathComponent(".relay-copy-\(UUID().uuidString)")
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: staging) }
    var staged: [(source: URL, name: String)] = []
    for (index, source) in sources.enumerated() {
      try Task.checkCancellation()
      let temporary = staging.appendingPathComponent(String(index))
      try files.copyItem(at: source, to: temporary)
      staged.append((temporary, urls[index].lastPathComponent))
    }

    var published: [URL] = []
    do {
      for file in staged {
        try Task.checkCancellation()
        published.append(try publish(file.source, name: file.name, to: directory))
      }
      return published
    } catch {
      // Already completed copies remain available if publication fails midway.
      // The error identifies their count, and original files are never removed.
      guard !published.isEmpty else { throw error }
      throw RelayFailure(message:
        "Copied \(published.count) item(s) before the operation stopped. "
        + "The completed copies are in \(directory.lastPathComponent). \(error.localizedDescription)")
    }
  }

  private static func publish(_ source: URL, name: String, to directory: URL) throws -> URL {
    let filename = name as NSString
    let ext = filename.pathExtension
    let stem = filename.deletingPathExtension
    for index in 0..<10_000 {
      let suffix = index == 0 ? "" : " (\(index + 1))"
      let candidate = directory.appendingPathComponent(
        stem + suffix + (ext.isEmpty ? "" : "." + ext))
      let result = source.path.withCString { from in
        candidate.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
      }
      if result == 0 { return candidate }
      let code = errno
      guard code == EEXIST else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
          NSFilePathErrorKey: candidate.path,
          NSLocalizedDescriptionKey: "Could not finish the destination copy. \(String(cString: strerror(code)))",
        ])
      }
    }
    throw RelayFailure(message: "Too many files share the name \(name) in the destination.")
  }
}
