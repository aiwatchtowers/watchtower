import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

final class DatabaseManagerTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - wipeLLMData

    // MARK: - init(path:) busy wait

    /// The real `init(path:)` waits for another process's write lock: the
    /// 5 s wait now comes only from `DBLockInstrumentation.install` (the
    /// `PRAGMA busy_timeout = 5000` it replaced is gone), so without it this
    /// write would fail at once with SQLITE_BUSY.
    func testInitPathWriterWaitsForAnotherConnectionsWriteLock() throws {
        let (seedPool, path) = try TestDatabase.createPool()
        try seedPool.close()
        defer { TestDatabase.cleanup(path: path) }
        let manager = try DatabaseManager(path: path)

        var holderConfig = Configuration()
        holderConfig.allowsUnsafeTransactions = true
        let holder = try DatabaseQueue(path: path, configuration: holderConfig)
        try holder.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? holder.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        }

        let start = Date()
        try manager.dbPool.write { try $0.execute(sql: "INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "the write waited for the holder")

        // The wait is above the default 200 ms threshold: the tx line lands
        // next to the DB unless the environment overrides the threshold.
        guard ProcessInfo.processInfo.environment["WATCHTOWER_DBLOCK_THRESHOLD_MS"] == nil else { return }
        let sink = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("dblock.jsonl")
        // The sink writes asynchronously and creates the file before the
        // line lands, so wait for the line itself, not the file.
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        repeat {
            text = (try? String(contentsOfFile: sink, encoding: .utf8)) ?? ""
            if text.contains("\"site\":\"desktop:channels\"") { break }
            usleep(10_000)
        } while Date() < deadline
        XCTAssertTrue(text.contains("\"kind\":\"tx\""), text)
        XCTAssertTrue(text.contains("\"site\":\"desktop:channels\""), text)
    }
}
