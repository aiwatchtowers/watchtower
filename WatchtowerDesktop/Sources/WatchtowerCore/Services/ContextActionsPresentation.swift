import Foundation

/// One row of the Analytics → Context "Do these" list (context actions, spec
/// 2026-11-12 part 4 and its failure paths): a context coach proposal with
/// what it saves, its evidence and where it is in its life.
package struct ContextActionRow: Equatable, Identifiable, Sendable {
    package enum Tag: Equatable, Sendable {
        /// The owner's Claude Code settings: applied at once, Undo puts it back.
        case settings
        /// A workbench repository file: a session opens a PR.
        case repoPR
        /// The agent's memory index: a session archives lines after review.
        case memory

        package var label: String {
            switch self {
            case .settings: return "your settings"
            case .repoPR: return "repo · PR"
            case .memory: return "your memory"
            }
        }
    }

    /// The open row's own button.
    package enum Verb: Equatable, Sendable {
        case turnOff, accept, archive
    }

    package enum State: Equatable, Sendable {
        case open
        /// Accept pressed, the session is being started.
        case starting
        case working(Int64)
        /// The session started, `coach accept --session` failed: Accept is
        /// hidden so no second session starts.
        case linkFailed(Int64)
        /// Accepted through a session whose row and branch are gone and that
        /// has no PR: an untraced PR may exist, so no Start Again.
        case sessionGone
        case prReady(pr: Int64, url: URL?)
        /// Merged (or the memory index written): the verdict is pending.
        case measuring
        /// The session ended with no PR (repo) or no write (memory); nil when
        /// its row is gone but its branch is still known.
        case endedWithoutChange(Int64?)
        case notMerged
        /// A `superseded` row: its key changed before Accept.
        case changedSince
        /// Claude Code wrote the old value back after Accept.
        case revertedOutside
        /// Applied; `afterTokens` nil while measuring.
        case done(beforeTokens: Int, afterTokens: Int?)
        /// Accept (or the start of its session) failed with this message.
        case failed(String)
        /// Revert… started this session; it opens the revert PR.
        case reverting(Int64)
        /// The revert session ended with no revert PR: Revert… again (the
        /// entry is dropped on that press), its session still openable.
        case revertEnded(Int64)
    }

    package enum Action: Equatable, Sendable {
        case turnOff, accept, archive, decline
        case openSession, retryLink, startAgain, dismiss
        case openPR, showDiff, undo, turnOffAgain
        /// A merged repository change: a session opens its revert PR.
        case revert

        package var title: String {
            switch self {
            case .turnOff: return "Turn Off"
            case .accept: return "Accept"
            case .archive: return "Archive"
            case .decline: return "Decline"
            case .openSession: return "Open Session"
            case .retryLink: return "Retry Link"
            case .startAgain: return "Start Again"
            case .dismiss: return "Dismiss"
            case .openPR: return "Open PR"
            case .showDiff: return "Show Diff"
            case .undo: return "Undo"
            case .turnOffAgain: return "Turn Off Again"
            case .revert: return "Revert…"
            }
        }
    }

    package let proposal: CoachProposal
    /// Tokens a session start saves; nil when the report does not weigh the
    /// source (a repository or memory change, or a group not measured).
    package let saving: Int?
    package let tag: Tag
    package let evidence: String
    package let verb: Verb
    package let state: State

    package var id: Int64 { proposal.id }

    /// "−30.2k"; a repository row's estimate (its `saving_tokens`
    /// evidence) "−~3.5k" (minus, then about); nil without a saving.
    package var savingText: String? {
        saving.map { (tag == .repoPR ? "−~" : "−") + ContextActionsPresentation.tokens($0) }
    }

    /// The buttons the state allows, in order. Decline only ever on a row
    /// not yet accepted; an accepted session row with nothing to measure
    /// gets Dismiss. Once applied, a settings row and a written memory index
    /// offer Undo (`coach rollback`); a merged repository change offers
    /// Revert… (a session with `coach brief --revert`).
    package var actions: [Action] {
        let primary: Action = switch verb {
        case .turnOff: .turnOff
        case .accept: .accept
        case .archive: .archive
        }
        switch state {
        case .open, .failed: return [primary, .decline]
        case .starting, .notMerged, .changedSince: return []
        case .measuring: return afterwards
        case .working, .reverting: return [.openSession]
        case .revertEnded: return [.openSession, .revert]
        case .linkFailed: return [.openSession, .retryLink]
        case .sessionGone: return [.dismiss]
        case .prReady: return [.openPR, .showDiff]
        case .endedWithoutChange(let session):
            return (session == nil ? [] : [.openSession]) + [.startAgain, .dismiss]
        case .revertedOutside: return [.turnOffAgain]
        case .done: return afterwards
        }
    }

    /// An applied row's way back.
    private var afterwards: [Action] {
        switch tag {
        case .settings: return [.undo]
        // Only an index the session wrote (`measure_from`) has a copy to put back.
        case .memory: return proposal.measureFrom == nil ? [] : [.undo]
        case .repoPR: return proposal.prState == "merged" ? [.revert] : []
        }
    }

    /// The line under the title that says where the row is; nil when the
    /// buttons say it.
    package var stateLine: String? {
        switch state {
        case .open, .starting, .working, .prReady, .measuring, .reverting: return nil
        case .failed(let message): return message
        case .linkFailed: return ContextActionsPresentation.Copy.linkFailed
        case .sessionGone: return ContextActionsPresentation.Copy.sessionGone
        case .endedWithoutChange:
            return tag == .memory ? ContextActionsPresentation.Copy.endedWithoutChange
                : ContextActionsPresentation.Copy.endedWithoutPR
        case .notMerged: return ContextActionsPresentation.Copy.notMerged
        case .changedSince: return ContextActionsPresentation.Copy.changedSince
        case .revertedOutside: return ContextActionsPresentation.Copy.revertedOutside
        case .revertEnded: return ContextActionsPresentation.Copy.revertEndedWithoutPR
        case .done(_, let after):
            switch proposal.verdict {
            case "no_effect", "too_little_data": return ContextActionsPresentation.Copy.noSaving
            default:
                guard let after else { return tag == .settings ? ContextActionsPresentation.Copy.takesEffect : nil }
                // Without the verdict's number of starts the row shows before → after only.
                guard case let .done(before, _) = state, let starts = proposal.verdictSessions, starts > 0 else { return nil }
                return ContextActionsPresentation.savedLine(tokens: max(0, before - after), starts: starts)
            }
        }
    }

    /// "79.6k → 49.4k", "79.6k → measuring" (before the verdict); nil
    /// unless done with a baseline, and nil for a finished verdict that
    /// measured no saving (no_effect, too_little_data): its line says so.
    package var beforeAfter: String? {
        guard case let .done(before, after) = state, before > 0,
              !["no_effect", "too_little_data"].contains(proposal.verdict) else { return nil }
        let tail = after.map(ContextActionsPresentation.tokens) ?? "measuring"
        return "\(ContextActionsPresentation.tokens(before)) → \(tail)"
    }

    /// The PR page (**Open PR**); `proposal.prURL` is the raw CLI key.
    package var prLink: URL? {
        guard case let .prReady(_, url) = state else { return nil }
        return url
    }

    /// The PR's files page (**Show Diff**, spec C11).
    package var diffURL: URL? {
        prLink?.appendingPathComponent("files")
    }
}

/// Pure rules of the Context block's "Do these" list.
package enum ContextActionsPresentation {
    package enum Copy {
        package static let unusedEverywhere = "0 calls in Watchtower sessions (all workbenches) in 30 days"
        package static let changedSince = "Changed since — nothing was written"
        package static let revertedOutside = "Turned back on outside Watchtower"
        package static let takesEffect = "Takes effect in new sessions"
        package static let linkFailed = "Session is running, but Watchtower could not link it"
        package static let alsoOnIn = "Also on in: "
        package static let endedWithoutPR = "Session ended without a PR"
        package static let sessionGone = "Session was removed — its PR can't be traced"
        package static let endedWithoutChange = "Session ended without a change"
        package static let notMerged = "Not merged"
        package static let saved = "Saved %@ on %d starts"
        package static let noSaving = "No measurable saving"
        package static let revertEndedWithoutPR = "Revert session ended without a PR"
    }

    static let settingsDestinations: Set = ["claude_plugin_off", "claude_mcp_server_off", "claude_connectors_off"]
    static let memoryDestination = "claude_memory_index"
    /// A session of these kinds has ended: nothing moves until the owner acts.
    static let endedKinds: Set<SessionSwitcherPresentation.State.Kind> = [.notStarted, .stopped, .finished, .failed]
    /// The evidence kind carrying a repository row's estimated saving.
    static let savingEvidence = "saving_tokens"
    /// How long a finished row stays in the list after its last event.
    static let doneDays: TimeInterval = 14 * 24 * 3600

    /// This workbench's context proposals and the global ones (workbench 0).
    /// `doThese`: rows to act on or in progress; the open ones first, then
    /// the rest, each largest saving first. `done`: applied, measured or
    /// closed rows, newest first. A done row fades 14 days after its
    /// `verdict_at` (a superseded row: after its `decided_at`), not after
    /// the Accept: the verdict lands at least 14 days after the Accept, so
    /// the measured saving would otherwise never show. A row still
    /// measuring (no verdict) stays until its verdict.
    /// `sources` must be THIS workbench's report sources: a row's saving,
    /// global rows included, is its group's measured tokens there, i.e. what
    /// this workbench saves per session start; nil (no number shown) when
    /// the group is absent from them.
    /// `sessionKinds` is the state of each session row the Desktop has. A
    /// session whose kind is `.notStarted` (closed or crashed before its
    /// first turn), `.stopped`, `.finished` or `.failed` (a StopFailure
    /// turn: nothing moves until the owner acts) has ended; any other kind
    /// is working. The moment after Accept, before the process is live, is
    /// `starting`: an id in `starting` wins over any session kind, and the
    /// caller keeps it there until that session's kind is live.
    /// `linkFailed` maps a proposal to the session it could not be linked
    /// to; `starting`/`errors` are the Desktop's pending Accepts and their
    /// failures; `repository` builds a PR link the CLI did not give.
    package static func rows(
        proposals: [CoachProposal],
        workbenchID: Int64,
        sources: [AgentSourceGroupRow],
        sessionKinds: [Int64: SessionSwitcherPresentation.State.Kind],
        linkFailed: [Int64: Int64],
        now: Date,
        starting: Set<Int64> = [],
        errors: [Int64: String] = [:],
        repository: URL? = nil,
        revertSessions: [Int64: Int64] = [:]
    ) -> (doThese: [ContextActionRow], done: [ContextActionRow]) {
        let ctx = StateInputs(sessionKinds: sessionKinds, linkFailed: linkFailed, starting: starting,
                              errors: errors, repository: repository, revertSessions: revertSessions)
        var doThese: [ContextActionRow] = []
        var done: [(row: ContextActionRow, at: Date)] = []
        for p in proposals where p.origin == "context" && (p.workbenchID == workbenchID || p.workbenchID == 0) {
            guard let row = makeRow(p, sources: sources, ctx) else { continue }
            switch row.state {
            case .done, .measuring, .notMerged, .changedSince:
                let last = p.verdictAt.flatMap(parseDate)
                    ?? (p.status == "superseded" ? p.decidedAt.flatMap(parseDate) : nil)
                if let last, now.timeIntervalSince(last) > doneDays { continue }
                done.append((row, last ?? p.decidedAt.flatMap(parseDate) ?? .distantPast))
            default:
                doThese.append(row)
            }
        }
        doThese.sort { a, b in
            let ka = (a.isOpen ? 0 : 1, -(a.saving ?? -1)), kb = (b.isOpen ? 0 : 1, -(b.saving ?? -1))
            return ka != kb ? ka < kb : a.id < b.id
        }
        done.sort { $0.at != $1.at ? $0.at > $1.at : $0.row.id > $1.row.id }
        return (doThese, done.map(\.row))
    }

    /// "4 changes would cut it to ~42k": the open rows with a known saving
    /// against the start context; "" when none has one.
    package static func headline(baselineTokens: Int, rows: [ContextActionRow]) -> String {
        let savings = rows.filter(\.isOpen).compactMap(\.saving).filter { $0 > 0 }
        guard !savings.isEmpty else { return "" }
        let left = max(0, baselineTokens - savings.reduce(0, +))
        let target = left >= 1000 ? "\(Int((Double(left) / 1000).rounded()))k" : "\(left)"
        let noun = savings.count == 1 ? "change" : "changes"
        return "\(savings.count) \(noun) would cut it to ~\(target)"
    }

    /// "Saved 30.2k on 12 starts".
    package static func savedLine(tokens: Int, starts: Int) -> String {
        String(format: Copy.saved, Self.tokens(tokens), starts)
    }

    /// "512", "30.2k", "42k": one decimal, dropped when it is 0.
    package static func tokens(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let text = String(format: "%.1f", Double(n) / 1000)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }

    /// One proposal of any origin as a row: what the Accepted edits log
    /// shows for a row accepted through a session (weekly and chat repo
    /// rows included), with the same inputs as `rows`. nil when not listed.
    package static func row(
        of p: CoachProposal,
        sources: [AgentSourceGroupRow] = [],
        sessionKinds: [Int64: SessionSwitcherPresentation.State.Kind],
        linkFailed: [Int64: Int64],
        starting: Set<Int64> = [],
        errors: [Int64: String] = [:],
        repository: URL? = nil,
        revertSessions: [Int64: Int64] = [:]
    ) -> ContextActionRow? {
        makeRow(p, sources: sources, StateInputs(sessionKinds: sessionKinds, linkFailed: linkFailed, starting: starting,
                                                 errors: errors, repository: repository, revertSessions: revertSessions))
    }

    // MARK: - Row parts

    private struct StateInputs {
        let sessionKinds: [Int64: SessionSwitcherPresentation.State.Kind]
        let linkFailed: [Int64: Int64]
        let starting: Set<Int64>
        let errors: [Int64: String]
        let repository: URL?
        let revertSessions: [Int64: Int64]
    }

    private static func makeRow(_ p: CoachProposal, sources: [AgentSourceGroupRow], _ ctx: StateInputs) -> ContextActionRow? {
        guard let state = state(of: p, ctx) else { return nil }
        let tag = tag(of: p)
        return ContextActionRow(proposal: p, saving: saving(of: p, sources: sources), tag: tag,
                                evidence: evidence(of: p, tag: tag), verb: verb(of: tag), state: state)
    }

    private static func tag(of p: CoachProposal) -> ContextActionRow.Tag {
        if settingsDestinations.contains(p.destination) { return .settings }
        return p.destination == memoryDestination ? .memory : .repoPR
    }

    private static func verb(of tag: ContextActionRow.Tag) -> ContextActionRow.Verb {
        switch tag {
        case .settings: return .turnOff
        case .repoPR: return .accept
        case .memory: return .archive
        }
    }

    /// nil = not listed (declined, rolled back, an unknown status).
    private static func state(of p: CoachProposal, _ ctx: StateInputs) -> ContextActionRow.State? {
        switch p.status {
        case "open":
            if let session = ctx.linkFailed[p.id] { return .linkFailed(session) }
            if ctx.starting.contains(p.id) { return .starting }
            if let message = ctx.errors[p.id] { return .failed(message) }
            return .open
        case "superseded":
            return .changedSince
        case "accepted":
            return acceptedState(of: p, ctx)
        default:
            return nil
        }
    }

    private static func acceptedState(of p: CoachProposal, _ ctx: StateInputs) -> ContextActionRow.State {
        // A revert session runs: no second Revert…; one that ended (the
        // kinds `sessionState` counts as ended) offers it again.
        if let session = ctx.revertSessions[p.id] {
            guard !ctx.starting.contains(p.id), let kind = ctx.sessionKinds[session], endedKinds.contains(kind) else {
                return .reverting(session)
            }
            return .revertEnded(session)
        }
        let before = Int(p.baseline ?? 0)
        switch p.verdict {
        case "reverted_outside":
            return .revertedOutside
        case "works", "no_effect":
            return .done(beforeTokens: before, afterTokens: p.verdictValue.map { Int($0) })
        case "too_little_data":
            return p.prState == "closed" ? .notMerged : .done(beforeTokens: before, afterTokens: nil)
        default:
            break
        }
        if tag(of: p) == .settings { return .done(beforeTokens: before, afterTokens: nil) }
        // A repository row accepted before sessions waits for its commit.
        return p.viaSession ? sessionState(of: p, ctx) : .measuring
    }

    /// A repository or memory row accepted through a session, no verdict yet.
    private static func sessionState(of p: CoachProposal, _ ctx: StateInputs) -> ContextActionRow.State {
        // Start Again's session could not be linked: Retry Link, never a second Start Again.
        if let session = ctx.linkFailed[p.id] { return .linkFailed(session) }
        // The PR decides first; the session's state only while its row exists.
        if let pr = p.pr {
            switch p.prState {
            case "merged": return .measuring
            case "closed": return .notMerged
            default: return .prReady(pr: pr, url: prURL(of: p, number: pr, repository: ctx.repository))
            }
        }
        if p.measureFrom != nil { return .measuring }
        if ctx.starting.contains(p.id) { return .starting }
        if let session = p.sessionID, let kind = ctx.sessionKinds[session] {
            return endedKinds.contains(kind) ? .endedWithoutChange(session) : .working(session)
        }
        // The session row is gone: a known branch still finds a PR, an
        // unknown one cannot (the memory index has no PR to trace).
        return p.sessionBranch.isEmpty && tag(of: p) == .repoPR ? .sessionGone : .endedWithoutChange(nil)
    }

    private static func prURL(of p: CoachProposal, number: Int64, repository: URL?) -> URL? {
        if let link = p.prURL, let url = URL(string: link) { return url }
        return repository.map { GitHubRemote.pullRequestURL(repository: $0, number: number) }
    }

    private static func evidence(of p: CoachProposal, tag: ContextActionRow.Tag) -> String {
        guard tag == .settings else {
            return p.evidence.filter { $0.kind != savingEvidence }.map(\.ref).joined(separator: " · ")
        }
        let elsewhere = p.evidence.first { $0.kind == "elsewhere" }
            .map { Copy.alsoOnIn + $0.ref.replacingOccurrences(of: "on in: ", with: "", options: .anchored) }
        return [Copy.unusedEverywhere, elsewhere].compactMap { $0 }.joined(separator: " · ")
    }

    /// A settings row's start weight from the report's sources: its group's
    /// measured rows (a plugin also takes its own MCP servers, each going to
    /// the plugin with the longest matching id, as the Go proposer folds
    /// them), nil for a group not in sources. A repository row: its
    /// `saving_tokens` evidence (an estimate). nil for the memory index.
    private static func saving(of p: CoachProposal, sources: [AgentSourceGroupRow]) -> Int? {
        let measured = sources.filter { $0.measuredSessions > 0 }
        let rows: [AgentSourceGroupRow]
        switch p.destination {
        case "claude_plugin_off":
            let name = String(p.sourceKey.prefix { $0 != "@" })
            let plugins = Set(sources.filter { $0.groupKind == "plugin" }.map(\.group)).union([name])
            let prefix = { (plugin: String) in "plugin_" + mcpServerID(plugin) + "_" }
            rows = measured.filter { r in
                if r.groupKind == "plugin" { return r.group == name }
                guard r.groupKind == "mcp_server", r.group.hasPrefix(prefix(name)) else { return false }
                let owner = plugins.filter { r.group.hasPrefix(prefix($0)) }.max { prefix($0).count < prefix($1).count }
                return owner == name
            }
        case "claude_mcp_server_off":
            rows = measured.filter { $0.groupKind == "mcp_server" && $0.group == mcpServerID(p.sourceKey) }
        case "claude_connectors_off":
            rows = measured.filter { $0.groupKind == "claude_ai_connectors" }
        default:
            // A repository row's estimate from the proposer (the moved
            // sections' tokens); the memory index has none.
            guard tag(of: p) == .repoPR else { return nil }
            return p.evidence.first { $0.kind == savingEvidence }.flatMap { Int($0.ref) }.flatMap { $0 > 0 ? $0 : nil }
        }
        return rows.isEmpty ? nil : rows.map(\.tokens).reduce(0, +)
    }

    /// Go's `agentreport.MCPServerID`: every character other than an ASCII
    /// letter, digit, '_' or '-' becomes '_'.
    static func mcpServerID(_ display: String) -> String {
        String(display.unicodeScalars.map { s -> Character in
            s == "_" || s == "-" || ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
                ? Character(s) : "_"
        })
    }

    private static let plainISO = ISO8601DateFormatter()
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        plainISO.date(from: s) ?? fractionalISO.date(from: s)
    }
}

extension ContextActionRow {
    /// Not yet accepted: the list's first part and the headline's changes.
    /// An accepted row being started again (Start Again) is not.
    package var isOpen: Bool {
        guard proposal.status == "open" else { return false }
        switch state {
        case .open, .starting, .failed: return true
        default: return false
        }
    }
}
