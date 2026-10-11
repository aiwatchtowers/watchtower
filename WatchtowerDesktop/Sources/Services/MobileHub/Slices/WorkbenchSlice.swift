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

    /// The home folder `folder_display` abbreviates to `~`.
    let home: String
    /// The refresher's last good git status for a workbench; nil before one.
    let gitStatus: @Sendable (Int64) -> WorkbenchGitSnapshot?
    /// Session counts per workbench over its published `terminal_session`
    /// records. The terminal_session slice (B Task 3) supplies the resolved
    /// states; until then every count is 0.
    let sessionCounts: @Sendable (Database) throws -> [Int64: Payload.SessionCounts]
    let now: @Sendable () -> Date

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        gitStatus: @escaping @Sendable (Int64) -> WorkbenchGitSnapshot? = { _ in nil },
        sessionCounts: @escaping @Sendable (Database) throws -> [Int64: Payload.SessionCounts] = { _ in [:] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.gitStatus = gitStatus
        self.sessionCounts = sessionCounts
        self.now = now
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
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let summaries = try Self.publishedWorkbenches(db)
        guard !summaries.isEmpty else { return [] }
        let window = try WorkbenchTargetWindow.load(db, now: now())
        let counts = try sessionCounts(db)
        let encoder = RelayCoder.makeEncoder()
        let stamp = now()
        return try summaries.map { summary in
            let payload = makePayload(summary, window: window, sessions: counts[summary.id] ?? .init())
            return SliceRecord(kind: kind, id: String(summary.id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    private func makePayload(
        _ summary: WorkbenchSwitcherSummary,
        window: WorkbenchTargetWindow,
        sessions: Payload.SessionCounts
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
            targetsMore: more > 0 ? more : nil
        )
    }

    /// The published workbenches: `WorkbenchQueries.switcherSummaries`, the
    /// latest session activity first (none last, then the switcher's name
    /// order), at most `maxWorkbenches`. The target and comment slices
    /// publish only these workbenches' boards.
    static func publishedWorkbenches(_ db: Database) throws -> [WorkbenchSwitcherSummary] {
        let all = try WorkbenchQueries.switcherSummaries(db)
        // No session (or an unparsable stamp) sorts last; ties keep the
        // switcher's order.
        let ranked = all.enumerated().map { (order: $0, activity: SliceDate.parse($1.lastSessionActivity), summary: $1) }
        let sorted = ranked.sorted { lhs, rhs in
            switch (lhs.activity, rhs.activity) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.order < rhs.order
            }
        }
        return sorted.prefix(maxWorkbenches).map(\.summary)
    }
}
