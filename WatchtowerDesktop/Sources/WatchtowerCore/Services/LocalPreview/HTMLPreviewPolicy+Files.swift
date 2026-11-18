import Foundation
import WatchtowerChatText

/// The workbench half of the preview policy: files under a served folder.
extension HTMLPreviewPolicy {
    /// The real file a preview request for `url` may be served from, or nil:
    /// the `scheme` only (the handler picks `folder` by the URL's token),
    /// each path segment percent-decoded, then
    /// `LocalPreviewHTTP.resolve` — no `..` or hidden segment, and once every
    /// symlink is resolved the file still lies under the folder with no
    /// hidden component below it (a `notes.js` linking to `.secrets/…` or a
    /// folder link to `.git` is refused).
    package static func previewFile(for url: URL, folder: URL, fileManager: FileManager = .default) -> URL? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments: [String] = []
        for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard let name = String(raw).removingPercentEncoding else { return nil }
            segments.append(name)
        }
        return LocalPreviewHTTP.resolve(segments, under: folder, fileManager: fileManager)
    }
}
