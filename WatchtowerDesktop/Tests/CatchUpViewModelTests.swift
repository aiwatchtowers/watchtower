import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The absence-recap ViewModel. Deliberately CLI-free: `build`/`regenerate`/
/// `submitFeedback` shell out to `watchtower catchup …`, which would run a real
/// binary (and a real AI call) here, so only the DB-backed half — observation,
/// acknowledge, the auto-window caption — and the pure window→argv mapping are
/// exercised.
@MainActor
final class CatchUpViewModelTests: XCTestCase {

    // MARK: - Seeding helpers

    @discardableResult
    nonisolated private static func insertRecap(
        _ db: Database,
        from: Double,
        to: Double,
        status: String = "ready"
    ) throws -> Int {
        try db.execute(
            sql: "INSERT INTO catchup_recaps (period_from, period_to, status) VALUES (?, ?, ?)",
            arguments: [from, to, status]
        )
        return Int(db.lastInsertedRowID)
    }

    @discardableResult
    nonisolated private static func insertDigest(_ db: Database, periodTo: Double) throws -> Int {
        try TestDatabase.insertDigest(db, periodFrom: periodTo - 100, periodTo: periodTo)
        return Int(db.lastInsertedRowID)
    }

    /// Pumps the run loop so the VM's ValueObservation Task can deliver its first value.
    private func waitFor(
        _ predicate: @escaping () -> Bool, timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Window choice → CLI arguments

    func testWindowChoiceCLIArguments() {
        XCTAssertEqual(CatchUpWindowChoice.auto.cliArguments, [],
                       "auto passes no window flags — the CLI resolves it from the last ack")
        XCTAssertEqual(CatchUpWindowChoice.today.cliArguments, ["--preset", "today"])
        XCTAssertEqual(CatchUpWindowChoice.yesterday.cliArguments, ["--preset", "yesterday"])
        XCTAssertEqual(CatchUpWindowChoice.threeDays.cliArguments, ["--preset", "3d"])
        XCTAssertEqual(CatchUpWindowChoice.week.cliArguments, ["--preset", "week"])

        let from = Date(timeIntervalSince1970: 1_800_000_000)
        let to = Date(timeIntervalSince1970: 1_800_086_400)
        let args = CatchUpWindowChoice.custom(from: from, to: to).cliArguments
        XCTAssertEqual(args.count, 4)
        XCTAssertEqual(args[0], "--from")
        XCTAssertEqual(args[2], "--to")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(args[1], iso.string(from: from), "RFC 3339 in UTC, the form `catchup run --from` parses")
        XCTAssertEqual(args[3], iso.string(from: to))
    }

    // MARK: - Observation

    func testStartObservingPopulatesRecapsAndSelectsNewest() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let newest = try await pool.write { db -> Int in
            _ = try Self.insertRecap(db, from: 1000, to: 2000)
            return try Self.insertRecap(db, from: 2000, to: 3000)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.startObserving()

        await waitFor { vm.recaps.count == 2 }
        XCTAssertEqual(vm.recaps.count, 2)
        XCTAssertEqual(vm.selected?.id, newest, "the newest recap is selected by default")
    }

    // MARK: - CLI failure classification

    /// `catchup run` exits 0 for a recap that composed and FAILED, reporting it
    /// in the envelope instead — so exit code alone is not the verdict.
    func testFailureMessageParsesExitZeroFailedEnvelope() {
        let failed = CatchUpViewModel.failureMessage(
            (exitCode: 0, stdout: #"{"status":"failed","error":"boom"}"#, stderr: ""),
            label: "Catch-up failed"
        )
        XCTAssertEqual(failed, "boom", "a failed envelope surfaces its own error")

        let ready = CatchUpViewModel.failureMessage(
            (exitCode: 0, stdout: #"{"status":"ready"}"#, stderr: ""),
            label: "Catch-up failed"
        )
        XCTAssertNil(ready, "a ready envelope is a clean run")

        let crashed = CatchUpViewModel.failureMessage(
            (exitCode: 1, stdout: "", stderr: "invalid --from"),
            label: "Catch-up failed"
        )
        XCTAssertEqual(crashed, "invalid --from", "a Go-level error comes from stderr")

        let plainText = CatchUpViewModel.failureMessage(
            (exitCode: 0, stdout: "Recorded feedback on recap 3, topic 0.", stderr: ""),
            label: "Catch-up failed"
        )
        XCTAssertNil(plainText, "non-JSON stdout on a clean exit is not an error")

        // `catchup feedback` prints plain text, so its caller parses nothing —
        // a stdout that happens to look like a failed envelope is still ignored.
        let unparsed = CatchUpViewModel.failureMessage(
            (exitCode: 0, stdout: #"{"status":"failed","error":"boom"}"#, stderr: ""),
            label: "Feedback failed",
            parseEnvelope: false
        )
        XCTAssertNil(unparsed)
    }

    // MARK: - Selection across reload

    func testApplyKeepsSelectedRecapAcrossReload() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let older = try await pool.write { db -> Int in
            let older = try Self.insertRecap(db, from: 1000, to: 2000)
            _ = try Self.insertRecap(db, from: 2000, to: 3000)
            return older
        }

        let vm = CatchUpViewModel(dbPool: pool)
        await vm.reload()
        vm.selected = vm.recaps.first { $0.id == older }
        XCTAssertEqual(vm.selected?.isAcknowledged, false)

        // Another writer (the CLI, or the ack path) moves the selected row.
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE catchup_recaps SET acknowledged_at = ? WHERE id = ?",
                arguments: ["2026-09-04T10:00:00Z", older]
            )
        }
        await vm.reload()

        XCTAssertEqual(vm.selected?.id, older, "reload keeps the deliberate selection, not the newest")
        XCTAssertEqual(vm.selected?.isAcknowledged, true, "and re-points it at the refreshed row")
    }

    /// A build/regen arms a one-shot "select the newest row" so the pane follows
    /// the recap the run is producing instead of staying on the previous one.
    func testBuildSelectsTheNewestRecapOnNextApply() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let older = try await pool.write { db -> Int in
            let older = try Self.insertRecap(db, from: 1000, to: 2000)
            _ = try Self.insertRecap(db, from: 2000, to: 3000)
            return older
        }

        let vm = CatchUpViewModel(dbPool: pool)
        await vm.reload()
        vm.selected = vm.recaps.first { $0.id == older }
        XCTAssertEqual(vm.selected?.id, older)

        // `run` arms the flag and the CLI inserts its `building` row; the first
        // poll after that is what this reload stands in for.
        vm.markSelectNewestForTesting()
        let newest = try await pool.write { db in
            try Self.insertRecap(db, from: 3000, to: 4000, status: "building")
        }
        await vm.reload()
        XCTAssertEqual(vm.selected?.id, newest, "the run's own row is selected")

        // One-shot: an ordinary poll afterwards must not keep jumping.
        vm.selected = vm.recaps.first { $0.id == older }
        await vm.reload()
        XCTAssertEqual(vm.selected?.id, older, "the flag is consumed — later reloads keep the selection")
    }

    // MARK: - Acknowledge

    func testAcknowledgeMarksWindowAndFlipsSelected() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let digestID = try await pool.write { db -> Int in
            _ = try Self.insertRecap(db, from: 1000, to: 2000)
            return try Self.insertDigest(db, periodTo: 1500)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.startObserving()
        await waitFor { vm.selected != nil }

        await vm.acknowledge()

        let readAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM digests WHERE id = ?", arguments: [digestID])
        }
        XCTAssertFalse((readAt ?? "").isEmpty, "the in-window digest is marked read")
        XCTAssertEqual(vm.selected?.isAcknowledged, true, "the selected row is re-read after the write")
        XCTAssertNil(vm.error)
    }

    func testReloadRefreshesAutoWindowStart() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        try await pool.write { db in
            _ = try Self.insertRecap(db, from: 1000, to: 2000)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.startObserving()
        await waitFor { vm.selected != nil }
        XCTAssertNil(vm.autoWindowStart, "nothing acknowledged yet — the caption has no start")

        await vm.acknowledge()

        XCTAssertEqual(vm.autoWindowStart, Date(timeIntervalSince1970: 2000),
                       "the next auto window starts where the acknowledged one ended")
    }
}
