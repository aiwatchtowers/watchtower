import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ReadinessCenterTests: XCTestCase {

    private var poolPaths: [String] = []

    override func tearDown() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    private func today(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? .distantPast
    }

    /// Waits (bounded) until `condition` holds for the center's readiness,
    /// re-checking on every change of it — no sleeping.
    private func waitUntil(
        _ center: ReadinessCenter,
        timeout: TimeInterval = 5,
        _ condition: @escaping ([ReadinessFeature: Readiness]) -> Bool
    ) async {
        let met = expectation(description: "readiness condition")
        func check() {
            if condition(center.readiness) {
                met.fulfill()
                return
            }
            withObservationTracking { _ = center.readiness } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [met], timeout: timeout)
    }

    private func insertDigest(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO digests (channel_id, period_from, period_to, type, summary)
                VALUES ('C1', 0, 1, 'channel', 'summary')
                """)
        }
    }

    func testFirstEvaluationAfterStart() async throws {
        let center = ReadinessCenter(environment: FakeReadinessEnvironment())
        XCTAssertTrue(center.readiness.isEmpty)
        center.start(pool: try makePool())
        defer { center.stop() }
        await waitUntil(center) { !$0.isEmpty }
        XCTAssertEqual(Set(center.readiness.keys), Set(ReadinessFeature.allCases))
    }

    func testInsertingContentFlipsToReady() async throws {
        let pool = try makePool()
        let center = ReadinessCenter(environment: FakeReadinessEnvironment())
        center.start(pool: pool)
        defer { center.stop() }
        await waitUntil(center) { !$0.isEmpty }
        XCTAssertNotEqual(center.readiness(for: .digests), .ready)

        try insertDigest(pool)
        await waitUntil(center) { $0[.digests] == .ready }
    }

    func testObservationStartsWithMissingTable() async throws {
        let pool = try makePool()
        try await pool.write { db in try db.execute(sql: "DROP TABLE stream_digests") }
        let center = ReadinessCenter(environment: FakeReadinessEnvironment())
        center.start(pool: pool)
        defer { center.stop() }
        await waitUntil(center) { !$0.isEmpty }
        XCTAssertEqual(center.readiness.count, ReadinessFeature.allCases.count)

        try insertDigest(pool)
        await waitUntil(center) { $0[.digests] == .ready }
    }

    func testTickReevaluatesWithNewNow() async throws {
        let environment = FakeReadinessEnvironment()
        environment.now = today(6)
        environment.briefingHour = 8
        environment.stamps["last_briefing.txt"] = Calendar.current.date(byAdding: .day, value: -1, to: today(8))
        let center = ReadinessCenter(environment: environment)
        center.start(pool: try makePool())
        defer { center.stop() }
        await waitUntil(center) { !$0.isEmpty }
        XCTAssertEqual(center.readiness(for: .briefing), .scheduled(.at(hour: 8, tomorrow: false)))

        environment.now = today(9)
        center.refresh()
        XCTAssertEqual(center.readiness(for: .briefing), .scheduled(.nextCycle(minutes: 15)))
    }

    /// Hermetic: the workspace directory and config.yaml are temp files.
    func testGarbageStampReadsNil() throws {
        let dir = NSTemporaryDirectory() + "watchtower_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "abc".write(toFile: dir + "/last_people.txt", atomically: true, encoding: .utf8)
        try "1700000000\n".write(toFile: dir + "/last_ideas.txt", atomically: true, encoding: .utf8)
        let configPath = dir + "/config.yaml"
        try "briefing:\n  hour: 7\nsync:\n  poll_interval: 30m\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        let environment = LiveReadinessEnvironment(
            daemon: DaemonManager(), visibility: FeatureVisibilityStore(), configPath: configPath
        ) { dir }
        XCTAssertNil(environment.stamp("last_people.txt"))
        XCTAssertNil(environment.stamp("last_briefing.txt"))
        XCTAssertEqual(environment.stamp("last_ideas.txt"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(environment.briefingHour, 7)
        XCTAssertEqual(environment.pollInterval, "30m")

        let noWorkspace = LiveReadinessEnvironment(
            daemon: DaemonManager(), visibility: FeatureVisibilityStore(), configPath: configPath
        ) { nil }
        XCTAssertNil(noWorkspace.stamp("last_ideas.txt"))
        // The names read are the daemon's stamp files (Reset LLM data clears the same list).
        XCTAssertTrue(Set(ReadinessCenter.stampFiles).isSubset(of: DaemonStampFiles.names))
    }

    func testStopCancelsObservationAndTick() async throws {
        let pool = try makePool()
        let center = ReadinessCenter(environment: FakeReadinessEnvironment())
        center.start(pool: pool)
        await waitUntil(center) { !$0.isEmpty }
        center.stop()
        let before = center.readiness

        let changed = expectation(description: "no readiness change after stop")
        changed.isInverted = true
        withObservationTracking { _ = center.readiness } onChange: { changed.fulfill() }
        try insertDigest(pool)
        center.refresh()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(center.readiness, before)
    }

    func testStateSurvivesNavigation() async throws {
        let appState = AppState.isolated()
        XCTAssertTrue(appState.readinessEnvironmentOverride is FakeReadinessEnvironment, "no live config/stamps in tests")
        appState.readinessCenter.start(pool: try makePool())
        defer { appState.readinessCenter.stop() }
        appState.selectedDestination = .digests
        appState.selectedDestination = .people
        await waitUntil(appState.readinessCenter) { !$0.isEmpty }
        XCTAssertEqual(appState.readinessCenter.readiness.count, ReadinessFeature.allCases.count)
    }
}
