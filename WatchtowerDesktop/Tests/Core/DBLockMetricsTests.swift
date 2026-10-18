import XCTest
import GRDB
@testable import WatchtowerCore

final class DBLockMetricsTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String { dir.appendingPathComponent("watchtower.db").path }
    private var sinkPath: String { dir.appendingPathComponent(DBLockSink.fileName).path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dblock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func makeSink(thresholdMS: Int64 = 200, maxFileBytes: Int64 = DBLockSink.maxFileBytes) throws -> DBLockSink {
        try XCTUnwrap(DBLockSink(
            dbPath: dbPath, settings: DBLockSettings(thresholdMS: thresholdMS), maxFileBytes: maxFileBytes))
    }

    /// An instrumented pool over a DB holding table `t`, handed back with an
    /// empty sink. Opening a pool on a fresh file runs GRDB's own WAL
    /// bootstrap on the writer (BEGIN IMMEDIATE, CREATE and DROP TABLE
    /// grdb_issue_102, COMMIT): a write transaction with no recognised table,
    /// which a loaded runner can stretch past a test's threshold into a
    /// `desktop:?` line. That is setup, not what a test measures.
    private func makePool(sink: DBLockSink?, busyTimeoutMS: Int = DBLockInstrumentation.busyTimeoutMS) throws -> DatabasePool {
        var config = Configuration()
        DBLockInstrumentation.install(on: &config, sink: sink, busyTimeoutMS: busyTimeoutMS)
        let pool = try DatabasePool(path: dbPath, configuration: config)
        try pool.writeWithoutTransaction { try $0.execute(sql: "CREATE TABLE IF NOT EXISTS t (v INTEGER)") }
        if let sink {
            sink.flush()
            // The sink re-opens a deleted file on its next line.
            if FileManager.default.fileExists(atPath: sink.path) {
                try FileManager.default.removeItem(atPath: sink.path)
            }
        }
        return pool
    }

    /// A second, uninstrumented connection that takes the write lock and
    /// keeps it until `release`.
    private func holdWriteLock() throws -> DatabaseQueue {
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let holder = try DatabaseQueue(path: dbPath, configuration: config)
        try holder.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        return holder
    }

    private func release(_ holder: DatabaseQueue) throws {
        try holder.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
    }

    private func lines(_ path: String? = nil) throws -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path ?? sinkPath, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    // MARK: - Settings

    func testSettingsParseMatchesGo() {
        XCTAssertEqual(DBLockSettings.parse(nil), DBLockSettings(thresholdMS: 200))
        XCTAssertEqual(DBLockSettings.parse(""), DBLockSettings(thresholdMS: 200))
        XCTAssertEqual(DBLockSettings.parse(" 0 "), DBLockSettings(thresholdMS: 0))
        XCTAssertEqual(DBLockSettings.parse("750"), DBLockSettings(thresholdMS: 750))
        XCTAssertEqual(DBLockSettings.parse("500\n"), DBLockSettings(thresholdMS: 500), "trimmed like strings.TrimSpace")
        XCTAssertTrue(DBLockSettings.parse("off").off)
        XCTAssertTrue(DBLockSettings.parse("OFF").off)
        XCTAssertEqual(DBLockSettings.parse("-5"), DBLockSettings(thresholdMS: 200))
        XCTAssertEqual(DBLockSettings.parse("fast"), DBLockSettings(thresholdMS: 200))
    }

    func testNoSinkWhenOffOrInMemory() {
        XCTAssertNil(DBLockSink(dbPath: dbPath, settings: DBLockSettings(off: true)))
        XCTAssertNil(DBLockSink(dbPath: ":memory:", settings: DBLockSettings()))
        XCTAssertNil(DBLockSink(dbPath: "", settings: DBLockSettings()))
    }

    // MARK: - Sink format and protocol

    func testLineCarriesTheSharedKeysAndOmitsZeros() throws {
        let sink = try makeSink()
        XCTAssertEqual(sink.path, sinkPath)
        sink.record(DBLockEvent(ts: Date(timeIntervalSince1970: 1_760_522_400), kind: DBLockEvent.kindTx,
                                waitMS: 3, holdMS: 1840, site: "desktop:t/x"))
        sink.flush()
        let raw = try String(contentsOfFile: sinkPath, encoding: .utf8)
        XCTAssertTrue(raw.hasSuffix("}\n"))
        XCTAssertEqual(raw.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(raw.contains("\"site\":\"desktop:t/x\""), "slashes stay unescaped: \(raw)")
        let obj = try XCTUnwrap(lines().first)
        XCTAssertEqual(obj["ts"] as? String, "2025-10-15T10:00:00.000Z")
        XCTAssertEqual(obj["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(obj["proc"] as? String, "desktop")
        XCTAssertEqual(obj["kind"] as? String, "tx")
        XCTAssertEqual(obj["wait_ms"] as? Int, 3)
        XCTAssertEqual(obj["hold_ms"] as? Int, 1840)
        XCTAssertEqual(Set(obj.keys), ["ts", "pid", "proc", "kind", "wait_ms", "hold_ms", "site"])
        let attrs = try FileManager.default.attributesOfItem(atPath: sinkPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTimestampAlwaysHasThreeFractionalDigits() throws {
        let sink = try makeSink()
        sink.record(DBLockEvent(ts: Date(timeIntervalSince1970: 1_760_522_400.5), kind: DBLockEvent.kindBusy))
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy))
        sink.flush()
        let stamps = try lines().compactMap { $0["ts"] as? String }
        XCTAssertEqual(stamps.first, "2025-10-15T10:00:00.500Z")
        XCTAssertEqual(stamps.count, 2)
        for ts in stamps {
            XCTAssertNotNil(ts.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression), ts)
        }
    }

    /// Truncated like Go's time.Format, never rounded up.
    func testTimestampTruncatesSubMilliseconds() throws {
        let sink = try makeSink()
        XCTAssertEqual(sink.timestamp(Date(timeIntervalSince1970: 1_760_522_400.9996)), "2025-10-15T10:00:00.999Z")
        XCTAssertEqual(sink.timestamp(Date(timeIntervalSince1970: 1_760_522_459.0004)), "2025-10-15T10:00:59.000Z")
        XCTAssertEqual(sink.timestamp(Date(timeIntervalSince1970: 1_760_522_400.123)), "2025-10-15T10:00:00.123Z")
    }

    func testRotatesOverTheCapToOneGeneration() throws {
        let sink = try makeSink(maxFileBytes: 10)
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "first"))
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "second"))
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "third"))
        sink.flush()
        XCTAssertEqual(try lines().map { $0["site"] as? String }, ["third"])
        XCTAssertEqual(try lines(sinkPath + ".1").map { $0["site"] as? String }, ["second"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(DBLockSink.lockFileName).path))
    }

    func testSkipsRotationWhileAnotherWriterHoldsTheLock() throws {
        let lockPath = dir.appendingPathComponent(DBLockSink.lockFileName).path
        let lockFD = open(lockPath, O_RDWR | O_CREAT, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        defer { close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)

        let sink = try makeSink(maxFileBytes: 10)
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "first"))
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "second"))
        sink.flush()
        XCTAssertEqual(try lines().map { $0["site"] as? String }, ["first", "second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sinkPath + ".1"))
    }

    func testReopensAfterAnotherProcessRotatedTheFile() throws {
        let sink = try makeSink()
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "before"))
        sink.flush()
        XCTAssertEqual(rename(sinkPath, sinkPath + ".1"), 0)
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "after"))
        sink.flush()
        XCTAssertEqual(try lines().map { $0["site"] as? String }, ["after"])
        XCTAssertEqual(try lines(sinkPath + ".1").map { $0["site"] as? String }, ["before"])
    }

    // MARK: - Busy wait

    /// The callback sleeps on sqliteDefaultBusyCallback's schedule and gives
    /// up once exactly the timeout has been slept.
    func testBusyScheduleMatchesSQLiteDefaultHandler() {
        var delays: [Int] = []
        var tries = 0
        while let delay = SQLiteBusyWait.delayMS(tries: tries, timeoutMS: 5000) {
            delays.append(delay)
            tries += 1
        }
        XCTAssertEqual(Array(delays.prefix(13)), [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100, 100])
        XCTAssertEqual(delays.reduce(0, +), 5000)
        XCTAssertEqual(delays.last, 72)
        XCTAssertEqual(tries, 59)

        XCTAssertEqual(SQLiteBusyWait.delayMS(tries: 0, timeoutMS: 2), 1)
        XCTAssertEqual(SQLiteBusyWait.delayMS(tries: 1, timeoutMS: 2), 1)
        XCTAssertNil(SQLiteBusyWait.delayMS(tries: 2, timeoutMS: 2))
    }

    func testHeldWriterFromAnotherPoolProducesBusyEvent() throws {
        let sink = try makeSink()
        let pool = try makePool(sink: sink, busyTimeoutMS: 300)
        let holder = try holdWriteLock()
        defer { try? release(holder) }

        let start = Date()
        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_BUSY)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        sink.flush()
        let busy = try lines().filter { $0["kind"] as? String == "busy" }
        XCTAssertEqual(busy.count, 1)
        let event = try XCTUnwrap(busy.first)
        XCTAssertEqual(event["err"] as? String, "SQLITE_BUSY")
        XCTAssertEqual(event["busy_timeout_ms"] as? Int, 300)
        XCTAssertEqual(event["site"] as? String, "desktop:?")
        XCTAssertGreaterThanOrEqual(event["wait_ms"] as? Int ?? 0, 290)
        XCTAssertEqual(event["proc"] as? String, "desktop")
    }

    /// Same waiting behaviour as the `PRAGMA busy_timeout = 5000` it replaces.
    func testBusyWaitGivesUpAfterFiveSeconds() throws {
        let sink = try makeSink()
        let pool = try makePool(sink: sink)
        let holder = try holdWriteLock()
        defer { try? release(holder) }

        let start = Date()
        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_BUSY)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 5.0)
        // Only a "did not wait forever" bound: a loaded CI runner has taken
        // ~9 s here, so the 5 s budget itself is pinned by the event below.
        XCTAssertLessThan(elapsed, 20.0)
        sink.flush()
        let busy = try lines().filter { $0["kind"] as? String == "busy" }
        XCTAssertEqual(busy.count, 1)
        let event = try XCTUnwrap(busy.first)
        XCTAssertEqual(event["busy_timeout_ms"] as? Int, 5000)
        XCTAssertGreaterThanOrEqual(event["wait_ms"] as? Int ?? 0, 5000)
    }

    func testNilSinkRecordsNothing() throws {
        let pool = try makePool(sink: nil, busyTimeoutMS: 100)
        let holder = try holdWriteLock()
        defer { try? release(holder) }

        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: sinkPath), "a nil sink records nothing")
    }

    func testWaitThatSucceedsShowsUpAsTxWait() throws {
        let sink = try makeSink(thresholdMS: 100)
        let pool = try makePool(sink: sink)
        let holder = try holdWriteLock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? self.release(holder) }

        try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }
        sink.flush()
        let event = try XCTUnwrap(lines().first)
        XCTAssertEqual(event["kind"] as? String, "tx")
        XCTAssertGreaterThanOrEqual(event["wait_ms"] as? Int ?? 0, 200)
        XCTAssertEqual(event["site"] as? String, "desktop:t")
        XCTAssertTrue(try lines().allSatisfy { $0["kind"] as? String != "busy" })
    }

    // MARK: - Transaction trace

    func testSlowWriteAboveThresholdProducesTxEvent() throws {
        let sink = try makeSink(thresholdMS: 50)
        let pool = try makePool(sink: sink)
        try pool.write { db in
            try db.execute(sql: "SELECT count(*) FROM t")
            try db.execute(sql: "INSERT INTO t VALUES (1)")
            try db.execute(sql: "UPDATE t SET v = 2")
            Thread.sleep(forTimeInterval: 0.08)
        }
        sink.flush()
        let events = try lines()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["kind"] as? String, "tx")
        XCTAssertGreaterThanOrEqual(event["hold_ms"] as? Int ?? 0, 80)
        XCTAssertEqual(event["site"] as? String, "desktop:t")
    }

    func testFastWriteBelowThresholdRecordsNothing() throws {
        let sink = try makeSink(thresholdMS: 1000)
        let pool = try makePool(sink: sink)
        try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }
        sink.flush()
        XCTAssertEqual(try lines().count, 0)
    }

    func testSlowTransactionWithoutWritesHasUnknownSite() throws {
        let sink = try makeSink(thresholdMS: 50)
        let pool = try makePool(sink: sink)
        try pool.write { _ in Thread.sleep(forTimeInterval: 0.06) }
        sink.flush()
        XCTAssertEqual(try lines().map { $0["site"] as? String }, ["desktop:?"])
    }

    func testRolledBackTransactionIsMeasured() throws {
        let sink = try makeSink(thresholdMS: 50)
        let pool = try makePool(sink: sink)
        struct Boom: Error {}
        XCTAssertThrowsError(try pool.write { db in
            try db.execute(sql: "DELETE FROM t")
            Thread.sleep(forTimeInterval: 0.06)
            throw Boom()
        })
        sink.flush()
        XCTAssertEqual(try lines().map { $0["site"] as? String }, ["desktop:t"])
    }

    /// Only the writer is traced: with threshold 0 a write is logged, reads
    /// (BEGIN DEFERRED … COMMIT on reader connections) never are.
    func testReadersAreNotTracedAndKeepTheBusyTimeoutPragma() throws {
        let sink = try makeSink(thresholdMS: 0)
        let pool = try makePool(sink: sink)
        let timeout = try pool.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") }
        XCTAssertEqual(timeout, 5000)
        _ = try pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t") }
        sink.flush()
        XCTAssertEqual(try lines().count, 0)

        try pool.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }
        sink.flush()
        XCTAssertEqual(try lines().count, 1)
    }

    /// GRDB's ValueObservation starts run `isolated(readOnly: true)` on the
    /// writer: a deferred, read-only transaction that never takes the write
    /// lock. Even at threshold 0 it writes no line.
    func testDeferredReadOnlyTransactionOnTheWriterRecordsNothing() throws {
        let sink = try makeSink(thresholdMS: 0)
        let pool = try makePool(sink: sink)
        try pool.writeWithoutTransaction { db in
            try db.readOnly {
                try db.inSavepoint {
                    _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM t")
                    Thread.sleep(forTimeInterval: 0.05)
                    return .commit
                }
            }
        }
        sink.flush()
        XCTAssertEqual(try lines().count, 0)
    }

    /// A deferred transaction that writes holds the lock from its first
    /// write: the read and sleep before it count toward neither wait nor hold.
    func testDeferredTransactionThatWritesIsMeasuredFromItsFirstWrite() throws {
        let sink = try makeSink(thresholdMS: 50)
        let pool = try makePool(sink: sink)
        try pool.writeWithoutTransaction { db in
            try db.inTransaction(.deferred) {
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM t")
                Thread.sleep(forTimeInterval: 0.5)
                try db.execute(sql: "INSERT INTO t VALUES (1)")
                Thread.sleep(forTimeInterval: 0.06)
                return .commit
            }
        }
        sink.flush()
        let events = try lines()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["kind"] as? String, "tx")
        XCTAssertEqual(event["site"] as? String, "desktop:t")
        let hold = event["hold_ms"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(hold, 60)
        // Measured from BEGIN either would be >= 500 ms (the pre-write
        // sleep); 400 leaves a loaded runner room without losing that.
        XCTAssertLessThan(hold, 400, "the hold starts at the first write, not at BEGIN")
        XCTAssertLessThan(event["wait_ms"] as? Int ?? 0, 400)
    }

    /// A deferred transaction whose first write waits for another writer:
    /// that wait is `wait_ms` only, never also part of `hold_ms`.
    func testContendedDeferredFirstWriteWaitIsNotCountedAsHold() throws {
        let sink = try makeSink(thresholdMS: 50)
        let pool = try makePool(sink: sink)
        let holder = try holdWriteLock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? self.release(holder) }
        try pool.writeWithoutTransaction { db in
            try db.inTransaction(.deferred) {
                try db.execute(sql: "INSERT INTO t VALUES (1)")
                Thread.sleep(forTimeInterval: 0.06)
                return .commit
            }
        }
        sink.flush()
        let event = try XCTUnwrap(lines().first { $0["kind"] as? String == "tx" })
        XCTAssertGreaterThanOrEqual(event["wait_ms"] as? Int ?? 0, 550, "the first write waited for the holder")
        let hold = event["hold_ms"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(hold, 60)
        // Counting the wait again would make the hold >= 610 ms; 500 leaves
        // a loaded runner room without losing that.
        XCTAssertLessThan(hold, 500, "the first write's wait is not counted again as hold")
    }

    /// The sink's names and cap are a Go↔Swift dual path; the Go suite
    /// (TestSinkNamesAndCapAreTheSharedLiterals) asserts the same literals,
    /// so a rename on one side fails a suite.
    func testSinkNamesAndCapAreTheSharedLiterals() throws {
        XCTAssertEqual(DBLockSink.fileName, "dblock.jsonl")
        XCTAssertEqual(DBLockSink.lockFileName, "dblock.jsonl.lock")
        XCTAssertEqual(DBLockSink.maxFileBytes, 10_485_760)
        let sink = try makeSink(maxFileBytes: 10)
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "first"))
        sink.record(DBLockEvent(kind: DBLockEvent.kindBusy, site: "second"))
        sink.flush()
        for name in ["dblock.jsonl", "dblock.jsonl.1", "dblock.jsonl.lock"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
    }

    func testTrackerParsing() {
        XCTAssertEqual(WriteTransactionTracker.writtenTable("INSERT INTO targets (a) VALUES (?)"), "targets")
        XCTAssertEqual(WriteTransactionTracker.writtenTable("INSERT OR REPLACE INTO \"chat_messages\"(a) VALUES (?)"), "chat_messages")
        XCTAssertEqual(WriteTransactionTracker.writtenTable("REPLACE INTO `x` VALUES (1)"), "x")
        XCTAssertEqual(WriteTransactionTracker.writtenTable("update OR IGNORE inbox_items SET a = 1"), "inbox_items")
        XCTAssertEqual(WriteTransactionTracker.writtenTable("UPDATE [y] SET a = 1"), "y")
        XCTAssertEqual(WriteTransactionTracker.writtenTable("DELETE FROM digests"), "digests")
        XCTAssertNil(WriteTransactionTracker.writtenTable("SELECT * FROM t"))
        XCTAssertNil(WriteTransactionTracker.writtenTable(""))

        XCTAssertEqual(WriteTransactionTracker.boundary("BEGIN IMMEDIATE TRANSACTION"), .begin(locking: true))
        XCTAssertEqual(WriteTransactionTracker.boundary("begin exclusive"), .begin(locking: true))
        XCTAssertEqual(WriteTransactionTracker.boundary("BEGIN DEFERRED TRANSACTION"), .begin(locking: false))
        XCTAssertEqual(WriteTransactionTracker.boundary("BEGIN"), .begin(locking: false))
        XCTAssertEqual(WriteTransactionTracker.boundary("BEGIN TRANSACTION"), .begin(locking: false))
        XCTAssertEqual(WriteTransactionTracker.boundary("END"), .end)
        XCTAssertEqual(WriteTransactionTracker.boundary("COMMIT TRANSACTION"), .end)
        XCTAssertEqual(WriteTransactionTracker.boundary("ROLLBACK TRANSACTION"), .end)
        XCTAssertNil(WriteTransactionTracker.boundary("ROLLBACK TRANSACTION TO SAVEPOINT grdb"))
        XCTAssertNil(WriteTransactionTracker.boundary("ROLLBACK\tTO\nSAVEPOINT grdb"))
        XCTAssertNil(WriteTransactionTracker.boundary("RELEASE SAVEPOINT grdb"))
        XCTAssertNil(WriteTransactionTracker.boundary("SELECT 1"))
    }
}
