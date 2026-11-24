import AppKit
import Foundation
import Observation
import SwiftUI
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
    /// The disk and index lookup (`file(_:in:indexFiles:)`), run off the main actor; tests stub it (async, so a
    /// test can hold a lookup without blocking a thread).
    @ObservationIgnored var lookUp: @Sendable (String, CodeRoot, [String]) async -> String? = { path, root, files in
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
            let file = await Task.detached(priority: .utility) { await lookUp(key.path, key.root, ask.indexFiles) }.value
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
    /// looked up afresh (`index`: the root's index now): one gone or ambiguous since does nothing and loses its
    /// colour.
    enum Action: Equatable {
        case showTarget(Int64)
        case copy(String)
        case openFile(String, CodeRoot)
        case nothing
    }

    /// What the click looks a path up in: the root's index file list and its `filesRevision`, read on the main
    /// actor when the click asks.
    struct IndexView {
        let files: @MainActor () -> [String]
        let revision: @MainActor () -> Int

        static let none = Self(files: { [] }, revision: { 0 })
    }

    /// How often a click looks again when the index changed under its lookup before it gives up.
    static let clickLookupAttempts = 3

    /// Off the main actor for a path (the base-name scan reads the whole file list); the click's action runs when
    /// it lands, still keyed by message, path and root. A bare name's lookup reads a snapshot of the index: if the
    /// index's revision moved meanwhile (a duplicate may have joined), the answer is stale and the name is looked up
    /// again (review round 3). A path with a `/` never reads the index, so no index change makes it stale (round
    /// 4). A miss is written back only over the answer the click read, never over a newer one.
    func action(
        for span: AgentTextHighlights.Span, messageID: Int64, root: CodeRoot?, index: IndexView
    ) async -> Action {
        switch span.kind {
        case let .ref(number): return .showTarget(Int64(number))
        case .hash, .command: return .copy(span.text)
        case .path:
            guard let root else { return .nothing }
            let key = Key(messageID: messageID, path: span.text, root: root)
            guard let answer = answers[key], answer.file != nil else { return .nothing }
            let (path, bare, lookUp) = (span.text, !span.text.contains("/"), lookUp)
            for _ in 0 ..< Self.clickLookupAttempts {
                let revision = bare ? index.revision() : 0
                let files = bare ? index.files() : []
                let file = await Task.detached(priority: .userInitiated) { await lookUp(path, root, files) }.value
                if Task.isCancelled { return .nothing }
                if bare, index.revision() != revision { continue }
                if let file { return .openFile(file, root) }
                if answers[key]?.stamp == answer.stamp {
                    answers[key] = Answer(file: nil, stamp: answer.stamp)
                }
                return .nothing
            }
            return .nothing
        }
    }

    /// The click whose lookup runs (`click`): a newer click, the chat leaving or its root changing cancels it, so
    /// a late lookup never acts for a pane that is gone (review round 3).
    @ObservationIgnored private var pendingClick: Task<Void, Never>?

    /// Runs a click: its action is worked out (`action`) and handed to `perform` unless cancelled meanwhile.
    func click(
        _ span: AgentTextHighlights.Span,
        messageID: Int64,
        root: CodeRoot?,
        index: IndexView,
        perform: @escaping @MainActor (Action) async -> Void
    ) {
        pendingClick?.cancel()
        pendingClick = Task { [weak self] in
            guard let self else { return }
            let action = await action(for: span, messageID: messageID, root: root, index: index)
            guard !Task.isCancelled else { return }
            await perform(action)
        }
    }

    /// The chat left, or its pane's root changed: a click still looking up does nothing.
    func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
    }

    /// Waits for the click in flight (tests).
    func clickFinished() async {
        await pendingClick?.value
    }

    /// The click in flight (tests keep its handle to await it after it is cancelled).
    var pendingClickTask: Task<Void, Never>? { pendingClick }

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

extension EnvironmentValues {
    /// Tests only: a rendered Workchat feed reports the span handlers it hands its rows, with the highlights they act
    /// through, so a hosted test can click a span of the real view (final review: Branch review's Author chat).
    @Entry var workchatHighlightProbe: (@MainActor (WorkchatHighlightHandlers, WorkchatHighlights) -> Void)?
}

/// The Workchat holds its session root while it is on screen (`CodeFilesCenter.startHolding`, reviews rounds 2–4): the
/// root's code index runs and its folder watcher keeps the index's file list current, so a bare file name resolves —
/// and a later duplicate turns it plain — with FILES never shown. The hold is no FILES consumer: it runs no
/// `git status`. Every counted hold is balanced by one `stopHolding`.
@MainActor
final class WorkchatIndexLease {
    private(set) var held: CodeRoot?
    /// The centre the held root was held in, so it is let go by the same one.
    private var files: CodeFilesCenter?

    /// Holds `root` in `files` (nil: none), letting go of the one held before. A root the centre does not count
    /// (a worktree gone before it showed) is not held, and a later call tries again.
    func hold(_ root: CodeRoot?, in files: CodeFilesCenter) {
        // The same root still held by this lease in the same centre: nothing to do. One retired meanwhile (its
        // folder left the bench and came back) is held again — by each lease on it (final review).
        if root == held, self.files === files, root.map { files.isHolding($0, lease: self) } ?? true { return }
        release()
        guard let root, files.startHolding(root, lease: self) else { return }
        held = root
        self.files = files
    }

    func release() {
        if let held { files?.stopHolding(held, lease: self) }
        held = nil
        files = nil
    }
}
