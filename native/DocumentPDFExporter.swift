import AppKit
import PDFKit
import WebKit

@MainActor
final class DocumentPDFExporter: NSObject, WKNavigationDelegate {
  private var webView: WKWebView?
  private var destination: URL?
  private var continuation: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?

  func export(html: String, to destination: URL) async throws {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 528, height: 720), configuration: config)
    view.navigationDelegate = self
    webView = view
    self.destination = destination
    let document = """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
      <style>
      * { box-sizing: border-box; }
      body { font: 11pt -apple-system, sans-serif; color: #171717; line-height: 1.5; margin: 0; }
      h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 13pt; }
      table { width: 100%; border-collapse: collapse; font-size: 10pt; margin: 12pt 0; }
      th,td { border: 1px solid #ccc; padding: 6pt; text-align: left; overflow-wrap: anywhere; }
      pre { white-space: pre-wrap; word-break: break-word; background: #f4f4f4; padding: 9pt; }
      code { font: 9.5pt Menlo, monospace; } img { max-width: 100%; } a { color: #175aa3; }
      blockquote { border-left: 2pt solid #ccc; padding-left: 12pt; margin-left: 0; }
      </style></head><body>\(html)</body></html>
      """
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      view.loadHTMLString(document, baseURL: nil)
      timeout = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        guard !Task.isCancelled else { return }
        self?.finish(.failure(RelayFailure(message: "PDF rendering timed out.")))
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let destination else { return }
    Task { [weak self] in
      do {
        let measured = try await webView.evaluateJavaScript("document.documentElement.scrollHeight")
        guard let height = measured as? Double, height.isFinite, height > 0, height <= 72_000 else {
          throw RelayFailure(message: "This document exceeds the 100-page PDF export limit.")
        }
        let config = WKPDFConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 528, height: max(1, height))
        let data = try await webView.pdf(configuration: config)
        guard self?.continuation != nil else { return }
        try await Task.detached(priority: .userInitiated) {
          try Self.paginate(data, to: destination)
        }.value
        self?.finish(.success(()))
      } catch { self?.finish(.failure(error)) }
    }
  }

  nonisolated private static func paginate(_ data: Data, to destination: URL) throws {
    guard data.count <= 30_000_000,
      let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), let page = document.page(at: 1)
    else { throw RelayFailure(message: "Could not render this PDF within the export limit.") }
    let bounds = page.getBoxRect(.mediaBox)
    guard bounds.width > 0, bounds.height > 0 else {
      throw RelayFailure(message: "The rendered document is empty.")
    }
    let scale = 528 / bounds.width
    let count = Int(ceil(bounds.height * scale / 720))
    guard (1...100).contains(count) else {
      throw RelayFailure(message: "This document exceeds the 100-page PDF export limit.")
    }
    let output = NSMutableData()
    var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &paper, nil)
    else { throw RelayFailure(message: "Could not create the PDF document.") }
    for index in 0..<count {
      context.beginPDFPage(nil)
      context.saveGState()
      context.clip(to: CGRect(x: 42, y: 36, width: 528, height: 720))
      context.translateBy(
        x: 42 - bounds.minX * scale, y: 756 - bounds.maxY * scale + CGFloat(index) * 720)
      context.scaleBy(x: scale, y: scale)
      context.drawPDFPage(page)
      context.restoreGState()
      context.endPDFPage()
      if output.length > 50_000_000 {
        context.closePDF()
        throw RelayFailure(message: "This PDF exceeds the 50 MB export limit.")
      }
    }
    context.closePDF()
    try (output as Data).write(to: destination, options: .atomic)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Void, Error>) {
    timeout?.cancel()
    timeout = nil
    let continuation = self.continuation
    self.continuation = nil
    continuation?.resume(with: result)
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
  }
}
