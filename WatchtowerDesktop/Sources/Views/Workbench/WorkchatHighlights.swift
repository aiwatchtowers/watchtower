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
/// hit. The lookup runs off the main actor; its answer is kept per message, path and root, and a hit landing
/// re-renders the feed (`found` is observed). Every answer carries the ask it answered — the dialog's `epoch` and the
/// index's `filesRevision` — and a newer ask looks again: a miss can turn into a hit, a bare name's hit into a miss
/// (it became ambiguous). A lookup still running when a newer ask comes runs again for it when it lands. A click
/// looks the path up afresh.
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

    /// Which state of the dialog and the index an answer is for.
    struct Stamp: Equatable {
        let epoch: Int
        let revision: Int
    }

    /// A lookup to run: its stamp and the index's file list then (kept only while the lookup is pending).
    private struct Ask {
        let stamp: Stamp
        let indexFiles: [String]
    }

    /// A lookup's answer: the file list it read is not kept.
    private struct Answer {
        let file: String?
        let stamp: Stamp
    }

    /// The last answer per path asked. Observed: an answer landing re-renders the feed.
    private var answers: [Key: Answer] = [:]
    @ObservationIgnored private var inFlight: [Key: Task<Void, Never>] = [:]
    /// The newest ask per key while its lookup runs: it runs again for it when it lands.
    @ObservationIgnored private var newest: [Key: Ask] = [:]
    /// The disk and index lookup (`file(_:in:indexFiles:)`); tests stub it.
    @ObservationIgnored var lookUp: @Sendable (String, CodeRoot, [String]) -> String? = { path, root, files in
        WorkchatHighlights.file(path, in: root, indexFiles: files)
    }

    /// Whether `path` of message `messageID` is a file of `root`, as far as known now. An answer to an older ask
    /// stands (no flicker) while the lookup for this one runs. `indexFiles` is read only for a bare file name.
    func resolves(
        _ path: String,
        messageID: Int64,
        root: CodeRoot,
        epoch: Int,
        revision: Int,
        indexFiles: @autoclosure () -> [String]
    ) -> Bool {
        let key = Key(messageID: messageID, path: path, root: root)
        let answer = answers[key]
        let shown = answer?.file != nil
        let stamp = Stamp(epoch: epoch, revision: revision)
        if answer?.stamp == stamp || newest[key]?.stamp == stamp { return shown }
        let ask = Ask(stamp: stamp, indexFiles: path.contains("/") ? [] : indexFiles())
        if inFlight[key] != nil {
            newest[key] = ask
        } else {
            start(key, ask)
        }
        return shown
    }

    private func start(_ key: Key, _ ask: Ask) {
        let lookUp = lookUp
        inFlight[key] = Task { [weak self] in
            let file = await Task.detached(priority: .utility) { lookUp(key.path, key.root, ask.indexFiles) }.value
            guard let self else { return }
            inFlight[key] = nil
            answers[key] = Answer(file: file, stamp: ask.stamp)
            if let next = newest.removeValue(forKey: key), next.stamp != ask.stamp { start(key, next) }
        }
    }

    /// Waits for the lookups in flight, re-runs included (tests, the shot fixture).
    func lookupsFinished() async {
        while let task = inFlight.values.first { await task.value }
    }

    /// What a click on `span` of message `messageID` does, as a value the view performs (and tests read). A path is
    /// looked up afresh (`indexFiles`: the root's index now): one gone or ambiguous since does nothing and loses its
    /// colour.
    enum Action: Equatable {
        case showTarget(Int64)
        case copy(String)
        case openFile(String, CodeRoot)
        case nothing
    }

    /// Off the main actor for a path (the base-name scan reads the whole file list); the click's action runs when
    /// it lands, still keyed by message, path and root.
    func action(
        for span: AgentTextHighlights.Span, messageID: Int64, root: CodeRoot?, indexFiles: @autoclosure () -> [String]
    ) async -> Action {
        switch span.kind {
        case let .ref(number): return .showTarget(Int64(number))
        case .hash, .command: return .copy(span.text)
        case .path:
            guard let root else { return .nothing }
            let key = Key(messageID: messageID, path: span.text, root: root)
            guard let answer = answers[key], answer.file != nil else { return .nothing }
            let (path, files, lookUp) = (span.text, span.text.contains("/") ? [] : indexFiles(), lookUp)
            let file = await Task.detached(priority: .userInitiated) { lookUp(path, root, files) }.value
            guard let file else {
                answers[key] = Answer(file: nil, stamp: answer.stamp)
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
            guard let hit = uniqueBaseName(path, in: indexFiles) else { return nil }
            relative = hit
        }
        return WorkbenchFolderPath.resolve(relative, folder: root.folder.path)
    }

    /// The one index path whose file name is `name`; nil for none or several.
    nonisolated static func uniqueBaseName(_ name: String, in indexFiles: [String]) -> String? {
        let suffix = "/" + name
        let hits = indexFiles.lazy.filter { $0 == name || $0.hasSuffix(suffix) }.prefix(2)
        return hits.count == 1 ? hits.first : nil
    }
}

/// A session's span click and path lookup, built once per feed (`SessionChatView`) and shared with a subagent's run.
struct WorkchatHighlightHandlers {
    let open: (AgentTextHighlights.Span, Int64) -> Void
    let resolvesPath: (String, Int64) -> Bool
}

/// The Workchat holds its session root while it is on screen, the way FILES does (`CodeFilesCenter.startWatching`,
/// reviews rounds 2–3): the root's code index runs and its folder watcher keeps the index's file list current, so a
/// bare file name resolves — and a later duplicate turns it plain — with FILES never shown. Every `show` is balanced
/// by one `hide`.
@MainActor
final class WorkchatIndexLease {
    private(set) var held: CodeRoot?
    private var show: ((CodeRoot) -> Void)?
    private var hide: ((CodeRoot) -> Void)?

    /// Where `hold` shows and hides a root (the app's `CodeIndexCenter`); the first connection stays, so a root
    /// shown is always hidden by the same centre.
    func connect(show: @escaping (CodeRoot) -> Void, hide: @escaping (CodeRoot) -> Void) {
        guard self.show == nil else { return }
        self.show = show
        self.hide = hide
    }

    /// Holds `root` (nil: none), letting go of the one held before.
    func hold(_ root: CodeRoot?) {
        guard root != held else { return }
        if let held { hide?(held) }
        held = root
        if let root { show?(root) }
    }

    func release() { hold(nil) }
}
