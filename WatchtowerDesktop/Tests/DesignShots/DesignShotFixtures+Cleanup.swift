import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Clean Up screen (board #1107), one shot per mockup frame A–G of
/// `docs/design/mockups/worktree-cleanup/screen.html`, on the mockup's rows
/// (`acme-app`, its names and sizes). Each state is reached the way the
/// app reaches it: the screen is opened and a scripted `--stream` run feeds
/// it the CLI's lines (`ScriptedCleanupStreamer`), so nothing is spawned.
/// The row counts follow these rows, not the mockup's 69 worktrees.
@MainActor
enum CleanupShotFixtures {
    enum Frame: String, CaseIterable {
        case a, b, c, d, e, f, g

        /// The frame's height in the mockup (title row included).
        var height: CGFloat {
            switch self {
            case .a: 580
            case .b: 460
            case .c: 440
            case .d: 400
            case .e: 380
            case .f: 360
            case .g: 340
            }
        }
    }

    private struct Built {
        let vm: WorkbenchesViewModel
        let project: Workbench
        /// Frame B: the confirmation's title, drawn over the screen.
        var confirmation: String?
    }

    private static var poolPaths: [String] = []
    private static var streamers: [ScriptedCleanupStreamer] = []
    /// Each frame is built once: `make` runs twice per shot (light, dark).
    private static var built: [Frame: Built] = [:]

    static func cleanUp() {
        streamers.forEach { $0.finishAll() }
        streamers = []
        built = [:]
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    static func screen(_ frame: Frame) -> AnyView {
        do {
            let state: Built
            if let cached = built[frame] {
                state = cached
            } else {
                state = try build(frame)
                built[frame] = state
            }
            return AnyView(page(state))
        } catch {
            XCTFail("cleanup shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// The title row's workbench controls (with **Clean Up ✕**) over the
    /// screen, as the page stacks them.
    private static func page(_ state: Built) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Text(state.project.name).font(.headline)
                WorkbenchHeaderControls(vm: state.vm, project: state.project, onDelete: {}, onCleanUpOldWorktrees: {})
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Stroke.hairlineColor).frame(height: Stroke.hairline)
            }
            CleanupScreenView(vm: state.vm, project: state.project)
        }
        .overlay(alignment: .top) {
            if let title = state.confirmation {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                    CleanupConfirmSheet(title: title) {}
                        .background(Surface.detail, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
                        .padding(.top, 90)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .detailBackground()
    }

    // MARK: - Frames

    private static func build(_ frame: Frame) throws -> Built {
        switch frame {
        case .a: try opened()
        case .b: try selectedAll()
        case .c: try result()
        case .d: try sessionScope()
        case .e: try failed()
        case .f: try anotherRunning()
        case .g: try nothingToCleanUp()
        }
    }

    /// A: rows listed at once, checks and sizes filling in.
    private static func opened() throws -> Built {
        let setup = try Setup()
        let checking = [
            wt("onboarding-copy", branch: "wt/onboarding-copy", origin: "placed"),
            wt("agent-c1d27e90b44f0a3d", branch: "lane/login-t3", origin: "subagent")
        ]
        let checked = [
            wt("search-filters", branch: "wt/search-filters", origin: "placed", bytes: 12_400_000_000, days: 9, merged: true),
            wt("agent-3f9c0a17d2e4b6c1", branch: "feature/export-csv", origin: "subagent", bytes: 12_000_000_000, days: 2),
            wt("billing-retry", branch: "wt/billing-retry", origin: "session", bytes: 11_000_000_000, days: 9, merged: true,
               owner: ["session_id": 7, "title": "Billing retry", "last_active": iso(days: 9)]),
            wt("agent-a4e21905ca8593e8", branch: "lane/login-t2", origin: "subagent", days: 1.2, merged: true),
            branch("old-experiment", days: 65, merged: true)
        ]
        let kept = keptRows("unpushed", count: 5, origin: "placed", reason: "unpushed_commits")
            + keptRows("recent", count: 3, origin: "session", reason: "session_recent")
            + keptRows("in-use", count: 1, origin: "manual", reason: "process_running")
        let all = checked + kept + checking
        try setup.open()
        let run = try setup.run(0)
        run.send(listed(all))
        for item in checked + kept { run.send(event("checked", item: item)) }
        try setup.spin("A's checks") { setup.progress?.checking.count == checking.count }
        return setup.built
    }

    /// B's and C's plan: the mockup's older-than-30-days merged rows.
    private static let filteredPlan: [[String: Any]] = [
        wt("import-wizard", branch: "wt/import-wizard", origin: "placed", bytes: 12_000_000_000, days: 36, merged: true),
        branch("wt/import-wizard", days: 36, merged: true),
        wt("agent-77ab01c3e9d2f450", branch: "lane/import-t4", origin: "subagent", bytes: 9_800_000_000, days: 37, merged: true),
        branch("lane/import-t4", days: 37, merged: true),
        wt("acme-app-legacy", branch: "feature/legacy-sync", origin: "manual", bytes: 3_100_000_000, days: 65, merged: true),
        branch("feature/legacy-sync", days: 65, merged: true, action: "keep", reason: "checked_out"),
        branch("old-experiment", days: 65, merged: true),
        wt("payments-spike", branch: "wt/payments-spike", origin: "placed", bytes: 12_000_000_000, days: 44, merged: true,
           action: "keep", reason: "unpushed_commits"),
        branch("draft-thing", days: 95, merged: true, action: "keep", reason: "unpushed_commits"),
        // Shown without the filters only.
        wt("search-filters", branch: "wt/search-filters", origin: "placed", bytes: 12_000_000_000, days: 9, merged: true)
    ]

    private static var olderMerged: CleanupFilters {
        var filters = CleanupFilters()
        filters.age = .days30
        filters.mergedOnly = true
        return filters
    }

    /// B: filtered, Select All That Can Go, then Clean Up….
    private static func selectedAll() throws -> Built {
        let setup = try Setup(checkedAgo: 60)
        try setup.plan(filteredPlan)
        setup.vm.cleanupScreens[setup.projectID]?.filters = olderMerged
        let model = try XCTUnwrap(setup.vm.cleanupScreenModel(projectID: setup.projectID))
        let ticks = model.selectAll(filters: olderMerged, into: [])
        setup.vm.cleanupScreens[setup.projectID]?.ticks = ticks
        var built = setup.built
        built.confirmation = model.confirmationTitle(for: model.liveTicks(ticks))
        return built
    }

    /// C: the apply's result — two worktrees and two branches gone, one
    /// kept because it changed since the check.
    private static func result() throws -> Built {
        let setup = try Setup()
        try setup.plan(filteredPlan)
        setup.vm.cleanupScreens[setup.projectID]?.filters = olderMerged
        let model = try XCTUnwrap(setup.vm.cleanupScreenModel(projectID: setup.projectID))
        setup.vm.cleanupScreens[setup.projectID]?.ticks = model.selectAll(filters: olderMerged, into: [])
        let vm = setup.vm, projectID = setup.projectID
        Task { await vm.applyCleanupScreen(projectID: projectID) }
        try setup.spin("C's apply") { setup.streamer.runs.count == 2 }
        let apply = try setup.run(1)
        let gone = [key("import-wizard"), key("wt/import-wizard", kind: "branch"), key("acme-app-legacy"),
                    key("old-experiment", kind: "branch")]
        for removing in gone { apply.send(#"{"event":"removing","key":"\#(removing)"}"#) }
        // agent-77ab… moved since the check: kept, with its branch.
        let moved = key("agent-77ab01c3e9d2f450")
        let items: [[String: Any]] = filteredPlan.compactMap { item in
            let itemKey = item["key"] as? String ?? ""
            if gone.contains(itemKey) { return item.merging(["done": true]) { $1 } }
            if itemKey == moved { return item.merging(["action": "keep", "reason": "moved"]) { $1 } }
            return itemKey == key("lane/import-t4", kind: "branch") ? nil : item
        }
        apply.send(done(items, mode: "apply", removed: 15_100_000_000))
        apply.finish()
        try setup.spin("C's result") { vm.sweepRuns[projectID] == nil }
        return setup.built
    }

    /// D: one session's scope, opened from its row.
    private static func sessionScope() throws -> Built {
        let setup = try Setup()
        let session = try setup.insertSession("Login redirect")
        try setup.plan([
            wt("login-redirect", branch: "wt/login-redirect", origin: "session", bytes: 12_000_000_000, minutes: 20,
               owner: ["session_id": session.id, "title": "Login redirect", "last_active": iso(days: 1.0 / 24)]),
            branch("wt/login-redirect", minutes: 20),
            wt("agent-5be0c2a19f7d3e64", branch: "lane/login-redirect-t1", origin: "subagent", bytes: 96_000_000,
               minutes: 60, merged: true),
            branch("lane/login-redirect-t1", minutes: 60, merged: true),
            wt("login-redirect-notes", branch: "wt/login-redirect-notes", origin: "subagent", bytes: 40_000_000,
               minutes: 30, action: "keep", reason: "uncommitted_changes")
        ], sessionID: session.id)
        return setup.built
    }

    /// E: the whole apply failed; the rows still ticked stay.
    private static func failed() throws -> Built {
        let setup = try Setup()
        try setup.plan([
            wt("import-wizard", branch: "wt/import-wizard", origin: "placed", bytes: 12_000_000_000, days: 36, merged: true),
            branch("wt/import-wizard", days: 36, merged: true),
            branch("old-experiment", days: 65, merged: true)
        ])
        let vm = setup.vm, projectID = setup.projectID
        vm.cleanupScreens[projectID]?.ticks = [key("import-wizard"), key("old-experiment", kind: "branch")]
        Task { await vm.applyCleanupScreen(projectID: projectID) }
        try setup.spin("E's apply") { setup.streamer.runs.count == 2 }
        try setup.run(1).finish(status: 1, message: "git is not reachable (exit 1). Nothing after it was touched.")
        try setup.spin("E's failure") { vm.sweepRuns[projectID] == nil }
        return setup.built
    }

    /// F: a Delete and Clean Up of another session of the workbench is
    /// applying: ticking works, Refresh and Clean Up… wait.
    private static func anotherRunning() throws -> Built {
        let setup = try Setup(checkedAgo: 120)
        try setup.plan([
            wt("search-filters", branch: "wt/search-filters", origin: "placed", bytes: 12_400_000_000, days: 9, merged: true),
            wt("agent-3f9c0a17d2e4b6c1", branch: "feature/export-csv", origin: "subagent", bytes: 12_000_000_000, days: 2)
        ])
        setup.vm.cleanupScreens[setup.projectID]?.ticks = [key("search-filters")]
        let other = try setup.insertSession("Billing export")
        setup.center.startStreamedApply(.session(other.id), workbenchID: setup.projectID, items: [key("billing-export")])
        try setup.spin("F's other apply") { setup.streamer.runs.count == 2 }
        return setup.built
    }

    /// G: nothing can go; one worktree kept with its branch.
    private static func nothingToCleanUp() throws -> Built {
        let setup = try Setup()
        try setup.plan([
            wt("pricing-draft", branch: "wt/pricing-draft", origin: "placed", bytes: 2_000_000_000, days: 4,
               action: "keep", reason: "unpushed_commits"),
            branch("wt/pricing-draft", days: 4, action: "keep", reason: "unpushed_commits")
        ])
        return setup.built
    }

    // MARK: - Setup

    /// One workbench page with a scripted cleanup center.
    @MainActor
    private final class Setup {
        let vm: WorkbenchesViewModel
        let project: Workbench
        let center: SessionCleanupCenter
        let streamer = ScriptedCleanupStreamer()
        private let pool: DatabasePool
        private var sessionID: Int64?

        var projectID: Int64 { project.id }
        var built: Built { Built(vm: vm, project: project) }

        var progress: SessionCleanupProgress? { vm.cleanupScreenProgress(projectID: projectID) }

        /// `checkedAgo`: how long ago the plan was ready, in seconds.
        init(checkedAgo: TimeInterval = 0) throws {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            streamers.append(streamer)
            self.pool = pool
            project = try pool.write { db in
                let id = try TestDatabase.insertWorkbench(db, name: "acme-app", folder: "/tmp/acme-app")
                return try XCTUnwrap(try Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
            }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
            vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
            vm.selectedWorkbenchID = project.id
            center = SessionCleanupCenter(runner: nil, streamer: streamer)
            center.baseEnvironment = { [:] }
            center.eventBatchInterval = .zero
            center.now = { Date().addingTimeInterval(-checkedAgo) }
            vm.sessionCleanup = center
        }

        func insertSession(_ title: String) throws -> TerminalSession {
            let projectID = projectID
            let session = try pool.write { db in
                try TerminalSessionQueries.create(db, .init(
                    projectID: projectID, kind: .claude, title: title,
                    folderPath: "/tmp/acme-app", claudeSessionID: UUID().uuidString.lowercased()
                ))
            }
            final class Flag { var done = false }
            let loaded = Flag()
            Task { @MainActor [vm] in
                _ = await vm.loadSessions(projectID: projectID)
                loaded.done = true
            }
            try spin("sessions") { loaded.done }
            return session
        }

        func open(sessionID: Int64? = nil) throws {
            vm.openCleanupScreen(projectID: projectID, sessionID: sessionID)
            try spin("the plan's run") { !streamer.runs.isEmpty }
        }

        func run(_ index: Int) throws -> ScriptedCleanupStreamer.Run {
            let runs = streamer.runs
            guard runs.count > index else { throw FixtureError.noRun(index) }
            return runs[index]
        }

        /// Opens the screen and lands a ready plan of `items`.
        func plan(_ items: [[String: Any]], sessionID: Int64? = nil) throws {
            try open(sessionID: sessionID)
            let run = try run(0)
            run.send(listed(items))
            run.send(done(items, mode: "plan"))
            run.finish()
            try spin("the plan") {
                if case .ready = progress?.stage { return true }
                return false
            }
        }

        /// Runs the main run loop until `condition` (the shot renders at once).
        func spin(_ what: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                guard Date() < deadline else { throw FixtureError.timedOut(what) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
    }

    private enum FixtureError: Error {
        case noRun(Int)
        case timedOut(String)
    }

    // MARK: - Stream lines

    private static let root = "/tmp/acme-app/.claude/worktrees/"

    private static func key(_ name: String, kind: String = "worktree") -> String {
        kind == "worktree" ? "worktree:\(root)\(name)" : "branch:\(name)"
    }

    private static func iso(days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86400))
    }

    /// A's folded Kept group: `count` worktrees kept for `reason`.
    private static func keptRows(_ prefix: String, count: Int, origin: String, reason: String) -> [[String: Any]] {
        (1...count).map { index in
            wt("\(prefix)-\(index)", branch: "wt/\(prefix)-\(index)", origin: origin, bytes: 1_000_000_000, days: 3,
               action: "keep", reason: reason)
        }
    }

    private static func wt(
        _ name: String,
        branch: String,
        origin: String,
        bytes: Int64? = nil,
        days: Double? = nil,
        minutes: Double? = nil,
        merged: Bool = false,
        action: String = "remove",
        reason: String = "",
        owner: [String: Any]? = nil
    ) -> [String: Any] {
        var item: [String: Any] = [
            "key": key(name), "kind": "worktree", "name": root + name, "branch": branch, "origin": origin,
            "action": action, "reason": reason, "merged": merged
        ]
        if let bytes {
            item["bytes"] = bytes
            item["bytes_known"] = true
        }
        if let ago = days ?? minutes.map({ $0 / 1440 }) { item["last_commit_at"] = iso(days: ago) }
        if let owner { item["owner"] = owner }
        return item
    }

    private static func branch(
        _ name: String,
        days: Double? = nil,
        minutes: Double? = nil,
        merged: Bool = false,
        action: String = "remove",
        reason: String = ""
    ) -> [String: Any] {
        var item: [String: Any] = [
            "key": key(name, kind: "branch"), "kind": "branch", "name": name, "action": action, "reason": reason,
            "merged": merged
        ]
        if let ago = days ?? minutes.map({ $0 / 1440 }) { item["last_commit_at"] = iso(days: ago) }
        return item
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// `listed` names each item before any check: key, kind, name, branch
    /// and who made it.
    private static func listed(_ items: [[String: Any]]) -> String {
        let bare = items.map { item in
            item.filter { ["key", "kind", "name", "branch", "origin"].contains($0.key) }
        }
        return line(["event": "listed", "items": bare])
    }

    private static func event(_ name: String, item: [String: Any]) -> String {
        line(["event": name, "item": item])
    }

    private static func done(_ items: [[String: Any]], mode: String, removed: Int64 = 0) -> String {
        line(["event": "done", "plan": [
            "mode": mode, "sweep": true, "items": items, "removed_bytes": removed, "removed_bytes_known": true
        ] as [String: Any]])
    }
}
