import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `workbench review <sub> …` with one fixed answer per subcommand
/// (`args[2]`); an unscripted one fails as Go's would.
final class ReviewStubRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let answers: [String: String]

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    /// `diff --since` answers from `diff-since` when that is scripted.
    func run(args: [String]) async throws -> Data {
        var sub = args.count > 2 ? args[2] : ""
        if sub == "diff", args.contains("--since"), answers["diff-since"] != nil { sub = "diff-since" }
        return Data((answers[sub] ?? #"{"ok":false,"error":"unscripted \#(sub)"}"#).utf8)
    }
}

/// Send's line goes nowhere: the fixtures never send.
@MainActor
private final class ReviewNoSink: ReviewLineSink {
    func deliverLine(_ line: String, key: SessionLineDelivery.LineKey, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        .submitted
    }
}

/// A Branch review round on a test database and the stub CLI (board #712):
/// the workbench `acme`, one Claude session, rounds 1 (sent) and 2, drafts
/// on the first file. Shared by `ReviewPresentationTests` and the shots.
@MainActor
struct ReviewFixture {
    struct File {
        let path: String
        var status = "modified"
        var additions = 10
        var deletions = 2
        var collapsed: String?
    }

    let pool: DatabasePool
    let path: String
    let projectID: Int64
    let session: TerminalSession
    let model: ReviewChangesModel

    /// `status` and `mode`/`phase` are round 2's; `drafts` line comments go
    /// on the first file; `sinceFiles` is the Since round 1 diff (default: `files`).
    init(
        files: [File],
        sinceFiles: [File]? = nil,
        context: [(id: Int64, text: String, intent: String)] = [],
        status: String = "open",
        mode: String = "quick",
        phase: String = "",
        drafts: Int = 0,
        overview: String? = nil
    ) throws {
        let (pool, path) = try TestDatabase.createPool()
        let lastActive = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-240))
        let (projectID, session) = try pool.write { db -> (Int64, TerminalSession) in
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            try db.execute(sql: """
                INSERT INTO terminal_sessions (project_id, kind, title, folder_path, last_active_at, claude_session_id)
                VALUES (?, 'claude', 'Fix the record capsule overlap', '/tmp/acme', ?, '00000000-0000-4000-8000-000000000001')
                """, arguments: [project, lastActive])
            let sessionID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO review_rounds (id, project_id, session_id, folder_root, base_sha, base_label, tree_sha, status)
                VALUES (1, ?, ?, '/tmp/acme', 'b1', 'origin/main', 't1', 'sent')
                """, arguments: [project, sessionID])
            try db.execute(sql: """
                INSERT INTO review_rounds (id, project_id, session_id, folder_root, base_sha, base_label, tree_sha,
                                           prev_round_id, status, mode, phase)
                VALUES (2, ?, ?, '/tmp/acme', 'b1', 'origin/main', 't2', 1, ?, ?, ?)
                """, arguments: [project, sessionID, status, mode, phase])
            for n in 0..<drafts {
                try db.execute(sql: """
                    INSERT INTO review_comments (round_id, path, start_line, end_line, tree_sha, body)
                    VALUES (2, ?, ?, ?, 't2', ?)
                    """, arguments: [files.first?.path, 3 + n, 3 + n, "What happens on a small screen? (\(n + 1))"])
            }
            return (project, try XCTUnwrap(try TerminalSessionQueries.fetch(db, id: sessionID)))
        }
        self.pool = pool
        self.path = path
        self.projectID = projectID
        self.session = session
        let runner = ReviewStubRunner([
            "start": Self.startJSON(status: status, mode: mode, phase: phase),
            "context": Self.contextJSON(context),
            "diff": Self.diffJSON(files),
            "diff-since": Self.diffJSON(sinceFiles ?? files),
            "file": #"{"ok":true,"old":\#(Self.side("a")),"new":\#(Self.side("b"))}"#,
            "overview": overview.map { #"{"ok":true,"overview":\#($0)}"# } ?? #"{"ok":true}"#,
            "approve": #"{"ok":true,"sent":true,"line":"\#(ReviewDeliveryLine.approved(roundID: 2))"}"#
        ])
        model = ReviewChangesModel(projectID: projectID, sessionID: session.id, cli: WorkbenchCLI(runner: runner), db: pool,
                                   lineDelivery: ReviewNoSink()) { false }
    }

    /// Opens the round and puts its first shown file on screen, as the pane does.
    func open() async {
        await model.open()
        if let first = model.files.first(where: { $0.collapsedReason == nil }) { await model.select(first.path) }
    }

    /// `open()` for a synchronous shot builder: the main run loop turns until
    /// it is done (the model's work is on the main actor).
    func openNow() {
        var done = false
        Task { @MainActor in
            await open()
            done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done, "the review fixture did not open in time")
    }

    /// Marks `paths` Viewed (on an open model).
    func markViewedNow(_ paths: [String]) {
        var done = false
        Task { @MainActor in
            for path in paths { try? await model.toggleViewed(path) }
            done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The identity bar's inputs: the session `Ready to check` in `place`.
    func identity(place: SessionPlace, mainStatus: WorkbenchGitStatus? = nil) -> ReviewSessionIdentity {
        let status = SessionAgentStatus(
            sessionID: session.id, workbenchID: projectID, workbenchName: "acme", title: session.title,
            state: .live(.readyToCheck, openAsks: 1, openQuestionAsks: 0, openReviewAsks: 1), at: nil
        )
        let row = SessionSwitcherPresentation.rows([session], liveIDs: [session.id], statuses: [session.id: status], now: Date()).first
        return ReviewSessionIdentity(row: row, place: place, stale: false, mainStatus: mainStatus,
                                     agentName: AgentKind.claude.displayName, openSession: {}, openTerminal: {})
    }

    func cleanUp() {
        TestDatabase.cleanup(path: path)
    }

    private static func side(_ text: String) -> String {
        #"{"exists":true,"text":"\#(text)\n","binary":false,"too_large":false}"#
    }

    private static func startJSON(status: String, mode: String, phase: String) -> String {
        """
        {"ok":true,"round":{"id":2,"status":"\(status)","mode":"\(mode)","phase":"\(phase)","folder_root":"/tmp/acme",
         "base_sha":"b1","base_label":"origin/main","tree_sha":"t2","prev_round_id":1,"prev_tree_sha":"t1",
         "prev_tree_lost":false}}
        """
    }

    private static func contextJSON(_ items: [(id: Int64, text: String, intent: String)]) -> String {
        let entries = items.map { #"{"target_id":\#($0.id),"text":"\#($0.text)","intent":"\#($0.intent)"}"# }
        return #"{"ok":true,"items":[\#(entries.joined(separator: ","))]}"#
    }

    private static func diffJSON(_ files: [File]) -> String {
        let entries = files.map { file in
            let collapsed = file.collapsed.map { #","collapsed_reason":"\#($0)""# } ?? ""
            return """
            {"path":"\(file.path)","status":"\(file.status)","additions":\(file.additions),"deletions":\(file.deletions),
             "binary":false,"new_blob":"blob-\(file.path)","new_mode":"100644"\(collapsed),
             "hunks":[{"hunk_id":"h-\(file.path)","header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,
             "new_lines":1,"lines":["-a","+b"]}]}
            """
        }
        return #"{"ok":true,"diff":{"files":[\#(entries.joined(separator: ","))],"truncated":false},"from":"b1","to":"t2"}"#
    }
}

/// The Branch review pane's shots (board #712, artboards A–C): a branch
/// with changes in Quick, the default branch with nothing to review, the
/// default branch with uncommitted edits, and Deep's Meaning. Each fixture is built once and reused for light and dark.
@MainActor
enum ReviewShotFixtures {
    private static var built: [String: (fixture: ReviewFixture, identity: ReviewSessionIdentity)] = [:]

    static func cleanUp() {
        built.values.forEach { $0.fixture.cleanUp() }
        built = [:]
    }

    static let files: [ReviewFixture.File] = [
        .init(path: "Sources/Recording/RecordCapsule.swift", additions: 40, deletions: 12),
        .init(path: "Tests/Recording/RecordCapsuleTests.swift", status: "added", additions: 96, deletions: 0),
        .init(path: "Sources/Recording/CapsuleCorner.swift", additions: 22, deletions: 6),
        .init(path: "Sources/Recording/CapsulePlacement.swift", additions: 30, deletions: 8),
        .init(path: "Sources/Settings/RecordingSettings.swift", additions: 18, deletions: 4),
        .init(path: "docs/guide/meetings.md", additions: 6, deletions: 2),
        .init(path: "Package.resolved", additions: 4, deletions: 4, collapsed: "lockfile"),
        .init(path: "Tests/Support/TestDatabase+Schema.swift", additions: 6, deletions: 0, collapsed: "generated")
    ]

    static let context: [(id: Int64, text: String, intent: String)] = [
        (128, "Recording capsule covers the window controls", "The capsule never sits on the title bar."),
        (131, "Let the owner move the capsule to another corner", "A corner preference in Settings."),
        (133, "Show the capsule's corner in Settings → Recording", "The chosen corner reads back in Settings.")
    ]

    static let overview = """
    {"summary":"Moves the capsule off the title bar and adds a corner preference. \
    Its position now comes from the window's title-bar rect.",
     "coverage":[{"index":1,"item":"#128 Recording capsule covers the window controls","status":"done",
                  "where":["Sources/Recording/RecordCapsule.swift"]},
                 {"index":2,"item":"#131 Let the owner move the capsule to another corner","status":"partial","where":[]},
                 {"index":3,"item":"#133 Show the capsule's corner in Settings → Recording","status":"not_found","where":[]}],
     "out_of_scope":["docs/guide/meetings.md"],
     "risk":[{"path":"Sources/Recording/RecordCapsule.swift","level":"high","why":"Reads the window before it is attached"}],
     "chapters":[]}
    """

    private static func worktree() -> SessionPlace {
        .worktree(name: "capsule-corners", root: URL(fileURLWithPath: "/tmp/acme-capsule-corners"),
                  status: WorkbenchGitStatus(branch: "feature/capsule-corners", dirty: true, changes: 2))
    }

    /// `chat` adds the agent chat panel (#962); the shots have no session
    /// control, so it shows its "not running" line.
    private static func pane(
        _ key: String, chat: Bool = false, make: () throws -> (ReviewFixture, ReviewSessionIdentity)
    ) -> AnyView {
        do {
            if built[key] == nil {
                let (fixture, identity) = try make()
                built[key] = (fixture, identity)
            }
            guard let entry = built[key] else { return AnyView(EmptyView()) }
            var agentChat: ReviewAgentChat?
            if chat {
                let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
                let vm = WorkbenchesViewModel(dbPool: entry.fixture.pool, cli: nil, defaults: defaults)
                agentChat = ReviewAgentChat(vm: vm, projectID: entry.fixture.projectID, sessionID: entry.fixture.session.id)
            }
            return AnyView(ReviewChangesPaneView(model: entry.fixture.model, identity: entry.identity, chat: agentChat)
                .detailBackground())
        } catch {
            XCTFail("review shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// Artboard A: a worktree branch, Quick, round 2 since round 1, three Viewed, three drafts.
    static func changes() -> AnyView {
        pane("changes") {
            let fixture = try ReviewFixture(files: files, context: context, drafts: 3, overview: overview)
            fixture.openNow()
            fixture.markViewedNow(Array(files[3...5].map(\.path)))
            return (fixture, fixture.identity(place: worktree()))
        }
    }

    /// Approve's confirmation (#964, mockup 3): unviewed chapters and the
    /// toolbar's popover, on its own (a popover does not render in a shot).
    static func approvePopover() -> AnyView {
        do {
            if built["approve-popover"] == nil {
                let fixture = try ReviewFixture(files: files, context: context, overview: overview)
                fixture.openNow()
                fixture.markViewedNow(Array(files[3...5].map(\.path)))
                built["approve-popover"] = (fixture, fixture.identity(place: worktree()))
            }
            guard let entry = built["approve-popover"] else { return AnyView(EmptyView()) }
            return AnyView(ReviewApprovePopover(model: entry.fixture.model, branch: "feature/capsule-corners") {}
                .background(Surface.window))
        } catch {
            XCTFail("review shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// After Approve (#964): the green banner, the outcome in the toolbar.
    static func approved() -> AnyView {
        pane("approved") {
            let fixture = try ReviewFixture(files: files, context: context, overview: overview)
            fixture.openNow()
            var done = false
            Task { @MainActor in
                await fixture.model.approve(resolveOpen: false)
                done = true
            }
            let deadline = Date().addingTimeInterval(10)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return (fixture, fixture.identity(place: worktree()))
        }
    }

    /// Artboard A with the agent chat panel open (#962).
    static func changesWithChat() -> AnyView {
        pane("changes-chat", chat: true) {
            let fixture = try ReviewFixture(files: files, context: context, drafts: 3, overview: overview)
            fixture.openNow()
            return (fixture, fixture.identity(place: worktree()))
        }
    }

    /// Artboard B: the main folder on main, no uncommitted edits.
    static func empty() -> AnyView {
        pane("empty") {
            let fixture = try ReviewFixture(files: [], context: context)
            fixture.openNow()
            return (fixture, fixture.identity(place: .main, mainStatus: WorkbenchGitStatus(branch: "main", head: "b1")))
        }
    }

    /// The main folder on main with uncommitted edits: the notice on the branch line, the edits listed.
    static func defaultBranch() -> AnyView {
        pane("default-branch") {
            let fixture = try ReviewFixture(files: Array(files[0...2]))
            fixture.openNow()
            let status = WorkbenchGitStatus(branch: "main", head: "b1", dirty: true, changes: 3)
            return (fixture, fixture.identity(place: .main, mainStatus: status))
        }
    }

    /// Artboard C: Deep, Meaning, with the AI overview.
    static func deepMeaning() -> AnyView {
        pane("deep") {
            let fixture = try ReviewFixture(files: files, context: context, mode: "deep", phase: "meaning", drafts: 3,
                                            overview: overview)
            fixture.openNow()
            // Deep makes its overview on its own; let it land.
            let deadline = Date().addingTimeInterval(5)
            while fixture.model.overview == .loading || fixture.model.overview == .idle, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return (fixture, fixture.identity(place: worktree()))
        }
    }
}
