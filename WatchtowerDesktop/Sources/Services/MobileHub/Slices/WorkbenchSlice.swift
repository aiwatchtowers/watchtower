import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The `workbench` slice (mobile POC spec §4.2), record name
/// `workbench-<projects.id>`: the ≤ 100 workbenches with the latest session
/// activity, each resolved and capped for the phone's Workbench list. The
/// raw `folder_path` is never published, only `folder_display`.
///
/// Wire shape: the Kit mirror `WatchtowerKit.Workbench`, RelayCoder JSON.
struct WorkbenchSlice: SliceSource {
    let kind = SliceKind.workbench

    static let maxWorkbenches = 100
    /// Twin of the Kit's `WorkbenchAutomation.maxPerWorkbench`.
    static let maxAutomations = 50

    /// The home folder `folder_display` abbreviates to `~`.
    let home: String
    /// The refresher's last good git status for a workbench; nil before one.
    let gitStatus: @Sendable (Int64) -> WorkbenchGitSnapshot?
    /// Session counts per workbench over its published `terminal_session`
    /// records. The terminal_session slice (B Task 3) supplies the resolved
    /// states; until then every count is 0.
    let sessionCounts: @Sendable (Database) throws -> [Int64: Payload.SessionCounts]
    let now: @Sendable () -> Date
    /// `workbench.default_agent` (board #399, D6): what a phone start runs,
    /// so the start sheet can name it.
    let defaultAgent: @Sendable () -> AgentKind

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        gitStatus: @escaping @Sendable (Int64) -> WorkbenchGitSnapshot? = { _ in nil },
        sessionCounts: @escaping @Sendable (Database) throws -> [Int64: Payload.SessionCounts] = { _ in [:] },
        now: @escaping @Sendable () -> Date = { Date() },
        defaultAgent: @escaping @Sendable () -> AgentKind = { .claude }
    ) {
        self.home = home
        self.gitStatus = gitStatus
        self.sessionCounts = sessionCounts
        self.now = now
        self.defaultAgent = defaultAgent
    }

    struct Payload: Encodable, Equatable {
        struct SessionCounts: Encodable, Equatable, Sendable {
            var working = 0
            var waiting = 0
            var needsApproval = 0
            var finished = 0
            var failed = 0
            var stopped = 0
            var notRunning = 0
        }

        /// One quick-run row of the workbench (ask #692), the Kit's `WorkbenchAutomation`.
        struct Automation: Encodable, Equatable {
            let id: Int64
            let name: String
            let nameClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
            /// `manual`, `button` or `scheduled` (a schedule or event recipe).
            let kind: String
            let asksFirst: Bool
            /// `runnable`, `running`, `needs_confirmation`, `disabled` or `parse_error`.
            let state: String
            let lastRunStatus: String?
            let lastRunAt: Date?
        }

        let id: Int64
        let name: String
        let nameClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let description: String
        let descriptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let folderDisplay: String
        let folderDisplayClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let branch: String
        let branchClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let detached: Bool
        let changes: Int
        let openAsks: Int
        let openTargets: Int
        let inProgressTargets: Int
        let blockedTargets: Int
        let doneTargets: Int
        let sessionCounts: SessionCounts
        let lastSessionActivity: Date?
        let archiveAfterDays: Int
        let targetsMore: Int?
        /// `TerminalSessionSlice.wireAgent`: `claude_code` or `codex_cli`.
        let defaultAgent: String
        /// nil (an absent key) when the workbench has none.
        var automations: [Automation]?
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let summaries = try Self.publishedWorkbenches(db)
        guard !summaries.isEmpty else { return [] }
        let window = try WorkbenchTargetWindow.load(db, now: now())
        let counts = try sessionCounts(db)
        let encoder = RelayCoder.makeEncoder()
        let stamp = now()
        let agent = TerminalSessionSlice.wireAgent(defaultAgent())
        let automations = try Self.automations(db, now: stamp)
        return try summaries.map { summary in
            var payload = makePayload(summary, window: window, sessions: counts[summary.id] ?? .init(), agent: agent)
            payload.automations = automations[summary.id]
            return SliceRecord(kind: kind, id: String(summary.id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    private func makePayload(
        _ summary: WorkbenchSwitcherSummary,
        window: WorkbenchTargetWindow,
        sessions: Payload.SessionCounts,
        agent: String
    ) -> Payload {
        let project = summary.project
        let name = SliceClip.text(project.name, limit: 200)
        let description = SliceClip.text(project.description, limit: 1000)
        let folder = SliceClip.text(WorkbenchBranchPresentation.displayPath(project.folderPath, home: home), limit: 300)
        let git = gitStatus(project.id)
        let branch = SliceClip.text(git?.branch ?? "", limit: 120)
        let more = window.more[project.id] ?? 0
        return Payload(
            id: project.id,
            name: name.text, nameClipped: name.clipped,
            description: description.text, descriptionClipped: description.clipped,
            folderDisplay: folder.text, folderDisplayClipped: folder.clipped,
            branch: branch.text, branchClipped: branch.clipped,
            detached: git?.detached ?? false,
            changes: git?.changes ?? 0,
            openAsks: summary.summary.openAsks,
            openTargets: summary.summary.openTargets,
            inProgressTargets: summary.summary.inProgressTargets,
            blockedTargets: summary.blockedTargets,
            doneTargets: window.doneUnarchived[project.id] ?? 0,
            sessionCounts: sessions,
            lastSessionActivity: SliceDate.parse(summary.lastSessionActivity),
            archiveAfterDays: project.archiveAfterDays,
            targetsMore: more > 0 ? more : nil,
            defaultAgent: agent,
            automations: nil
        )
    }

    /// The automations a phone may run, by workbench (ask #692): quick run's
    /// rows (`QuickRunCatalog`, removed recipes left out) of workbench
    /// recipes only, in its order, at most `maxAutomations` each.
    static func automations(_ db: Database, now: Date) throws -> [Int64: [Payload.Automation]] {
        let rows = QuickRunCatalog.rows(try AutomationQueries.fetchList(db, now: now), workbenchNames: [:])
        var out: [Int64: [Payload.Automation]] = [:]
        for row in rows {
            guard case let .workbench(id, _) = row.group, out[id, default: []].count < maxAutomations else { continue }
            out[id, default: []].append(automation(row))
        }
        return out
    }

    private static func automation(_ row: QuickRunRow) -> Payload.Automation {
        let name = SliceClip.text(row.name, limit: 200)
        let kind = switch row.kind {
        case .manual: "manual"
        case .button: "button"
        case .scheduledOrEvent: "scheduled"
        }
        let state = switch row.state {
        case .runnable: "runnable"
        case .running: "running"
        case .needsConfirmation: "needs_confirmation"
        case .disabled: "disabled"
        case .parseError: "parse_error"
        }
        let run = row.lastRun
        return Payload.Automation(
            id: row.id, name: name.text, nameClipped: name.clipped, kind: kind, asksFirst: row.asksFirst, state: state,
            lastRunStatus: run?.status.rawValue, lastRunAt: run.flatMap { $0.finishedAt ?? $0.startedAt ?? $0.queuedAt }
        )
    }

    /// The published workbenches: `WorkbenchQueries.switcherSummaries`, the
    /// latest session activity first (none last, then the switcher's name
    /// order), at most `maxWorkbenches`. The target and comment slices
    /// publish only these workbenches' boards.
    static func publishedWorkbenches(_ db: Database) throws -> [WorkbenchSwitcherSummary] {
        ranked(try WorkbenchQueries.switcherSummaries(db)) { $0.lastSessionActivity }
    }

    /// A published workbench's id and name.
    struct Ref: Equatable, Sendable {
        let id: Int64
        let name: String
    }

    /// `publishedWorkbenches`' set in its order, from one light query: no
    /// board, ask or comment counts. For the slices and runners that need
    /// only which workbenches are published (and their names).
    static func publishedWorkbenchRefs(_ db: Database) throws -> [Ref] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, s.last
            FROM projects p
            LEFT JOIN (
                SELECT project_id, MAX(last_active_at) AS last FROM terminal_sessions
                WHERE project_id IS NOT NULL GROUP BY project_id
            ) s ON s.project_id = p.id
            ORDER BY p.name COLLATE NOCASE, p.id
            """)
        let refs = rows.map { (ref: Ref(id: $0["id"], name: $0["name"]), last: $0["last"] as String? ?? "") }
        return ranked(refs) { $0.last }.map(\.ref)
    }

    /// `items` in the switcher's order, the latest parsed session activity
    /// first: no session (or an unparsable stamp) sorts last, ties keep the
    /// switcher's order; at most `maxWorkbenches`.
    private static func ranked<T>(_ items: [T], activity: (T) -> String) -> [T] {
        let ranked = items.enumerated().map { (order: $0, activity: SliceDate.parse(activity($1)), item: $1) }
        let sorted = ranked.sorted { lhs, rhs in
            switch (lhs.activity, rhs.activity) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.order < rhs.order
            }
        }
        return sorted.prefix(maxWorkbenches).map(\.item)
    }
}
