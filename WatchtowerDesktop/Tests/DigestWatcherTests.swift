import Foundation
import GRDB
import Testing
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@Suite("DigestWatcher")
@MainActor
struct DigestWatcherTests {
    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    /// Spies on `DigestWatcher.poll()`'s two notification calls without
    /// touching the real `UNUserNotificationCenter` — which requires a
    /// proper app bundle and crashes under `swift test`.
    private final class SpyNotifier: DigestWatcherNotifying {
        private(set) var decisionCalls: [(ideaID: Int, title: String)] = []
        private(set) var briefingCalls: [Int] = []

        func sendDecisionNotification(ideaID: Int, title: String) {
            decisionCalls.append((ideaID, title))
        }

        func sendBriefingNotification(attentionCount: Int) {
            briefingCalls.append(attentionCount)
        }
    }

    private func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: "lastCheckedDecisionID")
        UserDefaults.standard.removeObject(forKey: "lastCheckedBriefingID")
        UserDefaults.standard.removeObject(forKey: "notifyDecisions")
        UserDefaults.standard.removeObject(forKey: "quietHoursEnabled")
    }

    @Test("init seeds lastChecked from UserDefaults defaults")
    func initSeedsLastChecked() throws {
        let pool = try makePool()
        resetDefaults()

        let watcher = DigestWatcher(dbPool: pool)
        // Init alone doesn't trigger DB lookups; that happens on start().
        _ = watcher
    }

    @Test("start initializes lastCheckedDecisionID from max ledger decision id when first run")
    func startSeedsFromDB() throws {
        resetDefaults()

        let pool = try makePool()
        // Seed an existing ledger decision so max id is non-zero.
        try pool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Ship it")
        }

        let watcher = DigestWatcher(dbPool: pool)
        watcher.start()
        // Stop quickly to avoid the 60s polling loop racing in tests.
        watcher.stop()

        let stored = UserDefaults.standard.integer(forKey: "lastCheckedDecisionID")
        #expect(stored > 0, "lastCheckedDecisionID should be seeded from max ledger decision id, got \(stored)")
    }

    @Test("stop cancels watch task safely when called before start")
    func stopBeforeStart() throws {
        let pool = try makePool()
        let watcher = DigestWatcher(dbPool: pool)
        watcher.stop() // should not crash
    }

    @Test("stop is idempotent")
    func stopIdempotent() throws {
        let pool = try makePool()
        let watcher = DigestWatcher(dbPool: pool)
        watcher.start()
        watcher.stop()
        watcher.stop()
    }

    // MARK: - poll(): ledger decision notifications

    @Test("poll notifies once for a new ledger decision")
    func pollNotifiesNewLedgerDecision() throws {
        resetDefaults()
        let pool = try makePool()
        let ideaID = try pool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Adopt the new vendor")
        }

        let spy = SpyNotifier()
        let watcher = DigestWatcher(dbPool: pool, notificationService: spy)
        watcher.poll()

        #expect(spy.decisionCalls.count == 1)
        #expect(spy.decisionCalls.first?.ideaID == Int(ideaID))
        #expect(spy.decisionCalls.first?.title == "Adopt the new vendor")
        #expect(UserDefaults.standard.integer(forKey: "lastCheckedDecisionID") == Int(ideaID))
    }

    @Test("poll does not re-notify the same ledger decision on a second run")
    func pollDoesNotDuplicateNotification() throws {
        resetDefaults()
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertIdea(db, kind: "decision", title: "Adopt the new vendor")
        }

        let spy = SpyNotifier()
        let watcher = DigestWatcher(dbPool: pool, notificationService: spy)
        watcher.poll()
        watcher.poll()

        #expect(spy.decisionCalls.count == 1)
    }

    @Test("poll ignores a digest's decisions JSON when it has no ledger row")
    func pollIgnoresDigestDecisionsWithoutLedgerRow() throws {
        resetDefaults()
        let pool = try makePool()
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO digests (channel_id, period_from, period_to, type, summary, topics, decisions, action_items, message_count, model)
                VALUES ('C1', 100, 200, 'channel', 'x', '[]', '[{"text":"Ship it"}]', '[]', 1, 'm')
                """)
        }

        let spy = SpyNotifier()
        let watcher = DigestWatcher(dbPool: pool, notificationService: spy)
        watcher.poll()

        #expect(spy.decisionCalls.isEmpty)
    }
}
