import AppKit
import CoreServices
import UniformTypeIdentifiers

enum MarkdownSupport {
  static let extensions = ["md", "markdown"]

  static func isMarkdown(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
      && extensions.contains(url.pathExtension.lowercased())
  }

  @MainActor
  static func makeDefault(applicationURL: URL) async throws {
    let status = LSRegisterURL(applicationURL as CFURL, true)
    guard status == noErr else {
      throw RelayFailure(message: "macOS could not register the Markdown viewer (\(status)).")
    }
    let standard = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    var identifiers = Set<String>()
    let types = [standard] + extensions.compactMap { UTType(filenameExtension: $0) }
    for type in types where identifiers.insert(type.identifier).inserted {
      // A generic fallback must never change the user's handler for all text files.
      guard type != .plainText, type != .text, type != .data, type != .item,
        type.identifier == standard.identifier
          || extensions.contains(type.preferredFilenameExtension?.lowercased() ?? "") else { continue }
      try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type)
    }
  }
}
