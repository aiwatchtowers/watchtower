import SwiftUI
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The coach's pull-request states (spec 2026-11-19 §4.6, plan Task 5). The
/// mockups in `docs/design/mockups/coach-repo-prs/` were drawn with
/// test-target views; these shots render the real views
/// (`CoachAcceptedLogView`, `CoachProposalCardView`, `TuningAcceptedLine`)
/// over a `CoachCenter` whose CLI answers from a script, so the card lines
/// and Retry come from the center's own refusal handling. Data is synthetic:
/// `acme/repo`, PR #12 / #13.
@MainActor
enum CoachRepoPRsShotFixtures {
    enum State: String, CaseIterable {
        case accepted // every Accepted edits row of a PR edit, and the sync line
        case rollbackRetry = "rollback-retry"
        case acceptNoGH = "accept-no-gh"
        case acceptBaseDiffers = "accept-base-differs"
        case acceptPushFailed = "accept-push-failed"
        case acceptPRFailed = "accept-pr-failed"
        case acceptTimeout = "accept-timeout"
        case foldedWaiting = "folded-waiting"
        case rollbackPRChanged = "rollback-pr-changed" // the Roll Back sheet of a merged PR whose file moved
    }

    private static var centers: [CoachCenter] = []

    static func cleanUp() {
        centers.forEach { $0.stop() }
        centers = []
    }

    static var shots: [DesignShot] {
        State.allCases.map { state in
            DesignShot(name: "coach-repo-prs-\(state.rawValue)", size: size(state)) { screen(state) }
        }
    }

    private static func size(_ state: State) -> NSSize {
        switch state {
        case .accepted: NSSize(width: 900, height: 420)
        case .rollbackRetry: NSSize(width: 900, height: 140)
        case .foldedWaiting: NSSize(width: 460, height: 90)
        case .rollbackPRChanged: NSSize(width: 520, height: 290)
        default: NSSize(width: 900, height: 300)
        }
    }

    nonisolated static let prURL = "https://github.com/acme/repo/pull/12"
    nonisolated static let revertURL = "https://github.com/acme/repo/pull/13"

    nonisolated static func proposal(
        _ id: Int64,
        title: String,
        status: String = "accepted",
        verdict: String = "",
        numbers: (Double?, Double?) = (nil, nil),
        measureFrom: String? = nil,
        pr: String = prURL,
        revert: String = ""
    ) -> CoachProposal {
        var p = CoachProposal(
            id: id, title: title, why: "The agent missed the test command in 4 sessions.",
            destination: "repo_claude_md", workbenchID: 3, promptID: "", kind: "add", metric: "corrections",
            before: "# acme\n\nBuild with make.", after: "# acme\n\nBuild with make.\nTest with make test.",
            evidence: [], sources: 4, status: status, createdAt: "2026-11-0\(id % 9 + 1)T09:00:00Z",
            decidedAt: status == "open" ? nil : "2026-11-0\(id % 9 + 1)T10:00:00Z", baseline: numbers.0,
            verdict: verdict, verdictValue: numbers.1, verdictAt: nil, revertsID: 0, budget: 0)
        p.measureFrom = measureFrom
        p.prURL = pr
        p.revertPRURL = revert
        p.writtenBranch = status == "open" ? "" : "coach/a1b2c3d4/proposal-\(id)"
        p.folderBranch = status == "open" ? "main" : nil
        return p
    }

    /// The six states of an accepted PR edit, newest first.
    static var acceptedRows: [CoachProposal] {
        [
            proposal(16, title: "Name the test command in CLAUDE.md"),
            proposal(15, title: "Say which folder holds fixtures", measureFrom: "2026-11-08T12:00:00Z"),
            proposal(14, title: "Ask before running migrations", verdict: "works", numbers: (3, 1.5),
                     measureFrom: "2026-10-20T12:00:00Z"),
            proposal(13, title: "Prefer table tests", status: "rolled_back", revert: revertURL),
            proposal(12, title: "Keep commits small", status: "rolled_back"),
            proposal(11, title: "Run gofmt before commit", verdict: "too_little_data")
        ]
    }

    /// The open cards' Accept refusals, by proposal id: code, Go's sentence, git's or gh's words.
    private static let refusals: [Int64: (code: String, sentence: String, words: String)] = [
        21: ("no_gh", CoachPRTexts.noGH, "gh: not logged in"),
        22: ("base_differs", CoachPRTexts.baseDiffers(path: "CLAUDE.md"), "CLAUDE.md on main"),
        23: ("push_failed", CoachPRTexts.pushFailed, "push failed: remote: Permission to acme/repo.git denied"),
        24: ("pr_failed", CoachPRTexts.prFailed, "gh: GraphQL: was submitted too quickly"),
        25: ("timeout", CoachPRTexts.timeout, "context deadline exceeded"),
        17: ("pr_unreadable", CoachPRTexts.prUnreadable("#12"), "gh: could not resolve host api.github.com")
    ]

    private static func screen(_ state: State) -> AnyView {
        let page: AnyView
        switch state {
        case .accepted:
            let coach = center()
            spin { coach.syncLine != nil }
            page = AnyView(CoachAcceptedLogView(accepted: acceptedRows, open: [], coach: coach) { _ in })
        case .rollbackRetry:
            let coach = center()
            let row = proposal(17, title: "Name the test command in CLAUDE.md")
            Task { _ = await coach.rollback(17, force: false) }
            spin { coach.cardErrors[17] != nil }
            page = AnyView(CoachAcceptedLogView(accepted: [row], open: [], coach: coach) { _ in })
        case .acceptNoGH: page = card(21)
        case .acceptBaseDiffers: page = card(22)
        case .acceptPushFailed: page = card(23)
        case .acceptPRFailed: page = card(24)
        case .acceptTimeout: page = card(25)
        case .rollbackPRChanged:
            let diff = " # acme\n \n Build with make.\n Test with make test.\n+Lint with make lint."
            return AnyView(CoachRollbackSheet(proposal: proposal(18, title: "Name the test command in CLAUDE.md"),
                                              diff: diff, coach: center())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelBackground())
        case .foldedWaiting:
            return AnyView(TuningAcceptedLine(proposal: proposal(16, title: "Name the test command in CLAUDE.md"),
                                              written: nil) {}
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelBackground())
        }
        return AnyView(page.padding(Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    private static func card(_ id: Int64) -> AnyView {
        let coach = center()
        Task { await coach.accept(id, editedText: nil) }
        spin { coach.cardErrors[id] != nil }
        let open = proposal(id, title: "Name the test command in CLAUDE.md", status: "open", pr: "")
        return AnyView(CoachProposalCardView(
            proposal: open, isFirst: true, coach: coach,
            actions: CoachActions(openAsk: { _ in }, openTerminalSession: { _ in }, scrollToStatistics: {})) {})
    }

    /// A center whose proposal list is loaded (the refusals name the card's file and PR from it).
    private static func center() -> CoachCenter {
        let coach = CoachCenter(runner: Runner(), interval: .seconds(3600))
        centers.append(coach)
        coach.refreshProposals()
        coach.syncPRs()
        spin { coach.proposals?.value != nil && !coach.syncing }
        return coach
    }

    private static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    nonisolated private static func json(_ p: CoachProposal) -> [String: Any] {
        [
            "id": p.id, "title": p.title, "why": p.why, "destination": p.destination, "workbench_id": p.workbenchID,
            "prompt_id": "", "kind": p.kind, "metric": p.metric, "before": p.before, "after": p.after,
            "evidence": [], "sources": p.sources, "status": p.status, "created_at": p.createdAt,
            "decided_at": p.decidedAt ?? NSNull(), "verdict": p.verdict, "reverts_id": 0, "budget": 0,
            "pr_url": p.prURL, "revert_pr_url": p.revertPRURL
        ]
    }

    nonisolated private static var proposalsJSON: Data {
        let rows = [proposal(17, title: "Name the test command in CLAUDE.md")]
            + (21...25).map { proposal(Int64($0), title: "Name the test command in CLAUDE.md", status: "open", pr: "") }
        let list: [String: Any] = ["ok": true, "proposals": rows.map(json)]
        return (try? JSONSerialization.data(withJSONObject: list)) ?? Data()
    }

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            switch args.dropFirst().first {
            case "proposals": return CoachRepoPRsShotFixtures.proposalsJSON
            case "sync-prs":
                // Go's errors.Join of one line per unreadable row; the Desktop shows only its code's sentence.
                let error = "syncing coach proposal 9: \(CoachPRTexts.prUnreadable("#9")) (gh: HTTP 502)"
                let object: [String: Any] = ["ok": true, "changed": 0, "sync_error": error, "sync_code": "pr_unreadable"]
                return try JSONSerialization.data(withJSONObject: object)
            case "accept", "rollback":
                let id = Int64(args.dropFirst(2).first ?? "") ?? 0
                guard let r = CoachRepoPRsShotFixtures.refusals[id] else { return Data(#"{"ok":true}"#.utf8) }
                let object: [String: Any] = [
                    "ok": false, "code": r.code,
                    "error": "coach proposal \(id) (repo_claude_md): \(r.sentence) (\(r.words))"
                ]
                let line = String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
                throw CLIRunnerError.nonZeroExit(code: 1, stderr: line + "\ncoach: refused\n")
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}
