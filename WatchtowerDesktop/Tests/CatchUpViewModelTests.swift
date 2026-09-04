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
        XCTAssertEqual(args[1], iso.string(from: from), "RFC 3339, the form `catchup run --from` parses")
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
