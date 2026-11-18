import Foundation
import WatchtowerChatText

extension CodeLineLinks {
    /// The file and line a link names; nil for another scheme or a path
    /// that is absolute or climbs out of the workbench folder.
    package static func target(from url: URL) -> OpenQuicklyTarget? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let path = value("path"), !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              let line = value("line").flatMap(Int.init), line >= 1 else { return nil }
        return OpenQuicklyTarget(path: path, line: line, col: value("col").flatMap(Int.init))
    }
}
