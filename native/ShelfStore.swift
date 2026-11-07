import AppKit
import Foundation
import ImageIO
import PDFKit
import ServiceManagement
import UniformTypeIdentifiers
import WebKit

struct RelayFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@MainActor
private final class ReadCompletion<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
  func finish(_ result: Result<Value, Error>) {
    let continuation = self.continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }
}

struct ShelfRecord: Codable {
  var id: String
  var name: String
  var pinned: Bool
  var createdAt: String
}

struct ItemRecord: Codable {
  var id: String
  var shelfId: String
  var name: String
  var path: String
  var sourcePath: String?
  var kind: String
  var `extension`: String
  var size: Int64
  var modifiedAt: String
  var addedAt: String
  var storage: String
  var exists: Bool
  var line: Int?
  var content: String?
  var bookmark: Data?
}

struct WatchRecord: Codable {
  var id: String
  var path: String
  var shelfId: String
  var enabled: Bool
}

struct SavedDestination: Codable {
  var id: String
  var name: String
  var path: String
}

struct RelaySettings: Codable {
  var theme = "system"
  var activation = "shake"
  var alwaysOnTop = true
  var defaultStorage = "reference"
  var projectRoot = ""
  var launchAtLogin = false
  var watchExtensions = "md,txt,pdf,docx,csv,json,png,jpg,jpeg,zip"
}

struct PersistedShelf: Codable {
  var version = 1
  var shelves: [ShelfRecord]
  var items: [ItemRecord] = []
  var watchedFolders: [WatchRecord] = []
  var settings = RelaySettings()
  var destinations: [SavedDestination] = []
}

extension PersistedShelf {
  private enum CodingKeys: String, CodingKey {
    case version, shelves, items, watchedFolders, settings, destinations
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    shelves = try values.decode([ShelfRecord].self, forKey: .shelves)
    items = try values.decodeIfPresent([ItemRecord].self, forKey: .items) ?? []
    watchedFolders = try values.decodeIfPresent([WatchRecord].self, forKey: .watchedFolders) ?? []
    settings = try values.decodeIfPresent(RelaySettings.self, forKey: .settings) ?? RelaySettings()
    destinations = try values.decodeIfPresent([SavedDestination].self, forKey: .destinations) ?? []
  }
}

@MainActor
final class ShelfStore {
  let root: URL
  private let stateURL: URL
  private var state: PersistedShelf
  private var previous: PersistedShelf?
  private var allowedPaths = Set<String>()
  private var resources: [String: URL] = [:]
  private var watchers: [String: DirectoryWatcher] = [:]
  private var protectedDirectories: [String: Int] = [:]
  private var cleanupTask: Task<Void, Never>?
  private var activeReads = 0
  private var processingFiles = false
  var onChange: (([String: Any]) -> Void)?
  var onNotice: ((String) -> Void)?
  var onSettingsChange: (() -> Void)?
  var helperAvailable = true

  init(root suppliedRoot: URL? = nil) throws {
    let environmentRoot = ProcessInfo.processInfo.environment["RELAY_SHELF_DATA_DIR"].map {
      URL(fileURLWithPath: $0)
    }
    root =
      (suppliedRoot ?? environmentRoot
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RelayShelf")).standardizedFileURL.resolvingSymlinksInPath()
    stateURL = root.appendingPathComponent("shelves.json")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Files"), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: stateURL.path) {
      state = try JSONDecoder().decode(PersistedShelf.self, from: Data(contentsOf: stateURL))
      guard state.version == 1 else {
        throw RelayFailure(message: "This shelf was saved by a newer version of Relay Shelf.")
      }
    } else {
      state = PersistedShelf(shelves: [
        ShelfRecord(id: "inbox", name: "Inbox", pinned: true, createdAt: Self.now())
      ])
    }
    if state.shelves.isEmpty {
      state.shelves = [ShelfRecord(id: "inbox", name: "Inbox", pinned: true, createdAt: Self.now())]
    }
    let shelfIDs = Set(state.shelves.map(\.id))
    for index in state.items.indices {
      if !shelfIDs.contains(state.items[index].shelfId) {
        state.items[index].shelfId = state.shelves[0].id
      }
    }
  }

  func startWatching() {
    syncWatchers()
    scheduleCleanup()
  }

  func protectManagedDirectory(_ url: URL) {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    protectedDirectories[path, default: 0] += 1
  }

  func releaseManagedDirectory(_ url: URL) {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let count = protectedDirectories[path, default: 0]
    if count > 1 { protectedDirectories[path] = count - 1 }
    else { protectedDirectories.removeValue(forKey: path) }
    scheduleCleanup()
  }

  private func releaseStaging(_ items: [ItemRecord]) {
    for item in items where item.storage == "copy" {
      releaseManagedDirectory(URL(fileURLWithPath: item.path).deletingLastPathComponent())
    }
    scheduleCleanup()
  }

  private func scheduleCleanup() {
    cleanupTask?.cancel()
    cleanupTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, let self else { return }
      let retained = (self.state.items.map(\.path) + (self.previous?.items.map(\.path) ?? []))
        .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
      let trash = self.root.appendingPathComponent("Discarded")
      try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      var discarded: [URL] = []
      for parent in [
        self.root.appendingPathComponent("Files"),
        self.root.appendingPathComponent("Files/Promises"),
        self.root.appendingPathComponent("Incoming"),
      ] {
        let directories =
          (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil))
          ?? []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
          let directoryKey = directory.standardizedFileURL.resolvingSymlinksInPath().path
          guard !self.protectedDirectories.keys.contains(where: {
            $0 == directoryKey || $0.hasPrefix(directoryKey + "/")
          }),
            !retained.contains(where: { $0 == directoryKey || $0.hasPrefix(directoryKey + "/") }
            )
          else { continue }
          let destination = trash.appendingPathComponent(UUID().uuidString)
          // The rename is atomic and cheap. Recursive deletion runs off the UI thread.
          do {
            try FileManager.default.moveItem(at: directory, to: destination)
            discarded.append(destination)
          } catch { continue }
        }
      }
      let existingTrash =
        (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil))
        ?? []
      let toDelete = Set(discarded + existingTrash)
      await Task.detached(priority: .background) {
        for location in toDelete { try? FileManager.default.removeItem(at: location) }
      }.value
    }
  }

  func snapshot() -> [String: Any] {
    var result =
      (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any]
      ?? [:]
    // Bookmark data remains native and never crosses into the renderer.
    if var items = result["items"] as? [[String: Any]] {
      for index in items.indices { items[index].removeValue(forKey: "bookmark") }
      result["items"] = items
    }
    result["canUndo"] = previous != nil
    result["helperAvailable"] = helperAvailable
    return result
  }

  private func commit(
    _ change: (inout PersistedShelf) throws -> Void, undoable: Bool = false,
    preserveUndo: Bool = false
  ) throws {
    let before = state
    try change(&state)
    do {
      try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    } catch {
      state = before
      throw error
    }
    if undoable { previous = before } else if !preserveUndo { previous = nil }
    onChange?(snapshot())
    scheduleCleanup()
  }

  private func shelfID(_ payload: [String: Any]) throws -> String {
    let id = payload["shelfId"] as? String ?? state.shelves[0].id
    guard state.shelves.contains(where: { $0.id == id }) else {
      throw RelayFailure(message: "The selected shelf no longer exists.")
    }
    return id
  }

  private func selected(_ payload: [String: Any]) -> [ItemRecord] {
    let ids = Set(payload["ids"] as? [String] ?? [])
    return state.items.filter { ids.contains($0.id) }
  }

  private func authorize(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard allowedPaths.contains(url.path) || state.items.contains(where: { $0.path == url.path })
    else {
      throw RelayFailure(message: "Paste this location or add the file to a shelf first.")
    }
    return url
  }

  private func allow(_ entries: [[String: Any]]) {
    for entry in entries where entry["exists"] as? Bool == true {
      if let path = entry["path"] as? String { allowedPaths.insert(path) }
    }
  }

  private func boundedRead<Value>(_ operation: @escaping @Sendable () throws -> Value) async throws
    -> Value
  {
    guard activeReads < 4 else {
      throw RelayFailure(
        message:
          "Some file reads are waiting on macOS. Choose the file to authorize access, then retry.")
    }
    activeReads += 1
    return try await withCheckedThrowingContinuation { continuation in
      let completion = ReadCompletion(continuation)
      let deadline = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled else { return }
        completion.finish(
          .failure(
            RelayFailure(
              message:
                "File access is taking longer than expected. Choose the file to authorize access, then retry."
            )))
      }
      Task {
        let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }
          .value
        activeReads -= 1
        deadline.cancel()
        completion.finish(result)
      }
    }
  }

  func fileURLs(for ids: [String]) -> [URL] {
    selected(["ids": ids]).filter { FileManager.default.fileExists(atPath: $0.path) }.map {
      URL(fileURLWithPath: $0.path)
    }
  }

  func resourceURL(for requestURL: URL) -> URL? {
    guard requestURL.scheme == "relay-file" else { return nil }
    return resources[requestURL.lastPathComponent]
  }

  func handle(_ command: String, payload: [String: Any]) async throws -> Any {
    switch command {
    case "getState": return snapshot()
    case "resolve":
      let text = payload["text"] as? String ?? ""
      let base = payload["basePath"] as? String ?? state.settings.projectRoot
      let result = try await boundedRead {
        PathResolver.resolve(text, basePath: base)
      }
      allow(result)
      return result
    case "preview":
      return try await preview(try authorize(payload["path"] as? String ?? ""))
    case "add":
      let id = try shelfID(payload)
      let paths = payload["paths"] as? [String] ?? []
      let storage = payload["storage"] as? String ?? state.settings.defaultStorage
      let lines = payload["lines"] as? [String: Int] ?? [:]
      try await add(paths: paths, shelfId: id, storage: storage, lines: lines)
    case "addText":
      try await addText(
        payload["text"] as? String ?? "", name: payload["name"] as? String,
        shelfId: try shelfID(payload))
    case "captureClipboard": try await captureClipboard(shelfId: try shelfID(payload))
    case "addDestination": try addDestination(payload)
    case "removeDestination":
      let id = payload["id"] as? String ?? ""
      try commit { $0.destinations.removeAll { $0.id == id } }
    case "copyToDestination":
      let items = try orderedSelection(payload)
      guard let destination = state.destinations.first(where: {
        $0.id == payload["destinationId"] as? String
      }) else { throw RelayFailure(message: "Choose a saved destination first.") }
      let urls = items.map { URL(fileURLWithPath: $0.path) }
      let directory = try destinationFolder(destination.path)
      let paths = try await withProtectedInputs(urls) {
        try await DestinationCopier.copy(urls, to: directory)
      }
      return ["paths": paths.map(\.path)]
    case "processFiles":
      let items = try orderedSelection(payload)
      let destination = try shelfID(payload)
      let operation = payload["operation"] as? String ?? ""
      let options = payload["options"] as? [String: Any] ?? [:]
      let urls = items.map { URL(fileURLWithPath: $0.path) }
      _ = try await withProtectedInputs(urls) {
        try await generateFiles(shelfId: destination) { directory in
          try await FileActions.execute(
            operation: operation, urls: urls, outputDirectory: directory, options: options)
        }
      }
    case "captureScreenshot":
      let captured = try await generateFiles(shelfId: try shelfID(payload)) { directory in
        try await SystemActions.captureScreenshot(outputDirectory: directory)
      }
      var result = snapshot()
      result["capturedIDs"] = captured
      return result
    case "listShortcuts": return try await SystemActions.listShortcuts()
    case "runShortcut":
      let items = try orderedSelection(payload)
      let destination = try shelfID(payload)
      let name = payload["name"] as? String ?? ""
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RelayFailure(message: "Choose a shortcut to run.")
      }
      let urls = items.map { URL(fileURLWithPath: $0.path) }
      _ = try await withProtectedInputs(urls) {
        try await generateFiles(shelfId: destination) { directory in
          try await SystemActions.runShortcut(name: name, urls: urls, outputDirectory: directory)
        }
      }
    case "chooseFiles":
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = true
      panel.message = "Add files or folders to Relay Shelf"
      if await panel.begin() == .OK {
        try await add(
          paths: panel.urls.map(\.path), shelfId: try shelfID(payload),
          storage: payload["storage"] as? String ?? state.settings.defaultStorage)
      }
    case "chooseFolder":
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      if await panel.begin() == .OK, let path = panel.url?.path { return path }
      return NSNull()
    case "grantAccess":
      let url = try authorize(payload["path"] as? String ?? "")
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      panel.directoryURL = url.deletingLastPathComponent()
      panel.message =
        "Choose \(url.lastPathComponent) or its containing folder to allow macOS file access."
      guard await panel.begin() == .OK, let chosen = panel.url else { return false }
      let selectedPath = chosen.standardizedFileURL.path
      guard selectedPath == url.path || url.path.hasPrefix(selectedPath + "/") else {
        throw RelayFailure(message: "Choose the requested file or its containing folder.")
      }
      allowedPaths.insert(url.path)
      return true
    case "createShelf":
      let name = try validName(payload["name"] as? String)
      try commit {
        $0.shelves.append(
          ShelfRecord(id: UUID().uuidString, name: name, pinned: false, createdAt: Self.now()))
      }
    case "renameShelf":
      let name = try validName(payload["name"] as? String)
      guard let index = state.shelves.firstIndex(where: { $0.id == payload["id"] as? String })
      else { throw RelayFailure(message: "Shelf not found.") }
      try commit { $0.shelves[index].name = name }
    case "pinShelf":
      guard let index = state.shelves.firstIndex(where: { $0.id == payload["id"] as? String })
      else { throw RelayFailure(message: "Shelf not found.") }
      try commit { $0.shelves[index].pinned = payload["pinned"] as? Bool ?? false }
    case "deleteShelf":
      guard state.shelves.count > 1 else { throw RelayFailure(message: "Keep at least one shelf.") }
      let id = payload["id"] as? String ?? ""
      try commit(
        { data in
          data.shelves.removeAll { $0.id == id }
          data.items.removeAll { $0.shelfId == id }
          data.watchedFolders.removeAll { $0.shelfId == id }
        }, undoable: true)
      syncWatchers()
    case "remove", "clearShelf":
      let ids = Set(payload["ids"] as? [String] ?? [])
      let shelf = payload["shelfId"] as? String
      try commit(
        { data in
          data.items.removeAll { command == "remove" ? ids.contains($0.id) : $0.shelfId == shelf }
        }, undoable: true)
    case "undo":
      if let restored = previous {
        try commit { $0 = restored }
        previous = nil
        syncWatchers()
        onChange?(snapshot())
      }
    case "refresh": try await refresh()
    case "open", "reveal", "quickLook":
      let url = try authorize(payload["path"] as? String ?? "")
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RelayFailure(message: "The original file is missing. Use Locate to reconnect it.")
      }
      if command == "reveal" {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } else if command == "quickLook" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
      } else if !NSWorkspace.shared.open(url) {
        throw RelayFailure(message: "macOS could not open this file.")
      }
      return NSNull()
    case "openExternal":
      guard let raw = payload["url"] as? String, let url = URL(string: raw),
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
      else { throw RelayFailure(message: "Only web links can be opened here.") }
      NSWorkspace.shared.open(url)
      return NSNull()
    case "copyFiles":
      let urls = fileURLs(for: payload["ids"] as? [String] ?? [])
      guard !urls.isEmpty else { throw RelayFailure(message: "Select an available file first.") }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(urls as [NSURL])
      return NSNull()
    case "copyPaths":
      try copyText(selected(payload).map(\.path).joined(separator: "\n"))
      return NSNull()
    case "copyContents":
      let items = selected(payload)
      var texts: [String] = []
      for item in items {
        let result = try await preview(URL(fileURLWithPath: item.path))
        guard let text = result["text"] as? String else {
          throw RelayFailure(
            message:
              "Contents can be copied from text documents and PDFs. Use Copy files for this selection."
          )
        }
        guard result["truncated"] as? Bool != true else {
          throw RelayFailure(
            message:
              "This preview is shortened. Open the original to copy its complete contents, or copy the file."
          )
        }
        texts.append(items.count > 1 ? "# \(item.name)\n\n\(text)" : text)
      }
      try copyText(texts.joined(separator: "\n\n---\n\n"))
      return NSNull()
    case "copyText":
      try copyText(payload["text"] as? String ?? "", html: payload["html"] as? String)
      return NSNull()
    case "snapshot": try await saveCopies(selected(payload))
    case "exportZip":
      let result = try await exportZip(selected(payload))
      if let path = result["path"] as? String { allowedPaths.insert(path) }
      return result
    case "exportPDF":
      let result = try await exportPDF(
        try authorize(payload["path"] as? String ?? ""), html: payload["html"] as? String)
      if let path = result["path"] as? String { allowedPaths.insert(path) }
      return result
    case "updateSettings": try updateSettings(payload["settings"] as? [String: Any] ?? [:])
    case "addWatch":
      let id = try shelfID(payload)
      let path = (payload["path"] as? NSString)?.expandingTildeInPath ?? ""
      let description = PathResolver.describe(URL(fileURLWithPath: path))
      guard description["exists"] as? Bool == true, description["kind"] as? String == "folder"
      else { throw RelayFailure(message: "Choose an existing folder to watch.") }
      guard !state.watchedFolders.contains(where: { $0.path == path && $0.shelfId == id }) else {
        return snapshot()
      }
      try commit {
        $0.watchedFolders.append(
          WatchRecord(id: UUID().uuidString, path: path, shelfId: id, enabled: true))
      }
      syncWatchers()
    case "removeWatch":
      try commit { $0.watchedFolders.removeAll { $0.id == payload["id"] as? String } }
      syncWatchers()
    case "toggleWatch":
      if let index = state.watchedFolders.firstIndex(where: { $0.id == payload["id"] as? String }) {
        try commit { $0.watchedFolders[index].enabled = payload["enabled"] as? Bool ?? false }
        syncWatchers()
      }
    case "locate":
      guard let item = state.items.first(where: { $0.id == payload["id"] as? String }) else {
        throw RelayFailure(message: "Item not found.")
      }
      let panel = NSOpenPanel()
      panel.message = "Locate \(item.name)"
      panel.canChooseDirectories = item.kind == "folder"
      panel.canChooseFiles = item.kind != "folder"
      if await panel.begin() == .OK, let url = panel.url {
        let replacement = try await makeItem(
          url: url, shelfId: item.shelfId, storage: "reference", id: item.id)
        try commit { data in
          if let index = data.items.firstIndex(where: {
            $0.id == item.id && $0.path == item.path && $0.storage == item.storage
          }) {
            data.items[index] = replacement
          }
        }
      }
    default: throw RelayFailure(message: "Unknown action: \(command)")
    }
    return snapshot()
  }

  private func validName(_ value: String?) throws -> String {
    let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 120 else {
      throw RelayFailure(message: "Use a name between 1 and 120 characters.")
    }
    return name
  }

  private func orderedSelection(_ payload: [String: Any]) throws -> [ItemRecord] {
    let ids = payload["ids"] as? [String] ?? []
    guard !ids.isEmpty, ids.count <= 500 else {
      throw RelayFailure(message: "Select between 1 and 500 available items.")
    }
    let byID = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
    var seen = Set<String>()
    return try ids.filter { seen.insert($0).inserted }.map { id in
      guard let item = byID[id], FileManager.default.fileExists(atPath: item.path) else {
        throw RelayFailure(message: "A selected file is unavailable. Refresh the shelf or use Locate.")
      }
      return item
    }
  }

  private func destinationFolder(_ input: String) throws -> URL {
    let path = (input as NSString).expandingTildeInPath
    guard (path as NSString).isAbsolutePath else {
      throw RelayFailure(message: "Choose an existing destination folder.")
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let description = PathResolver.describe(url)
    guard description["exists"] as? Bool == true, description["kind"] as? String == "folder" else {
      throw RelayFailure(message: "Choose an existing destination folder.")
    }
    guard url.path != root.path, !url.path.hasPrefix(root.path + "/") else {
      throw RelayFailure(message: "Choose a destination outside Relay Shelf’s managed data folder.")
    }
    return url
  }

  private func addDestination(_ payload: [String: Any]) throws {
    let url = try destinationFolder(payload["path"] as? String ?? "")
    let suppliedName = (payload["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let name = try validName(suppliedName.isEmpty ? url.lastPathComponent : suppliedName)
    if let index = state.destinations.firstIndex(where: { $0.path == url.path }) {
      try commit { $0.destinations[index].name = name }
      return
    }
    guard state.destinations.count < 100 else {
      throw RelayFailure(message: "Keep up to 100 saved destinations.")
    }
    let record = SavedDestination(id: UUID().uuidString, name: name, path: url.path)
    try commit { $0.destinations.append(record) }
  }

  private func withProtectedInputs<Value>(
    _ urls: [URL], operation: () async throws -> Value
  ) async rethrows -> Value {
    for url in urls { protectManagedDirectory(url) }
    defer { for url in urls { releaseManagedDirectory(url) } }
    return try await operation()
  }

  @discardableResult
  private func generateFiles(
    shelfId: String, operation: (URL) async throws -> [URL]
  ) async throws -> [String] {
    guard !processingFiles else {
      throw RelayFailure(message: "Wait for the current file action to finish.")
    }
    processingFiles = true
    defer { processingFiles = false }
    let directory = root.appendingPathComponent("Files").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    protectManagedDirectory(directory)
    defer { releaseManagedDirectory(directory) }
    let urls = try await operation(directory)
    try Task.checkCancellation()
    guard urls.count <= 500 else {
      throw RelayFailure(message: "A file action can add up to 500 output files.")
    }
    var pending: [ItemRecord] = []
    for url in urls {
      let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
      guard canonical.path.hasPrefix(directory.path + "/") else {
        throw RelayFailure(message: "The file action returned an unexpected output location.")
      }
      var item = try await makeItem(url: canonical, shelfId: shelfId, storage: "reference")
      item.storage = "copy"
      pending.append(item)
    }
    guard !pending.isEmpty else { return [] }
    try commit { data in
      guard data.shelves.contains(where: { $0.id == shelfId }) else {
        throw RelayFailure(message: "The destination shelf was removed while the file action was running.")
      }
      data.items.append(contentsOf: pending)
    }
    return pending.map(\.id)
  }

  @discardableResult
  private func add(paths: [String], shelfId: String, storage: String, lines: [String: Int] = [:])
    async throws -> [String]
  {
    guard paths.count <= 500 else { throw RelayFailure(message: "Add up to 500 files at a time.") }
    guard ["reference", "copy"].contains(storage) else {
      throw RelayFailure(message: "Unknown storage mode.")
    }
    var pending: [ItemRecord] = []
    defer { releaseStaging(pending) }
    var failures: [String] = []
    var seen = Set(state.items.filter { $0.shelfId == shelfId }.map { $0.sourcePath ?? $0.path })
    for path in paths {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
      guard seen.insert(url.path).inserted else { continue }
      do {
        var item = try await makeItem(url: url, shelfId: shelfId, storage: storage)
        item.line = lines[path]
        pending.append(item)
      } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    if !pending.isEmpty {
      // Recheck membership after asynchronous copies to keep concurrent imports consistent.
      try commit { data in
        guard data.shelves.contains(where: { $0.id == shelfId }) else {
          throw RelayFailure(message: "The destination shelf was removed while importing.")
        }
        var current = Set(
          data.items.filter { $0.shelfId == shelfId }.map { $0.sourcePath ?? $0.path })
        data.items.append(
          contentsOf: pending.filter { current.insert($0.sourcePath ?? $0.path).inserted })
      }
    }
    if !failures.isEmpty {
      let message = failures.prefix(5).joined(separator: "\n")
      if pending.isEmpty { throw RelayFailure(message: message) }
      onNotice?("Added \(pending.count) items. Some files could not be added.\n\(message)")
    }
    // Return only committed identities, including existing items for duplicate drops.
    let requested = Set(paths.map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
    })
    return state.items.filter {
      $0.shelfId == shelfId && requested.contains($0.sourcePath ?? $0.path)
    }.map(\.id)
  }

  private func makeItem(url: URL, shelfId: String, storage: String, id: String = UUID().uuidString)
    async throws -> ItemRecord
  {
    let filesRoot = root.appendingPathComponent("Files")
    let stagedDirectory =
      storage == "copy" ? filesRoot.appendingPathComponent(UUID().uuidString) : nil
    if let stagedDirectory { protectManagedDirectory(stagedDirectory) }
    do {
      return try await Task.detached(priority: .userInitiated) {
        let source = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
          throw RelayFailure(message: "File not found.")
        }
        var location = source
        if let directory = stagedDirectory {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          location = directory.appendingPathComponent(source.lastPathComponent)
          do {
            try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: location)
          } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
          }
        }
        let values = PathResolver.describe(location)
        if let error = values["error"] as? String { throw RelayFailure(message: error) }
        return ItemRecord(
          id: id, shelfId: shelfId, name: source.lastPathComponent, path: location.path,
          sourcePath: storage == "copy" ? source.path : nil,
          kind: values["kind"] as? String ?? "file",
          extension: source.pathExtension.lowercased(), size: values["size"] as? Int64 ?? 0,
          modifiedAt: values["modifiedAt"] as? String ?? Self.now(), addedAt: Self.now(),
          storage: storage,
          exists: true,
          bookmark: try? location.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
      }.value
    } catch {
      if let stagedDirectory { releaseManagedDirectory(stagedDirectory) }
      scheduleCleanup()
      throw error
    }
  }

  @discardableResult
  private func addText(_ text: String, name: String?, shelfId: String) async throws -> String {
    guard !text.isEmpty else { throw RelayFailure(message: "The clipboard is empty.") }
    guard text.utf8.count <= 2_000_000 else {
      throw RelayFailure(message: "Text capture is limited to 2 MB. Add the source file instead.")
    }
    let id = UUID().uuidString
    let url = root.appendingPathComponent("Files").appendingPathComponent(id)
      .appendingPathComponent("\(safeFilename(name ?? "Text \(Self.filenameDate())")).txt")
    protectManagedDirectory(url.deletingLastPathComponent())
    defer {
      releaseManagedDirectory(url.deletingLastPathComponent())
      scheduleCleanup()
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
    var item = try await makeItem(url: url, shelfId: shelfId, storage: "reference", id: id)
    item.storage = "copy"
    item.kind = Self.webURL(text) != nil ? "url" : "text"
    item.content = String(text.prefix(8_000))
    if let web = Self.webURL(text) { item.name = web.host ?? text }
    try commit { data in
      guard data.shelves.contains(where: { $0.id == shelfId }) else {
        throw RelayFailure(message: "The destination shelf was removed while capturing.")
      }
      data.items.append(item)
    }
    return item.id
  }

  private func captureClipboard(shelfId: String) async throws {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      try await add(
        paths: urls.map(\.path), shelfId: shelfId, storage: state.settings.defaultStorage)
      return
    }
    if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      try await saveImage(data, shelfId: shelfId)
      return
    }
    guard let text = pasteboard.string(forType: .string) else {
      throw RelayFailure(message: "Copy a file, location, image, link, or text first.")
    }
    let base = state.settings.projectRoot
    let paths = await Task.detached { PathResolver.resolve(text, basePath: base) }.value
    let available = paths.filter { $0["exists"] as? Bool == true }.compactMap {
      $0["path"] as? String
    }
    if !available.isEmpty {
      let lines = Dictionary(
        paths.compactMap { entry -> (String, Int)? in
          guard let path = entry["path"] as? String, let line = entry["line"] as? Int else {
            return nil
          }
          return (path, line)
        }, uniquingKeysWith: { first, _ in first })
      try await add(
        paths: available, shelfId: shelfId, storage: state.settings.defaultStorage, lines: lines)
      let missing = paths.count - available.count
      if missing > 0 {
        onNotice?("Added available files. \(missing) pasted locations could not be resolved.")
      }
    } else if !paths.isEmpty {
      throw RelayFailure(
        message:
          "The copied location could not be found. Use Paste location to inspect it or choose a project folder."
      )
    } else {
      try await addText(text, name: nil, shelfId: shelfId)
    }
  }

  @discardableResult
  private func saveImage(_ data: Data, shelfId: String) async throws -> String {
    guard data.count <= 100_000_000,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let identifier = CGImageSourceGetType(source),
      let ext = UTType(identifier as String)?.preferredFilenameExtension
    else { throw RelayFailure(message: "Could not read the copied image.") }
    let directory = root.appendingPathComponent("Files").appendingPathComponent(UUID().uuidString)
    protectManagedDirectory(directory)
    defer {
      releaseManagedDirectory(directory)
      scheduleCleanup()
    }
    let url = directory.appendingPathComponent("Image \(Self.filenameDate()).\(ext)")
    try await Task.detached(priority: .userInitiated) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }.value
    var item = try await makeItem(url: url, shelfId: shelfId, storage: "reference")
    item.storage = "copy"
    try commit { data in
      guard data.shelves.contains(where: { $0.id == shelfId }) else {
        throw RelayFailure(message: "The destination shelf was removed while capturing.")
      }
      data.items.append(item)
    }
    return item.id
  }

  @discardableResult
  func addDroppedURLs(_ urls: [URL]) async -> [String] {
    do {
      return try await add(
        paths: urls.map(\.path), shelfId: state.shelves[0].id,
        storage: state.settings.defaultStorage)
    } catch {
      onNotice?(error.localizedDescription)
      return []
    }
  }

  @discardableResult
  func captureDroppedText(_ text: String) async -> [String] {
    do {
      let paths = PathResolver.resolve(text, basePath: state.settings.projectRoot)
      let found = paths.filter { $0["exists"] as? Bool == true }.compactMap {
        $0["path"] as? String
      }
      if found.isEmpty {
        return [try await addText(text, name: nil, shelfId: state.shelves[0].id)]
      } else {
        let lines = Dictionary(
          paths.compactMap { entry -> (String, Int)? in
            guard let path = entry["path"] as? String, let line = entry["line"] as? Int else {
              return nil
            }
            return (path, line)
          }, uniquingKeysWith: { first, _ in first })
        return try await add(
          paths: found, shelfId: state.shelves[0].id, storage: state.settings.defaultStorage,
          lines: lines)
      }
    } catch {
      onNotice?(error.localizedDescription)
      return []
    }
  }

  @discardableResult
  func captureDroppedImage(_ data: Data, extension _: String) async -> [String] {
    do { return [try await saveImage(data, shelfId: state.shelves[0].id)] } catch {
      onNotice?(error.localizedDescription)
      return []
    }
  }

  private func copyText(_ text: String, html: String? = nil) throws {
    guard !text.isEmpty else { throw RelayFailure(message: "Select content to copy.") }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    if let html { NSPasteboard.general.setString(html, forType: .html) }
  }

  private func saveCopies(_ items: [ItemRecord]) async throws {
    var replacements: [String: ItemRecord] = [:]
    defer { releaseStaging(Array(replacements.values)) }
    for item in items where item.storage != "copy" {
      var copy = try await makeItem(
        url: URL(fileURLWithPath: item.path), shelfId: item.shelfId, storage: "copy", id: item.id)
      copy.addedAt = item.addedAt
      copy.line = item.line
      replacements[item.id] = copy
    }
    let originals = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    try commit(
      { data in
        data.items = data.items.map { current in
          guard let original = originals[current.id], original.path == current.path,
            original.storage == current.storage
          else { return current }
          return replacements[current.id] ?? current
        }
      }, undoable: true)
  }

  private func refresh() async throws {
    let before = state.items
    let refreshed = await Task.detached(priority: .utility) {
      before.map { source -> ItemRecord in
        var item = source
        var url = URL(fileURLWithPath: item.path)
        if !FileManager.default.fileExists(atPath: url.path), let bookmark = item.bookmark {
          var stale = false
          if let resolved = try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: resolved.path)
          {
            url = resolved
            item.path = resolved.path
            item.name = resolved.lastPathComponent
          }
        }
        item.exists = FileManager.default.fileExists(atPath: url.path)
        let values = PathResolver.describe(url)
        if values["exists"] as? Bool == true {
          item.size = values["size"] as? Int64 ?? 0
          item.modifiedAt = values["modifiedAt"] as? String ?? item.modifiedAt
        }
        return item
      }
    }.value
    let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
    let previousPaths = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.path) })
    try commit(
      { data in
        data.items = data.items.map { item in
          guard previousPaths[item.id] == item.path else { return item }
          return byID[item.id] ?? item
        }
      }, preserveUndo: true)
  }

  private func updateSettings(_ input: [String: Any]) throws {
    var settings = state.settings
    if let value = input["theme"] as? String, ["system", "light", "dark"].contains(value) {
      settings.theme = value
    }
    if let value = input["activation"] as? String, ["shake", "edge", "drag", "off"].contains(value)
    {
      settings.activation = value
    }
    if let value = input["defaultStorage"] as? String, ["copy", "reference"].contains(value) {
      settings.defaultStorage = value
    }
    if let value = input["alwaysOnTop"] as? Bool { settings.alwaysOnTop = value }
    if let value = input["projectRoot"] as? String {
      settings.projectRoot = (value as NSString).expandingTildeInPath
    }
    if let value = input["watchExtensions"] as? String {
      settings.watchExtensions = String(value.prefix(500))
    }
    if let value = input["launchAtLogin"] as? Bool, value != settings.launchAtLogin {
      if value {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      settings.launchAtLogin = value
    }
    try commit { $0.settings = settings }
    syncWatchers()
    onSettingsChange?()
  }

  private func syncWatchers() {
    let enabled = state.watchedFolders.filter(\.enabled)
    let ids = Set(enabled.map(\.id))
    for id in Array(watchers.keys) where !ids.contains(id) {
      watchers[id]?.stop()
      watchers.removeValue(forKey: id)
    }
    for watch in enabled where watchers[watch.id] == nil {
      let monitor = DirectoryWatcher(url: URL(fileURLWithPath: watch.path))
      monitor.onFiles = { [weak self] urls in
        guard let self else { return [] }
        let extensions = Set(
          self.state.settings.watchExtensions.lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
          }.filter { !$0.isEmpty })
        let accepted = urls.filter {
          extensions.isEmpty || extensions.contains($0.pathExtension.lowercased())
        }
        let ignored = Set(urls.map(\.path)).subtracting(accepted.map(\.path))
        guard !accepted.isEmpty else { return ignored }
        do {
          try await self.add(
            paths: accepted.map(\.path), shelfId: watch.shelfId,
            storage: self.state.settings.defaultStorage)
        } catch { self.onNotice?(error.localizedDescription) }
        let recorded = Set(
          self.state.items.filter { $0.shelfId == watch.shelfId }.map { $0.sourcePath ?? $0.path })
        return ignored.union(accepted.map(\.path).filter { recorded.contains($0) })
      }
      monitor.onError = { [weak self] message in self?.onNotice?(message) }
      if monitor.start() { watchers[watch.id] = monitor }
    }
  }

  private func preview(_ url: URL) async throws -> [String: Any] {
    let item = state.items.first { $0.path == url.path }
    if item?.kind == "url", let content = item?.content {
      return ["type": "url", "path": url.path, "name": item!.name, "text": content, "url": content]
    }
    var result = try await boundedRead { try Self.readPreview(url) }
    if let entries = result["entries"] as? [[String: Any]] { allow(entries) }
    if result["type"] as? String == "pdf" {
      let token = UUID().uuidString
      if resources.count > 30 { resources.removeAll() }
      resources[token] = url
      result["url"] = "relay-file://preview/\(token)"
    }
    return result
  }

  nonisolated static func readPreview(_ url: URL) throws -> [String: Any] {
    let values = PathResolver.describe(url)
    if let error = values["error"] as? String { throw RelayFailure(message: error) }
    var result: [String: Any] = ["path": url.path, "name": url.lastPathComponent]
    if values["kind"] as? String == "folder" {
      let contents = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
      let entries = contents.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }.prefix(500).map { PathResolver.describe($0) }
      result["type"] = "folder"
      result["entries"] = entries
      result["truncated"] = contents.count > 500
      return result
    }
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { throw RelayFailure(message: "Could not preview this image.") }
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.png.identifier as CFString, 1, nil)
      else { throw RelayFailure(message: "Could not prepare image preview.") }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw RelayFailure(message: "Could not prepare image preview.")
      }
      result["type"] = "image"
      result["url"] = "data:image/png;base64,\((data as Data).base64EncodedString())"
      return result
    }
    if ext == "pdf" {
      guard let document = PDFDocument(url: url) else {
        throw RelayFailure(message: "This PDF could not be read.")
      }
      var text = ""
      for index in 0..<min(document.pageCount, 30) {
        text += (document.page(at: index)?.string ?? "") + "\n"
        if text.utf8.count > 256_000 { break }
      }
      result["type"] = "pdf"
      result["text"] = String(text.prefix(256_000))
      result["truncated"] = document.pageCount > 30 || text.utf8.count > 256_000
      return result
    }
    let supported = Set([
      "md", "markdown", "txt", "text", "json", "jsonl", "csv", "tsv", "log", "swift", "py", "js",
      "ts", "tsx", "jsx", "html", "css", "scss", "yaml", "yml", "toml", "ini", "conf", "xml", "sql",
      "rs", "go", "java", "sh", "zsh", "bash", "rb", "c", "h", "cpp", "env", "gitignore", "",
    ])
    guard supported.contains(ext) else {
      result["type"] = "unsupported"
      return result
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 256_000) ?? Data()
    let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    guard hasUTF16BOM || !data.prefix(8192).contains(0) else {
      result["type"] = "unsupported"
      return result
    }
    let text =
      hasUTF16BOM
      ? String(data: data, encoding: .utf16) ?? "" : String(decoding: data, as: UTF8.self)
    result["text"] = text
    result["truncated"] = (values["size"] as? Int64 ?? 0) > Int64(data.count)
    result["type"] =
      ["md", "markdown"].contains(ext)
      ? "markdown" : ["json", "csv", "tsv"].contains(ext) ? (ext == "tsv" ? "csv" : ext) : "text"
    return result
  }

  private func exportZip(_ items: [ItemRecord]) async throws -> [String: Any] {
    guard !items.isEmpty else { throw RelayFailure(message: "Select files to export.") }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = "Relay Shelf \(Self.filenameDate()).zip"
    guard await panel.begin() == .OK, let destination = panel.url else { return [:] }
    let sources = items.map { URL(fileURLWithPath: $0.path) }
    try await Task.detached(priority: .userInitiated) {
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RelayExport-\(UUID().uuidString)")
      let contents = temporary.appendingPathComponent("Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: temporary) }
      var names = Set<String>()
      for source in sources {
        var name = source.lastPathComponent
        var index = 2
        while !names.insert(name).inserted {
          let base = source.deletingPathExtension().lastPathComponent
          name =
            "\(base) (\(index))" + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
          index += 1
        }
        try FileManager.default.copyItem(at: source, to: contents.appendingPathComponent(name))
      }
      let archive = temporary.appendingPathComponent("export.zip")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-c", "-k", "--sequesterRsrc", contents.path, archive.path]
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw RelayFailure(message: "ZIP export failed.")
      }
      let data = try Data(contentsOf: archive, options: .mappedIfSafe)
      try data.write(to: destination, options: .atomic)
    }.value
    return ["path": destination.path]
  }

  private func exportPDF(_ url: URL, html: String?) async throws -> [String: Any] {
    let content = try await preview(url)
    guard let text = content["text"] as? String else {
      throw RelayFailure(message: "PDF export supports text and Markdown documents.")
    }
    guard content["truncated"] as? Bool != true else {
      throw RelayFailure(
        message:
          "This document exceeds the preview limit. Open it in an editor to export the complete document."
      )
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
    guard await panel.begin() == .OK, let destination = panel.url else { return [:] }
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    let documentHTML = html ?? "<pre>\(escaped)</pre>"
    guard documentHTML.utf8.count <= 2_000_000 else {
      throw RelayFailure(message: "The rendered document exceeds the PDF export limit.")
    }
    try await DocumentPDFExporter().export(html: documentHTML, to: destination)
    return ["path": destination.path]
  }

  private func safeFilename(_ name: String) -> String {
    String(
      name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(
        100))
  }

  nonisolated private static func webURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed),
      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
    else { return nil }
    return url
  }

  nonisolated static func timestamp(_ date: Date) -> String { date.ISO8601Format() }
  nonisolated static func now() -> String { timestamp(Date()) }
  nonisolated private static func filenameDate() -> String {
    now().replacingOccurrences(of: ":", with: "-")
  }
}
