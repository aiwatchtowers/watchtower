import XCTest
import WatchtowerCore

final class CleanupScreenModelTests: XCTestCase {
    private typealias Item = SessionCleanupItem
    private typealias Model = CleanupScreenModel

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400
    private let root = "/work/acme/.claude/worktrees/"

    // MARK: Fixtures

    private func worktree(
        _ name: String,
        branch: String = "",
        gb: Double? = 1,
        merged: Bool = true,
        origin: SessionCleanupOrigin = .placed,
        daysAgo: Double? = 9,
        keep reason: SessionCleanupReason.Code? = nil,
        owner: SessionCleanupOwner? = nil
    ) -> Item {
        // Go names a worktree by its folder's base name; its root is the key's.
        Item(
            key: "worktree:\(root)\(name)", kind: .worktree, name: name, branch: branch,
            bytes: gb.map { Int64($0 * 1_000_000_000) } ?? 0, bytesKnown: gb != nil,
            action: reason == nil ? .remove : .keep, reason: reason.map(SessionCleanupReason.known),
            owner: owner, origin: origin,
            lastCommitAt: daysAgo.map { now.addingTimeInterval(-$0 * day) }, merged: merged
        )
    }

    private func branch(
        _ name: String, merged: Bool = true, daysAgo: Double? = 9, keep reason: SessionCleanupReason.Code? = nil
    ) -> Item {
        Item(
            key: "branch:\(name)", kind: .branch, name: name,
            action: reason == nil ? .remove : .keep, reason: reason.map(SessionCleanupReason.known),
            lastCommitAt: daysAgo.map { now.addingTimeInterval(-$0 * day) }, merged: merged
        )
    }

    private func bundle(_ path: String, of worktree: String = "") -> Item {
        Item(key: "lsreg:\(path)", kind: .lsreg, name: path, action: .remove, worktree: worktree)
    }

    private func orphan(_ pid: Int, of worktree: String) -> Item {
        Item(key: "process:\(pid):Mon Oct 12 10:00:00 2026", kind: .process, name: "stub",
             bytesKnown: true, action: .remove, detail: worktree + "/.build/stub", worktree: worktree)
    }

    private func model(_ items: [Item], checking: Set<String> = [], sizing: Set<String> = []) -> Model {
        Model(items: items, checking: checking, sizing: sizing, now: now)
    }

    private func all(_ model: Model, filters: CleanupFilters = CleanupFilters()) -> [CleanupRow] {
        let rows = model.rows(filters: filters, sort: .size, ascending: false)
        return rows.canGo + rows.kept
    }

    private func row(_ id: String, in model: Model) -> CleanupRow? {
        all(model).first { $0.id == id }
    }

    // MARK: Pairing

    func testWorktreeRowCarriesItsBranchAndBundles() {
        let wt = worktree("billing", branch: "wt/billing")
        let m = model([
            wt, branch("wt/billing"),
            bundle(root + "billing/build/Acme.app", of: root + "billing"),
            bundle(root + "billing/build/Helper.app", of: root + "billing")
        ])
        let rows = all(m)
        XCTAssertEqual(rows.map(\.id), [wt.key])
        XCTAssertEqual(rows[0].title, "billing")
        XCTAssertEqual(rows[0].subtitle, "wt/billing")
        XCTAssertNil(rows[0].branchNote)
        XCTAssertEqual(rows[0].applyKeys, [
            wt.key, "branch:wt/billing",
            "lsreg:\(root)billing/build/Acme.app", "lsreg:\(root)billing/build/Helper.app"
        ])
    }

    /// A session's orphan process folds into its worktree's row: no row of
    /// its own (a `process:` key alone is never acted on), sent with the
    /// worktree, and not counted in the footer.
    func testOrphanProcessFoldsIntoItsWorktree() {
        let wt = worktree("billing", branch: "wt/billing")
        let proc = orphan(501, of: root + "billing")
        let m = model([wt, branch("wt/billing"), proc])
        XCTAssertEqual(all(m).map(\.id), [wt.key])
        XCTAssertEqual(row(wt.key, in: m)?.applyKeys, [wt.key, "branch:wt/billing", proc.key])
        XCTAssertEqual(m.totalText(for: [wt.key]), "1 worktree, 1 branch · ~1.0 GB")
    }

    /// The real `workbench cleanup --json --stream` lines (written by Go's
    /// `TestCleanupCmd_StreamGoldenForTheDesktop`) build one worktree row that
    /// sends its worktree, branch, bundle and orphan — mid-stream and done.
    func testGoStreamFixtureBuildsOneRow() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session-cleanup-stream.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        var checked: [Item] = []
        var plan: SessionCleanupPlan?
        for line in lines {
            switch SessionCleanupEvent.decode(line: line) {
            case let .checked(item): checked.append(item)
            case let .done(done): plan = done
            default: break
            }
        }
        let wtKey = "worktree:/work/acme/wt-golden"
        let want: Set = [
            wtKey, "branch:feat/golden", "lsreg:/work/acme/wt-golden/Build/App.app",
            "process:501:Mon Oct 12 10:00:00 2026"
        ]
        for items in [checked, try XCTUnwrap(plan).items] {
            let rows = all(model(items))
            XCTAssertEqual(rows.map(\.id), [wtKey])
            XCTAssertEqual(rows.first?.title, "wt-golden")
            XCTAssertEqual(Set(rows.first?.applyKeys ?? []), want)
            XCTAssertEqual(rows.first?.applyKeys.count, 4)
        }
    }

    func testKeptBranchIsNotSentWithItsWorktree() {
        let wt = worktree("legacy", branch: "feature/legacy-sync", origin: .manual)
        let lsreg = bundle(root + "legacy/Acme.app", of: root + "legacy")
        let m = model([wt, branch("feature/legacy-sync", keep: .checkedOut), lsreg])
        let only = row(wt.key, in: m)
        XCTAssertEqual(all(m).count, 1)
        XCTAssertEqual(only?.branchNote, "branch kept — checked out elsewhere")
        XCTAssertEqual(only?.applyKeys, [wt.key, lsreg.key])
        XCTAssertEqual(m.applyKeys(for: [wt.key]), [wt.key, lsreg.key])
    }

    func testBranchOnlyAndStaleEntryRows() {
        let stale = bundle("/work/acme/build/Old.app")
        let m = model([branch("old-experiment", daysAgo: 60), stale])
        let branchRow = row("branch:old-experiment", in: m)
        XCTAssertEqual(branchRow?.title, "old-experiment")
        XCTAssertEqual(branchRow?.subtitle, "branch only")
        XCTAssertEqual(branchRow?.sizeText, "—")
        XCTAssertNil(branchRow?.bytes)
        XCTAssertEqual(branchRow?.applyKeys, ["branch:old-experiment"])
        let staleRow = row(stale.key, in: m)
        XCTAssertEqual(staleRow?.title, "LaunchServices entry")
        XCTAssertEqual(staleRow?.subtitle, "/work/acme/build/Old.app")
        XCTAssertEqual(staleRow?.applyKeys, [stale.key])
        // Merged and Pushed speak of commits: a stale entry has none.
        XCTAssertEqual(staleRow?.state, .staleEntry)
        XCTAssertEqual(staleRow?.canChoose, true)
    }

    // MARK: States

    func testCheckingRowsCannotBeChosen() {
        let checked = worktree("a", gb: 2)
        let pending = worktree("b", gb: nil)
        let m = model([checked, pending], checking: [pending.key])
        let row = row(pending.key, in: m)
        XCTAssertEqual(row?.state, .checking)
        XCTAssertEqual(row?.sizeText, "checking")
        XCTAssertEqual(row?.canChoose, false)
        XCTAssertEqual(m.selectAll(filters: CleanupFilters(), into: []), [checked.key])
    }

    func testStatesAndSizes() {
        let merged = worktree("merged", gb: 12)
        let pushed = worktree("pushed", gb: 2, merged: false)
        let measuring = worktree("measuring", gb: nil)
        let unknown = worktree("unknown", gb: nil)
        var failed = worktree("failed")
        failed.error = "git exited 128"
        let m = model([merged, pushed, measuring, unknown, failed], sizing: [measuring.key])
        XCTAssertEqual(row(merged.key, in: m)?.state, .merged)
        XCTAssertEqual(row(merged.key, in: m)?.sizeText, "~12 GB")
        XCTAssertEqual(row(merged.key, in: m)?.bytes, 12_000_000_000)
        XCTAssertEqual(row(pushed.key, in: m)?.state, .pushed)
        XCTAssertEqual(row(measuring.key, in: m)?.sizeText, "measuring")
        XCTAssertEqual(row(unknown.key, in: m)?.sizeText, "size unknown")
        XCTAssertEqual(row(failed.key, in: m)?.state, .failed("git exited 128"))
        XCTAssertEqual(row(failed.key, in: m)?.canChoose, false)
        XCTAssertEqual(row(merged.key, in: m)?.lastCommitText, "9 days ago")
        let recent = worktree("recent", daysAgo: 1.0 / 24)
        XCTAssertEqual(row(recent.key, in: model([recent]))?.lastCommitText, "1 hour ago")
    }

    func testRemovingAndRemovedRows() {
        let going = worktree("going")
        var gone = worktree("gone")
        gone.done = true
        let m = Model(items: [going, gone], checking: [], sizing: [], removing: [going.key], now: now)
        XCTAssertEqual(all(m).map(\.id), [going.key])
        XCTAssertEqual(row(going.key, in: m)?.state, .removing)
        XCTAssertEqual(row(going.key, in: m)?.canChoose, false)
    }

    func testKeptGoLastWithReasons() {
        let goes = worktree("goes")
        let kept = [
            worktree("u1", keep: .unpushedCommits), worktree("u2", keep: .unpushedCommits),
            branch("draft", keep: .unpushedCommits),
            worktree("r1", keep: .sessionRecent), worktree("r2", keep: .sessionRecent),
            worktree("busy", keep: .processRunning),
            worktree("moved", keep: .moved)
        ]
        let m = model([goes] + kept)
        let rows = m.rows(filters: CleanupFilters(), sort: .size, ascending: false)
        XCTAssertEqual(rows.canGo.map(\.id), [goes.key])
        XCTAssertEqual(Set(rows.kept.map(\.id)), Set(kept.map(\.key)))
        XCTAssertTrue(rows.kept.allSatisfy { !$0.canChoose && $0.applyKeys.isEmpty })
        XCTAssertEqual(row("branch:draft", in: m)?.state, .kept("Unpushed commits"))
        XCTAssertEqual(row(kept[6].key, in: m)?.state, .changedSinceCheck("Changed since the check"))
        XCTAssertEqual(m.keptSummary(), "3 unpushed commits · 2 recent sessions · 1 in use · 1 changed since the check")
        XCTAssertEqual(model([worktree("r", keep: .sessionRecent)]).keptSummary(), "1 recent session")
        XCTAssertEqual(model([goes]).keptSummary(), "")
    }

    // MARK: Filters and ticking

    func testFiltersAndSelectAll() {
        let old = worktree("old", daysAgo: 40)
        let oldPushed = worktree("old-pushed", merged: false, daysAgo: 40)
        let fresh = worktree("fresh", daysAgo: 3)
        let oldBranch = branch("old-branch", daysAgo: 70)
        let oldKept = worktree("old-kept", daysAgo: 50, keep: .unpushedCommits)
        let oldChecking = worktree("old-checking", daysAgo: 45)
        let m = model([old, oldPushed, fresh, oldBranch, oldKept, oldChecking], checking: [oldChecking.key])
        var filters = CleanupFilters()
        filters.age = .days30
        filters.mergedOnly = true
        let ticks = m.selectAll(filters: filters, into: ["existing"])
        XCTAssertEqual(ticks, ["existing", old.key, oldBranch.key])

        filters = CleanupFilters()
        filters.kind = .branches
        XCTAssertEqual(m.rows(filters: filters, sort: .name, ascending: true).canGo.map(\.id), [oldBranch.key])
        filters.kind = .worktrees
        filters.search = "PUSHED"
        XCTAssertEqual(m.rows(filters: filters, sort: .name, ascending: true).canGo.map(\.id), [oldPushed.key])
        filters = CleanupFilters()
        filters.owner = .subagent
        XCTAssertTrue(m.rows(filters: filters, sort: .name, ascending: true).canGo.isEmpty)
        filters.owner = .placed
        XCTAssertEqual(m.rows(filters: filters, sort: .name, ascending: true).canGo.count, 4)
    }

    func testHiddenTicksCountAndStaleTicksDrop() {
        let shown = worktree("shown", gb: 12, daysAgo: 40)
        let hidden = worktree("hidden", gb: 3, daysAgo: 2)
        let m = model([shown, hidden])
        var filters = CleanupFilters()
        filters.age = .days30
        XCTAssertEqual(m.rows(filters: filters, sort: .size, ascending: false).canGo.map(\.id), [shown.key])
        let ticks: Set<String> = [shown.key, hidden.key]
        XCTAssertEqual(m.totalText(for: ticks), "2 worktrees · ~15 GB")
        XCTAssertEqual(m.applyKeys(for: ticks), [shown.key, hidden.key])

        let refreshed = model([shown, worktree("hidden", gb: 3, daysAgo: 2, keep: .uncommittedChanges)])
        XCTAssertEqual(refreshed.liveTicks(ticks.union(["worktree:gone"])), [shown.key])
        let rechecking = model([shown, hidden], checking: [shown.key])
        XCTAssertEqual(rechecking.liveTicks(ticks), ticks)
        XCTAssertEqual(rechecking.applyKeys(for: ticks), [hidden.key])
    }

    func testRangeSkipsRowsThatCannotBeChosen() {
        let items = (1...5).map { worktree("r\($0)", gb: Double(10 - $0)) }
        let m = model(items, checking: [items[2].key])
        let rows = m.rows(filters: CleanupFilters(), sort: .name, ascending: true).canGo
        XCTAssertEqual(rows.map(\.id), items.map(\.key))
        let on = m.tickRange(from: items[4].key, to: items[0].key, in: rows, on: true, ticks: [])
        XCTAssertEqual(on, Set([0, 1, 3, 4].map { items[$0].key }))
        let off = m.tickRange(from: items[1].key, to: items[3].key, in: rows, on: false, ticks: on)
        XCTAssertEqual(off, Set([items[0].key, items[4].key]))
    }

    // MARK: Sorting

    func testDefaultSortIsSizeDescendingUnmeasuredLast() {
        let small = worktree("small", gb: 1, daysAgo: 1)
        let big = worktree("big", gb: 12, daysAgo: 30)
        let unmeasured = worktree("unmeasured", gb: nil, daysAgo: 5)
        let branchOnly = branch("a-branch", daysAgo: nil)
        let m = model([small, unmeasured, branchOnly, big])
        XCTAssertEqual(
            m.rows(filters: CleanupFilters(), sort: .size, ascending: false).canGo.map(\.id),
            [big.key, small.key, branchOnly.key, unmeasured.key]
        )
        XCTAssertEqual(
            m.rows(filters: CleanupFilters(), sort: .size, ascending: true).canGo.map(\.id),
            [small.key, big.key, branchOnly.key, unmeasured.key]
        )
        XCTAssertEqual(
            m.rows(filters: CleanupFilters(), sort: .name, ascending: true).canGo.map(\.id),
            [branchOnly.key, big.key, small.key, unmeasured.key]
        )
        XCTAssertEqual(
            m.rows(filters: CleanupFilters(), sort: .lastCommit, ascending: false).canGo.map(\.id),
            [small.key, unmeasured.key, big.key, branchOnly.key]
        )
    }

    /// Mockup A: sized rows, then the measuring one and the branch with no
    /// size, then the rows still being checked — in either direction.
    func testRowsStillCheckingSortAfterTheOtherUnmeasured() {
        let sized = worktree("search-filters", gb: 12)
        let measuring = worktree("agent-a4e2", gb: nil)
        let branchOnly = branch("old-experiment")
        let checkingA = worktree("agent-c1d2", gb: nil)
        let checkingB = worktree("onboarding-copy", gb: nil)
        let m = model([checkingB, branchOnly, checkingA, measuring, sized],
                      checking: [checkingA.key, checkingB.key], sizing: [measuring.key])
        let expected = [sized.key, measuring.key, branchOnly.key, checkingA.key, checkingB.key]
        for ascending in [false, true] {
            XCTAssertEqual(m.rows(filters: CleanupFilters(), sort: .size, ascending: ascending).canGo.map(\.id), expected)
        }
        let byCommit = m.rows(filters: CleanupFilters(), sort: .lastCommit, ascending: false).canGo.map(\.id)
        XCTAssertEqual(byCommit.suffix(2), [checkingA.key, checkingB.key], "checking rows last among the ties")
    }

    // MARK: Copy

    func testOwnerText() {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * day))
        let session = worktree("billing-retry", origin: .session,
                               owner: SessionCleanupOwner(sessionID: 4, title: "Billing retry", lastActive: stamp))
        let untitled = worktree("untitled", origin: .session, owner: SessionCleanupOwner(sessionID: 7))
        let sub = worktree("agent-3f9c0a17d2e4b6c1", origin: .subagent)
        let placed = worktree("search-filters", origin: .placed)
        let manual = worktree("legacy", origin: .manual)
        let m = model([session, untitled, sub, placed, manual, branch("old")])
        XCTAssertEqual(row(session.key, in: m)?.ownerText, "“Billing retry” · active 9 days ago")
        XCTAssertEqual(row(untitled.key, in: m)?.ownerText, "Session 7")
        XCTAssertEqual(row(sub.key, in: m)?.ownerText, "Subagent")
        XCTAssertEqual(row(placed.key, in: m)?.ownerText, "Session deleted")
        XCTAssertEqual(row(manual.key, in: m)?.ownerText, "Made by hand")
        XCTAssertEqual(row("branch:old", in: m)?.ownerText, "—")
    }

    func testTotalsAndConfirmation() {
        let a = worktree("a", branch: "wt/a", gb: 12)
        let b = worktree("b", branch: "wt/b", gb: 9.8)
        let c = worktree("c", branch: "feature/c", gb: 3.1)
        let m = model([a, branch("wt/a"), b, branch("wt/b"), c, branch("feature/c", keep: .checkedOut),
                       branch("old-experiment")])
        let ticks: Set<String> = [a.key, b.key, c.key, "branch:old-experiment"]
        XCTAssertEqual(m.totalText(for: ticks), "3 worktrees, 3 branches · ~25 GB")
        XCTAssertEqual(m.confirmationTitle(for: ticks), "Remove 3 worktrees and 3 branches (~25 GB)?")
        XCTAssertEqual(m.totalText(for: []), "Nothing selected")
        XCTAssertEqual(m.totalText(for: ["branch:old-experiment"]), "1 branch")
        XCTAssertEqual(m.confirmationTitle(for: ["branch:old-experiment"]), "Remove 1 branch?")

        let unmeasured = worktree("d", gb: nil)
        let m2 = model([a, unmeasured])
        XCTAssertEqual(m2.totalText(for: [a.key, unmeasured.key]), "2 worktrees · ~12 GB, some sizes unknown")
        XCTAssertEqual(m2.confirmationTitle(for: [a.key, unmeasured.key]),
                       "Remove 2 worktrees (~12 GB, some sizes unknown)?")
        XCTAssertEqual(m2.totalText(for: [unmeasured.key]), "1 worktree · size unknown")
    }

    /// The view's typed facts (Task 10 review): no matching of display strings.
    func testPendingSizeOwnerAndTotalParts() {
        let checked = worktree("checked", gb: 12)
        let checking = worktree("checking", gb: nil)
        let measuring = worktree("measuring", gb: nil)
        let m = model([checked, checking, measuring, branch("old")], checking: [checking.key], sizing: [measuring.key])
        XCTAssertEqual(row(checked.key, in: m)?.sizePending, false)
        XCTAssertEqual(row(checking.key, in: m)?.sizePending, true)
        XCTAssertEqual(row(measuring.key, in: m)?.sizePending, true)
        XCTAssertEqual(row("branch:old", in: m)?.sizePending, false)
        XCTAssertEqual(row(checked.key, in: m)?.hasOwner, true)
        XCTAssertEqual(row("branch:old", in: m)?.hasOwner, false)

        XCTAssertNil(m.totalParts(for: []))
        XCTAssertEqual(m.totalParts(for: [checked.key])?.counts, "1 worktree")
        XCTAssertEqual(m.totalParts(for: [checked.key])?.size, "~12 GB")
        XCTAssertNil(m.totalParts(for: ["branch:old"])?.size)
    }

    /// The screen's own words (mockups D and G).
    func testEmptyKeptLineAndChipCopy() {
        XCTAssertEqual(model([worktree("u", keep: .unpushedCommits)]).emptyKeptText(), "Kept: 1 — unpushed commits")
        XCTAssertEqual(
            model([worktree("u1", keep: .unpushedCommits), worktree("u2", keep: .unpushedCommits),
                   worktree("r", keep: .sessionRecent)]).emptyKeptText(),
            "Kept: 3 — 2 unpushed commits · 1 recent session"
        )
        XCTAssertNil(model([worktree("goes")]).emptyKeptText())
        XCTAssertEqual(Model.showKeptTitle, "Show kept")
        XCTAssertEqual(Model.sessionChipText(title: "Login redirect", sessionID: 3), "Session: “Login redirect” ✕")
        XCTAssertEqual(Model.sessionChipText(title: nil, sessionID: 3), "Session: “Session 3” ✕")
        XCTAssertEqual(Model.sessionChipText(title: "", sessionID: 3), "Session: “Session 3” ✕")
    }

    func testResultLine() {
        func done(_ item: Item) -> Item {
            var copy = item
            copy.done = true
            return copy
        }
        let items = [
            done(worktree("a", branch: "wt/a")), done(branch("wt/a")),
            done(worktree("b", branch: "wt/b")), done(branch("wt/b")),
            worktree("c", keep: .moved),
            worktree("d", keep: .notSelected)
        ]
        var plan = SessionCleanupPlan(mode: "apply", items: items, removedBytes: 15_000_000_000, removedBytesKnown: true)
        let sent = Set(items.prefix(5).map(\.key))
        XCTAssertEqual(Model.resultText(plan, sent: sent).freed, "Freed ~15 GB · removed 2 worktrees, 2 branches")
        XCTAssertEqual(Model.resultText(plan, sent: sent).kept, "kept 1 — changed since the check")
        plan.removedBytesKnown = false
        XCTAssertEqual(Model.resultText(plan, sent: sent).freed,
                       "Freed at least ~15 GB · removed 2 worktrees, 2 branches")

        let none = SessionCleanupPlan(mode: "apply", items: [
            worktree("x", keep: .unpushedCommits), branch("y", keep: .unpushedCommits)
        ], removedBytesKnown: true)
        let noneSent = Set(none.items.map(\.key))
        XCTAssertEqual(Model.resultText(none, sent: noneSent).freed, "Nothing removed")
        XCTAssertEqual(Model.resultText(none, sent: noneSent).kept, "kept 2 — unpushed commits")

        let mixed = SessionCleanupPlan(mode: "apply", items: [
            done(branch("z")),
            worktree("x", keep: .unpushedCommits), branch("y", keep: .unpushedCommits), worktree("m", keep: .moved)
        ], removedBytesKnown: true)
        let mixedSent = Set(mixed.items.map(\.key))
        XCTAssertEqual(Model.resultText(mixed, sent: mixedSent).freed, "Removed 1 branch")
        XCTAssertEqual(Model.resultText(mixed, sent: mixedSent).kept,
                       "kept 3 — 2 unpushed commits, 1 changed since the check")
        XCTAssertNil(Model.resultText(SessionCleanupPlan(items: [done(branch("z"))]), sent: ["branch:z"]).kept)
    }

    /// Mockup C: two rows were kept at plan time (unpushed commits) and never
    /// ticked; the one ticked row whose tip moved is the only "kept".
    func testPlanTimeKeepsThatWereNotSentAreNotCounted() {
        var removed = worktree("import-wizard", branch: "wt/import-wizard")
        removed.done = true
        var removedBranch = branch("wt/import-wizard")
        removedBranch.done = true
        let moved = worktree("agent-77ab01c3e9d2f450", keep: .moved)
        let plan = SessionCleanupPlan(mode: "apply", items: [
            removed, removedBranch, moved,
            worktree("payments-spike", keep: .unpushedCommits), branch("draft-thing", keep: .unpushedCommits)
        ], removedBytes: 15_000_000_000, removedBytesKnown: true)
        let result = Model.resultText(plan, sent: [removed.key, removedBranch.key, moved.key])
        XCTAssertEqual(result.freed, "Freed ~15 GB · removed 1 worktree, 1 branch")
        XCTAssertEqual(result.kept, "kept 1 — changed since the check")
    }

    func testProgressLineCopy() {
        func text(_ stage: CleanupStage, _ worktrees: Int = 69, _ branches: Int = 130) -> String {
            Model.progressText(stage, worktrees: worktrees, branches: branches, sessionScope: false, now: now)
        }
        XCTAssertEqual(text(.listing), "Listing worktrees…")
        XCTAssertEqual(text(.checking(done: 23, of: 69)), "Checking 23 of 69 worktrees…")
        XCTAssertEqual(text(.checking(done: 0, of: 1)), "Checking 0 of 1 worktree…")
        XCTAssertEqual(text(.sizing(done: 4, of: 53)), "Measuring sizes 4 of 53…")
        XCTAssertEqual(text(.ready(at: now.addingTimeInterval(-30))), "Checked just now · 69 worktrees, 130 branches")
        XCTAssertEqual(text(.ready(at: now.addingTimeInterval(-70))), "Checked 1 min ago · 69 worktrees, 130 branches")
        XCTAssertEqual(text(.ready(at: now.addingTimeInterval(-7200))), "Checked 2 h ago · 69 worktrees, 130 branches")
        XCTAssertEqual(text(.ready(at: now), 1, 1), "Checked just now · 1 worktree, 1 branch")
        XCTAssertEqual(text(.applying), "Removing…")
        XCTAssertEqual(text(.failed("git is not reachable (exit 1).")), "Clean up failed: git is not reachable (exit 1).")
        let plan = SessionCleanupPlan(mode: "apply", items: [], removedBytesKnown: true)
        XCTAssertEqual(text(.done(plan)), "Checked just now · 69 worktrees, 130 branches")
        XCTAssertEqual(
            Model.progressText(.ready(at: now), worktrees: 2, branches: 2, sessionScope: true, now: now),
            "Checked just now · this session left 2 worktrees, 2 branches"
        )
    }

    func testAgeText() {
        func age(_ seconds: TimeInterval) -> String { Model.ageText(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(age(59), "just now")
        XCTAssertEqual(age(20 * 60), "20 min ago")
        XCTAssertEqual(age(3600), "1 h ago")
        XCTAssertEqual(age(3 * 3600), "3 h ago")
        XCTAssertEqual(Model.lastCommitText(now.addingTimeInterval(-3600), now: now), "1 hour ago")
        XCTAssertEqual(Model.lastCommitText(now.addingTimeInterval(-3 * 3600), now: now), "3 hours ago")
        XCTAssertEqual(Model.lastCommitText(now.addingTimeInterval(-20 * 60), now: now), "20 min ago")
        XCTAssertEqual(Model.lastCommitText(now.addingTimeInterval(-9 * day), now: now), "9 days ago")
        XCTAssertEqual(age(day), "1 day ago")
        XCTAssertEqual(age(9 * day), "9 days ago")
        XCTAssertEqual(age(35 * day), "5 weeks ago")
        XCTAssertEqual(age(60 * day), "2 months ago")
        XCTAssertEqual(age(400 * day), "1 year ago")
    }
}
