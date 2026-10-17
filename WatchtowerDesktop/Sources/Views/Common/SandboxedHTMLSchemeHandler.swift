import Foundation
import WatchtowerCore
import WebKit

/// Serves a workbench html preview's folder to its sandboxed web view under
/// `wtpreview://<token>/…` (#563), in place of `file:` access to the whole
/// folder. Each load gets a fresh token (`serve`); a request under any other
/// token — a late one from the page shown before — fails. Only what
/// `HTMLPreviewReply` allows is served — the rules of the browser's loopback
/// server: no hidden file or folder, no symlink out of the folder or into a
/// hidden one (`notes.js` → `.secrets/config.js`, a folder link to `.git`),
/// nothing over `LocalPreviewHTTP.maxFileBytes`, every reply under the
/// in-app CSP (no fetch/XHR). Files are read off the main thread and sent in
/// `chunkBytes` pieces, the next read only after the last is handed over; a
/// task WebKit stops gets nothing more. Read-only, from disk only: it opens
/// no connection.
///
/// State (`folders`, `running`) is touched on the main thread only, where
/// WebKit calls the handler.
final class SandboxedHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let chunkBytes = 256 * 1024

    /// Per token: the folder served and the path of its top-level page.
    private var sites: [String: (folder: URL, page: String?)] = [:]
    private var running = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "watchtower.html-preview.files", qos: .userInitiated)

    /// Serves `folder` alone under a new token and returns it (lowercase hex);
    /// nil serves nothing (an in-memory page).
    @discardableResult
    func serve(_ folder: URL?) -> String {
        let token = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        sites = folder.map { [token: ($0, nil)] } ?? [:]
        return token
    }

    /// Marks `page` (a URL under a token `serve` returned) as the top-level
    /// page: only its replies go out without `sandbox` (#563), so a framed
    /// sibling is an opaque origin the page cannot read.
    func setPage(_ page: URL) {
        guard let token = page.host?.lowercased(), sites[token] != nil else { return }
        sites[token]?.page = Self.path(of: page)
    }

    private static func path(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let token = url.host?.lowercased(), let site = sites[token] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        running.insert(id)
        let range = task.request.value(forHTTPHeaderField: "Range")
        let isPage = site.page != nil && Self.path(of: url) == site.page
        queue.async { [weak self] in
            let reply = HTMLPreviewReply.reply(for: url, folder: site.folder, range: range, isPage: isPage)
            self?.answer(task, id: id, url: url, reply: reply)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// On `queue`: the head, then the body.
    private func answer(_ task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, reply: HTMLPreviewReply) {
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        switch reply {
        case let .refusal(_, _, body):
            onMain(task, id, closing: nil) { task in
                if let response { task.didReceive(response) }
                task.didReceive(body)
                return .finish
            }
        case let .file(file, _, _, range):
            guard let handle = try? FileHandle(forReadingFrom: file), (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil else {
                return onMain(task, id, closing: nil) { task in
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return .failed
                }
            }
            onMain(task, id, closing: handle) { [weak self] task in
                if let response { task.didReceive(response) }
                guard !range.isEmpty else { return .finish }
                self?.queue.async { self?.pump(task, id: id, handle: handle, remaining: range.count) }
                return .keepOpen
            }
        }
    }

    /// On `queue`: one chunk, handed over on the main thread before the next
    /// is read. A file that shrank since its length was taken fails the task.
    private func pump(_ task: any WKURLSchemeTask, id: ObjectIdentifier, handle: FileHandle, remaining: Int) {
        guard let chunk = try? handle.read(upToCount: min(remaining, Self.chunkBytes)), !chunk.isEmpty else {
            return onMain(task, id, closing: handle) { task in
                task.didFailWithError(URLError(.cannotDecodeContentData))
                return .failed
            }
        }
        let left = remaining - chunk.count
        onMain(task, id, closing: handle) { [weak self] task in
            task.didReceive(chunk)
            guard left > 0 else { return .finish }
            self?.queue.async { self?.pump(task, id: id, handle: handle, remaining: left) }
            return .keepOpen
        }
    }

    private enum Step {
        /// Finish the task.
        case finish
        /// The step already failed the task.
        case failed
        /// More is coming.
        case keepOpen
    }

    /// Runs `step` on the main thread while the task still runs; `closing`
    /// is closed whenever the task ends or was stopped.
    private func onMain(
        _ task: any WKURLSchemeTask,
        _ id: ObjectIdentifier,
        closing handle: FileHandle?,
        step: @escaping (any WKURLSchemeTask) -> Step
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running.contains(id) else {
                try? handle?.close()
                return
            }
            switch step(task) {
            case .keepOpen:
                return
            case .finish:
                task.didFinish()
            case .failed:
                break
            }
            self.running.remove(id)
            try? handle?.close()
        }
    }
}
