import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The queued embedded-chat draft lives in `chat_queued_drafts` (#604 S15),
/// and still comes back after a relaunch (CHAT-01).
@MainActor
final class EmbeddedDraftMirrorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var pool: DatabasePool!
    private var path = ""
    private let first = EmbeddedChatKey(contextType: "track", contextID: "1", conversationID: 10)
    private let second = EmbeddedChatKey(contextType: "track", contextID: "1", conversationID: 11)

    override func setUp() async throws {
        suite = "embedded-draft-mirror-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func mirror() -> DatabaseDraftMirror {
        DatabaseDraftMirror(defaults: defaults)
    }

    /// The writes are async in call order; a sync write waits behind them.
    private func settled() throws {
        try pool.write { _ in }
    }

    private func row(_ key: EmbeddedChatKey) throws -> String? {
        try pool.read { try QueuedDraftQueries.text($0, key: key.description) }
    }

    func testQueuedDraftSurvivesRelaunch() throws {
        let mirror = mirror()
        mirror.writer = pool
        mirror.save("queued words", for: first)
        XCTAssertEqual(mirror.restore(for: first), "queued words")
        XCTAssertNil(mirror.restore(for: second))
        try settled()

        let relaunched = self.mirror()
        relaunched.writer = pool
        XCTAssertEqual(relaunched.restore(for: first), "queued words", "a new process reads the row")
        XCTAssertNil(defaults.string(forKey: DatabaseDraftMirror.legacyPrefix + first.description),
                     "nothing goes to UserDefaults")
    }

    func testQueuedBeforePoolIsFlushed() throws {
        let mirror = mirror()
        mirror.save("early", for: first)
        XCTAssertEqual(mirror.restore(for: first), "early", "kept in memory before the database opens")
        mirror.writer = pool
        try settled()
        XCTAssertEqual(try row(first), "early")
    }

    func testLegacyDefaultsImportedAndRemoved() throws {
        let legacyFirst = DatabaseDraftMirror.legacyPrefix + first.description
        let legacySecond = DatabaseDraftMirror.legacyPrefix + second.description
        defaults.set("from defaults", forKey: legacyFirst)
        defaults.set("superseded", forKey: legacySecond)
        let mirror = mirror()
        mirror.clear(for: second) // this process's clear wins over the legacy text
        mirror.writer = pool
        try settled()
        XCTAssertEqual(try row(first), "from defaults")
        XCTAssertNil(try row(second))
        XCTAssertEqual(mirror.restore(for: first), "from defaults")
        // The keys go in the write's completion, which runs on the writer
        // queue before the barrier write in `settled()`.
        XCTAssertNil(defaults.string(forKey: legacyFirst))
        XCTAssertNil(defaults.string(forKey: legacySecond))
    }

    func testClearRemovesRow() throws {
        let mirror = mirror()
        mirror.writer = pool
        mirror.save("queued", for: first)
        mirror.clear(for: first)
        try settled()
        XCTAssertNil(try row(first))
        XCTAssertNil(mirror.restore(for: first))
    }
}
