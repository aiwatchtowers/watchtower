import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Stop syncing in Statistics → Channels (adaptive Slack sync, #1709): the
/// suggestion rule shared with Go, the CLI-only writes and the Not synced
/// filter.
extension ChannelStatsTests {
    /// The suggestion rule follows Go's case for case
    /// (`internal/db/testdata/channel_recommendation_cases.json`, read by Go's
    /// `TestComputeRecommendations_ExcludeCases`).
    func testExcludeRecommendationMatchesGo() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/channel_recommendation_cases.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let now = Date(timeIntervalSince1970: try XCTUnwrap(fixture["now"] as? Double))
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let stats = try XCTUnwrap(item["stats"] as? [[String: Any]], name).map(Self.stat(from:))
            var signals: [String: ChannelValueSignals] = [:]
            for (id, value) in try XCTUnwrap(item["signals"] as? [String: [String: Any]], name) {
                var json = ["channel_id": id, "decision_count": 0, "active_track_count": 0,
                            "task_count": 0, "pending_inbox_count": 0] as [String: Any]
                json.merge(value) { _, new in new }
                signals[id] = try JSONDecoder().decode(ChannelValueSignals.self,
                                                       from: JSONSerialization.data(withJSONObject: json))
            }
            let want = try XCTUnwrap(item["want"] as? [[String: String]], name)
            let got = ChannelStatsQueries.computeRecommendations(from: stats, signals: signals, now: now)
                .map { ["channel_id": $0.channelID, "action": $0.action.rawValue, "reason": $0.reason] }
            XCTAssertEqual(got, want, name)
        }
    }

    func testFetchAllReadsStopSyncingInputs() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "alerts")
            try TestDatabase.insertChannel(db, id: "C002", name: "random")
            try TestDatabase.insertMessage(db, channelID: "C001", ts: "1700000010.000000", userID: "U002", text: "hey <@U001>")
            try TestDatabase.insertMessage(db, channelID: "C001", ts: "1700000020.000000", userID: "U002", text: "plain")
            try db.execute(sql: """
                INSERT INTO channel_settings (channel_id, is_muted_for_llm, muted_at, sync_excluded)
                VALUES ('C001', 1, '2026-11-01T09:00:00Z', 1)
                """)
            try db.execute(sql: "INSERT INTO channel_settings (channel_id, catchup_from, catchup_to) VALUES ('C002', 1600000000, 1600000500)")
        }
        let stats = try db.read { try ChannelStatsQueries.fetchAll($0, currentUserID: "U001") }
        let byID = Dictionary(uniqueKeysWithValues: stats.map { ($0.id, $0) })
        let alerts = try XCTUnwrap(byID["C001"])
        XCTAssertTrue(alerts.isSyncExcluded)
        XCTAssertEqual(alerts.mutedAt, 1_793_523_600) // 2026-11-01T09:00:00Z
        XCTAssertEqual(alerts.lastMention, 1_700_000_010)
        XCTAssertNil(alerts.catchupFrom)
        XCTAssertEqual(alerts.syncState, .notSynced)
        let random = try XCTUnwrap(byID["C002"])
        XCTAssertFalse(random.isSyncExcluded)
        XCTAssertEqual(random.mutedAt, 0)
        XCTAssertEqual(random.syncState, .catchingUp(since: Date(timeIntervalSince1970: 1_600_000_000)))
    }

    /// Stop syncing and Sync again run the CLI (the only writer of the
    /// exclusion columns), never a Swift write.
    @MainActor
    func testStopSyncingCallsCLI() async throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await dbManager.dbPool.write { try TestDatabase.insertChannel($0, id: "C0JUNK", name: "alerts") }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"channel_id":"C0JUNK","sync_excluded":true,"muted":true}"#.utf8))
        let vm = ChannelStatsViewModel(dbManager: dbManager, cliRunner: runner)
        vm.stats = try [Self.stat(from: ["id": "C0JUNK", "name": "alerts"])]

        await vm.toggleSyncExcluded(channelID: "C0JUNK")
        vm.stats = try [Self.stat(from: ["id": "C0JUNK", "name": "alerts", "is_sync_excluded": true])]
        await vm.toggleSyncExcluded(channelID: "C0JUNK")
        await vm.applyRecommendation(ChannelRecommendation(
            channelID: "C0JUNK", channelName: "alerts", action: .exclude, reason: ChannelStatsPresentation.reasonMuted
        ))

        XCTAssertEqual(runner.invocations, [
            ["channels", "exclude", "--id", "C0JUNK", "--json"],
            ["channels", "include", "--id", "C0JUNK", "--json"],
            ["channels", "exclude", "--id", "C0JUNK", "--json"]
        ])
        XCTAssertNil(vm.errorMessage)
        let settings = try await dbManager.dbPool.read { try ChannelSettings.fetchOne($0, key: "C0JUNK") }
        XCTAssertNil(settings, "the Desktop wrote channel_settings itself")
    }

    /// A failed CLI call says why and leaves the row as it was: no
    /// optimistic flip.
    @MainActor
    func testCLIFailureShowsErrorAndKeepsRow() async throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: #"no channel with id "C0JUNK""#))
        let vm = ChannelStatsViewModel(dbManager: dbManager, cliRunner: runner)
        vm.stats = try [Self.stat(from: ["id": "C0JUNK", "name": "alerts", "total_messages": 12])]

        await vm.toggleSyncExcluded(channelID: "C0JUNK")

        XCTAssertEqual(runner.invocations.count, 1)
        let message = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(message.hasPrefix("Stop syncing failed: "), message)
        XCTAssertTrue(message.contains("no channel with id"), message)
        XCTAssertEqual(vm.stats.map(\.id), ["C0JUNK"])
        XCTAssertFalse(try XCTUnwrap(vm.stats.first).isSyncExcluded)
        XCTAssertFalse(vm.isSyncPending("C0JUNK"))
    }

    /// Without a CLI the button fails the same way, never writing itself.
    @MainActor
    func testStopSyncingWithoutCLIShowsError() async throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = ChannelStatsViewModel(dbManager: dbManager, cliRunner: nil)
        vm.stats = try [Self.stat(from: ["id": "C0JUNK", "name": "alerts", "is_sync_excluded": true])]

        await vm.toggleSyncExcluded(channelID: "C0JUNK")

        XCTAssertTrue(try XCTUnwrap(vm.errorMessage).hasPrefix("Sync again failed: "))
        XCTAssertTrue(try XCTUnwrap(vm.stats.first).isSyncExcluded)
    }

    @MainActor
    func testNotSyncedFilter() throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = ChannelStatsViewModel(dbManager: dbManager, cliRunner: nil)
        vm.stats = try [
            Self.stat(from: ["id": "C1", "name": "team-core", "total_messages": 412]),
            Self.stat(from: ["id": "C2", "name": "alerts-prod", "total_messages": 2904, "is_sync_excluded": true]),
            Self.stat(from: ["id": "C3", "name": "random", "total_messages": 655, "catchup_from": 1_800_000_000])
        ]
        XCTAssertEqual(ChannelStatsViewModel.Filter.notSynced.rawValue, ChannelStatsPresentation.filterNotSynced)
        XCTAssertEqual(ChannelStatsViewModel.Filter.allCases.map(\.rawValue),
                       ["All", "Muted", "Favorites", "Recommendations", "Not synced"])

        vm.filter = .notSynced
        XCTAssertEqual(vm.filteredStats.map(\.id), ["C2"])

        vm.stats = try [Self.stat(from: ["id": "C1", "name": "team-core", "total_messages": 412])]
        XCTAssertTrue(vm.filteredStats.isEmpty)
    }

    /// A `ChannelStat` from its JSON keys; unset keys are 0, false or empty.
    static func stat(from fields: [String: Any]) throws -> ChannelStat {
        var json: [String: Any] = [
            "id": "", "name": "", "type": "public", "is_archived": false, "is_member": true, "num_members": 0,
            "total_messages": 0, "user_messages": 0, "bot_messages": 0, "bot_ratio": 0.0, "mention_count": 0,
            "last_activity": 0.0, "last_user_activity": 0.0, "last_mention": 0.0, "is_muted_for_llm": false,
            "muted_at": 0.0, "is_favorite": false, "is_watched": false, "is_sync_excluded": false,
            "digest_count": 0, "messages_since_digest": 0
        ]
        json.merge(fields) { _, new in new }
        return try JSONDecoder().decode(ChannelStat.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
