import Foundation

/// Links into the user guide on GitHub. Mirrors Go `guide.BaseURL`.
package enum GuideLinks {
    package static let baseURL = URL(string: "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/")!

    package static let readme = baseURL.appendingPathComponent("README.md")

    /// `<baseURL><path>` with `#<anchor>` when the anchor is non-empty.
    package static func url(path: String, anchor: String?) -> URL {
        var string = baseURL.absoluteString + path
        if let anchor, !anchor.isEmpty { string += "#" + anchor }
        return URL(string: string) ?? readme
    }
}
