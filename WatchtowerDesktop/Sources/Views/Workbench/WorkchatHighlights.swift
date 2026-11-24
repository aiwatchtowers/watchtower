import AppKit
import Foundation
import WatchtowerChatText
import WatchtowerCore

/// What the Workchat's highlighted spans of the agent's text do (spec 2026-11-24-workchat-polish §2): a ref shows the
/// target on the Board, a hash or a command is copied (with a short "Copied" line), a path opens in Files in a preview
/// tab. A path is coloured only when it is a regular file of the session's code root; each path is looked up once
/// per root (render asks often, the disk answers once).
@MainActor
final class WorkchatHighlights {
    /// The short line over the feed after a hash or a command is copied.
    static func copiedNotice(_ text: String) -> String {
        "Copied \(text)"
    }

    private var resolved: [String: String?] = [:]
    private var resolvedRoot: CodeRoot?
    /// Looks a path up on disk (`WorkbenchFolderPath.resolve`); tests stub it.
    var lookUp: (String, CodeRoot) -> String? = { path, root in
        WorkbenchFolderPath.resolve(path, folder: root.folder.path)
    }

    /// The file `path` names in `root`, relative to it; nil when it is no regular file there.
    func file(_ path: String, in root: CodeRoot) -> String? {
        if root != resolvedRoot {
            resolved = [:]
            resolvedRoot = root
        }
        if let hit = resolved[path] { return hit }
        let file = lookUp(path, root)
        resolved[path] = .some(file)
        return file
    }

    /// What a click on `span` does, as a value the view performs (and tests read).
    enum Action: Equatable {
        case showTarget(Int64)
        case copy(String)
        case openFile(String, CodeRoot)
        case nothing
    }

    func action(for span: AgentTextHighlights.Span, root: CodeRoot?) -> Action {
        switch span.kind {
        case let .ref(number): .showTarget(Int64(number))
        case .hash, .command: .copy(span.text)
        case .path: root.flatMap { root in file(span.text, in: root).map { .openFile($0, root) } } ?? .nothing
        }
    }
}
