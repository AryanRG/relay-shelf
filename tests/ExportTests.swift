import AppKit
import Foundation
import PDFKit

@main
struct ExportTests {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPDFTests-\(UUID().uuidString)")
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("export.pdf")
        let started = Date()
        try await DocumentPDFExporter().export(html: "<h1>Export regression</h1><table><tr><th>Artifact</th><th>Status</th></tr><tr><td>Document</td><td>Ready</td></tr></table>", to: file)
        guard let document = PDFDocument(url: file), document.pageCount == 1,
          document.string?.contains("Export regression") == true,
          (try Data(contentsOf: file)).count < 1_000_000,
          Date().timeIntervalSince(started) < 15 else {
          throw RelayFailure(message: "PDF export failed bounded size, content, page count, or timing validation.")
        }
        print("PASS bounded WebKit PDF generation, extracted text, one-page layout, and sub-1MB output")
        try FileManager.default.removeItem(at: folder)
        exit(0)
      } catch {
        fputs("PDF export test failed: \(error.localizedDescription)\n", stderr)
        try? FileManager.default.removeItem(at: folder)
        exit(1)
      }
    }
    application.run()
  }
}
