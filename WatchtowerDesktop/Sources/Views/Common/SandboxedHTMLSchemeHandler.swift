import Foundation
import UniformTypeIdentifiers
import WatchtowerCore
import WebKit

/// Serves a workbench html preview's folder to its sandboxed web view under
/// `wtpreview://preview/…` (#563), in place of `file:` access to the whole
/// folder. Only what `HTMLPreviewPolicy.previewFile` resolves is served — the
/// rules of the browser's loopback server: no hidden file or folder, and no
/// symlink out of the folder or into a hidden one (`notes.js` →
/// `.secrets/config.js`, a folder link to `.git`). Everything else fails as
/// a missing file. Read-only, from disk only: it opens no connection.
/// A byte-range request (media seek) gets a 206 with that slice.
final class SandboxedHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The folder of the file shown; nil serves nothing (an in-memory page).
    var folder: URL?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let folder, let url = task.request.url,
              let file = HTMLPreviewPolicy.previewFile(for: url, folder: folder),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        var status = 200
        var body = data
        if let range = HTMLPreviewPolicy.byteRange(task.request.value(forHTTPHeaderField: "Range"), length: data.count) {
            status = 206
            body = data.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
        }
        task.didReceive(body)
        task.didFinish()
    }

    /// Every task is answered within `start`, so none is left to stop.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
