import AppKit
import Foundation
import Observation
import WatchtowerChatText
import WatchtowerCore

/// What the Workchat's highlighted spans of the agent's text do (spec 2026-11-24-workchat-polish §2): a ref shows the
/// target on the Board, a hash or a command is copied (with a short "Copied" line), a path opens in Files in a preview
/// tab beside the session's own pane.
///
/// A path is coloured only when it is a regular file of the session's code root: one with a `/` (an absolute one
/// inside the root too) by that path, a bare file name by the root's Open Quickly file index on a unique base-name
/// hit. The lookup runs off the main actor; its answer is kept per message and path, and a hit landing re-renders
/// the feed (`found` is observed). A miss is kept only for the `epoch` it was asked in — a new entry or an index
/// change asks again. A click checks the file again.
@MainActor
@Observable
final class WorkchatHighlights {
    /// The short line over the feed after a hash or a command is copied.
    static func copiedNotice(_ text: String) -> String {
        "Copied \(text)"
    }

    struct Key: Hashable {
        let messageID: Int64
        let path: String
        let root: CodeRoot
    }

    /// The resolved file of each path asked, relative to the root. Observed: a lookup landing re-renders.
    private(set) var found: [Key: String] = [:]
    /// The epoch each miss was asked in.
    @ObservationIgnored private var missed: [Key: Int] = [:]
    @ObservationIgnored private var inFlight: [Key: Task<Void, Never>] = [:]
    /// The disk and index lookup (`file(_:in:indexFiles:)`); tests stub it.
    @ObservationIgnored var lookUp: @Sendable (String, CodeRoot, [String]) -> String? = { path, root, files in
        WorkchatHighlights.file(path, in: root, indexFiles: files)
    }
    /// A click's second look at a resolved file (relative to the root); tests stub it.
    @ObservationIgnored var recheck: (String, CodeRoot) -> String? = { file, root in
        WorkbenchFolderPath.resolve(file, folder: root.folder.path)
    }

    /// Whether `path` of message `messageID` is a file of `root`, as far as known now. Unknown: the lookup starts
    /// (once per epoch) and `false` stands until it lands. `indexFiles` is read only for a bare file name.
    func resolves(
        _ path: String, messageID: Int64, root: CodeRoot, epoch: Int, indexFiles: @autoclosure () -> [String]
    ) -> Bool {
        let key = Key(messageID: messageID, path: path, root: root)
        if found[key] != nil { return true }
        guard missed[key] != epoch, inFlight[key] == nil else { return false }
        let files = path.contains("/") ? [] : indexFiles()
        let lookUp = lookUp
        inFlight[key] = Task { [weak self] in
            let file = await Task.detached(priority: .utility) { lookUp(path, root, files) }.value
            guard let self else { return }
            inFlight[key] = nil
            if let file {
                found[key] = file
                missed[key] = nil
            } else {
                missed[key] = epoch
            }
        }
        return false
    }

    /// Waits for the lookups in flight (tests, the shot fixture).
    func lookupsFinished() async {
        while let task = inFlight.values.first { await task.value }
    }

    /// What a click on `span` does, as a value the view performs (and tests read). A path is checked on disk again:
    /// one gone since it was coloured does nothing.
    enum Action: Equatable {
        case showTarget(Int64)
        case copy(String)
        case openFile(String, CodeRoot)
        case nothing
    }

    func action(for span: AgentTextHighlights.Span, root: CodeRoot?) -> Action {
        switch span.kind {
        case let .ref(number): return .showTarget(Int64(number))
        case .hash, .command: return .copy(span.text)
        case .path:
            guard let root, let file = found.first(where: { $0.key.path == span.text && $0.key.root == root })?.value
            else { return .nothing }
            guard recheck(file, root) == file else {
                found = found.filter { $0.value != file || $0.key.root != root }
                return .nothing
            }
            return .openFile(file, root)
        }
    }

    /// The regular file `path` names in `root`, relative to it: a path with a `/` (absolute inside the root, or
    /// relative) as written; a bare name by a unique base-name hit in the root's index (`indexFiles`, relative paths).
    nonisolated static func file(_ path: String, in root: CodeRoot, indexFiles: [String]) -> String? {
        let relative: String
        if path.contains("/") {
            guard let inside = OwnerAskDocumentLink.relativePath(path, folder: root.folder.path)
                ?? OwnerAskDocumentLink.relativePath(path, folder: root.folder.resolvingSymlinksInPath().path)
            else { return nil }
            relative = inside
        } else {
            let suffix = "/" + path
            let hits = indexFiles.lazy.filter { $0 == path || $0.hasSuffix(suffix) }.prefix(2)
            guard hits.count == 1, let hit = hits.first else { return nil }
            relative = hit
        }
        return WorkbenchFolderPath.resolve(relative, folder: root.folder.path)
    }
}

/// A session's span click and path lookup, built once per feed (`SessionChatView`) and shared with a subagent's run.
struct WorkchatHighlightHandlers {
    let open: (AgentTextHighlights.Span) -> Void
    let resolvesPath: (String, Int64) -> Bool
}
