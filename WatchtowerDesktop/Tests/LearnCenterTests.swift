import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
@Observable
final class FakeLearnEnvironment: LearnEnvironment {
    var now = Date(timeIntervalSince1970: 1_792_900_000)
    var disabledFeatures: Set<String>? = []
    var iphonePaired = false
    var dictationUsed = false
    var goals: Set<OnboardingGoal> = []
}

@MainActor
final class LearnCenterTests: XCTestCase {
    private var poolPaths: [String] = []
    private var centers: [LearnCenter] = []

    override func tearDown() {
        centers.forEach { $0.stop() }
        centers = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        super.tearDown()
    }

    static func card(
        _ id: String, _ area: LearnArea, doneWhen: LearnSignal? = nil, action: String = ""
    ) -> LearnCard {
        LearnCard(id: id, title: "Title \(id)", text: "Text \(id).", area: area, level: .basics, kind: .feature,
                  since: "0.24.0", action: action, doneWhen: doneWhen)
    }

    static let catalog = LearnCatalog(cards: [
        card("chat", .assistant, doneWhen: .chatUsed, action: "nav:chat"),
        card("inbox", .communication, action: "nav:inbox"),
        card("record", .meetings, doneWhen: .dictationUsed),
        card("phone", .iphone, doneWhen: .iphonePaired),
        card("memory", .assistant, doneWhen: .memoryOn)
    ])

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    private func start(
        _ pool: DatabasePool,
        environment: FakeLearnEnvironment? = nil,
        catalog: @escaping LearnCenter.CatalogLoader = { LearnCenterTests.catalog }
    ) -> LearnCenter {
        let center = LearnCenter(environment: environment ?? FakeLearnEnvironment(), loadCatalog: catalog)
        centers.append(center)
        center.start(pool: pool, newAfter: nil)
        return center
    }

    /// Waits until `condition` holds for the selection, re-checking on every
    /// change of it — no deadline.
    private func waitUntil(_ center: LearnCenter, _ condition: @escaping (LearnSelection?) -> Bool) async {
        await untilObserved { condition(center.selection) }
    }

    /// Waits until `count` seen-row writes landed.
    private func waitForWrites(_ center: LearnCenter, _ count: Int) async {
        await untilObserved { center.writes >= count }
    }

    private func seen(_ pool: DatabasePool) throws -> [String: LearnSeenHow] {
        try pool.read(LearnQueries.fetchSeen)
    }

    func testFirstReadSelectsUnseenCards() async throws {
        let pool = try makePool()
        let center = start(pool)
        await waitUntil(center) { $0 != nil }
        let selection = try XCTUnwrap(center.zone)
        XCTAssertEqual(selection.total, 5)
        XCTAssertEqual(Set(selection.home.map(\.id)).count, 3)
        // Memory is on (no feature disabled): recorded in_use, never shown.
        await waitUntil(center) { $0?.seenCount == 1 }
        await waitForWrites(center, 1)
        XCTAssertEqual(try seen(pool), ["memory": .inUse])
    }

    func testRowSignalRecordsInUse() async throws {
        let pool = try makePool()
        try await pool.write { db in
            let conversation = try TestDatabase.insertChatConversation(db)
            try TestDatabase.insertChatMessage(db, conversationID: conversation, role: "user", text: "hi")
        }
        let center = start(pool)
        await waitUntil(center) { $0?.seenCount == 2 }
        await waitForWrites(center, 1)
        XCTAssertEqual(try seen(pool)["chat"], .inUse)
        XCTAssertFalse(center.selection?.home.contains { $0.id == "chat" } ?? true)
    }

    /// Before `features list` loaded, the fail-open state never writes a row.
    func testUnknownFeaturesWriteNoMemoryRow() async throws {
        let pool = try makePool()
        let environment = FakeLearnEnvironment()
        environment.disabledFeatures = nil
        let center = start(pool, environment: environment)
        await waitUntil(center) { $0 != nil }
        await center.refresh()
        XCTAssertEqual(try seen(pool), [:])
        XCTAssertEqual(center.selection?.seenCount, 0)
    }

    /// An environment change (the phone paired) rebuilds without a DB change.
    func testEnvironmentChangeRecordsInUse() async throws {
        let pool = try makePool()
        let environment = FakeLearnEnvironment()
        environment.disabledFeatures = ["memory"]
        let center = start(pool, environment: environment)
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.selection?.seenCount, 0)
        environment.iphonePaired = true
        await waitUntil(center) { $0?.seenCount == 1 }
        await waitForWrites(center, 1)
        XCTAssertEqual(try seen(pool), ["phone": .inUse])
    }

    func testGotItActionAndShowAgain() async throws {
        let pool = try makePool()
        let environment = FakeLearnEnvironment()
        environment.disabledFeatures = ["memory"]
        let center = start(pool, environment: environment)
        await waitUntil(center) { $0 != nil }

        await center.gotIt("inbox")
        await center.recordAction("chat")
        XCTAssertEqual(try seen(pool), ["inbox": .gotIt, "chat": .action])
        XCTAssertEqual(center.selection?.seenCount, 2)
        XCTAssertFalse(center.selection?.home.contains { $0.id == "inbox" } ?? true)

        await center.showAgain("inbox")
        XCTAssertEqual(try seen(pool), ["chat": .action])
        XCTAssertTrue(center.selection?.home.contains { $0.id == "inbox" } ?? false)
    }

    /// A restart while the catalog loads waits for that load instead of
    /// cancelling it: the zone still shows, and the CLI ran once.
    func testRestartDuringLoadKeepsTheCatalog() async throws {
        let pool = try makePool()
        let calls = LoadCounter()
        // The load is held until after the restart.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let center = start(pool) {
            await calls.increment()
            for await _ in gate {}
            try Task.checkCancellation()
            return Self.catalog
        }
        center.start(pool: pool, newAfter: nil)
        open.finish()
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.zone?.total, 5)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    /// An in-use card offers no Show again, and the center ignores one.
    func testShowAgainIgnoredForInUseCard() async throws {
        let pool = try makePool()
        let center = start(pool)
        await waitUntil(center) { $0?.seenCount == 1 }
        await waitForWrites(center, 1)
        let memory = center.selection?.sections.flatMap(\.cards).first { $0.id == "memory" }
        XCTAssertEqual(memory?.seenHow, .inUse)
        XCTAssertEqual(memory?.canShowAgain, false)
        await center.showAgain("memory")
        XCTAssertEqual(try seen(pool), ["memory": .inUse])
        XCTAssertEqual(center.writes, 1)
    }

    /// The catalog failing to load hides the zone; it is not retried this launch.
    func testCatalogFailureHidesTheZone() async throws {
        let pool = try makePool()
        let loaded = expectation(description: "catalog load")
        loaded.assertForOverFulfill = true
        let center = start(pool) {
            await MainActor.run { loaded.fulfill() }
            throw CLIRunnerError.binaryNotFound
        }
        await fulfillment(of: [loaded])
        // A restart (another workspace) does not load again.
        center.start(pool: pool, newAfter: nil)
        await center.refresh()
        XCTAssertNil(center.selection)
        XCTAssertNil(center.zone)
    }

    func testEmptyCatalogHidesTheZone() async throws {
        let pool = try makePool()
        let center = start(pool) { LearnCatalog(cards: []) }
        await waitUntil(center) { $0 != nil }
        XCTAssertNil(center.zone)
    }
}

private actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// No hub answers on the socket: `HubCenter` reads `hub status --json` instead.
private struct NoHubClient: HubControlClienting {
    func send(_ request: HubControlRequest) async throws -> HubControlAnswer { throw HubControlError.noHub }
    func watch() -> AsyncThrowingStream<HubEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: HubControlError.noHub) }
    }
}

/// Learn's "iPhone paired" is the Go hub's `phones` count from `hub status`.
@MainActor
final class LiveLearnEnvironmentTests: XCTestCase {
    func testIPhonePairedReadsThePhonesCountOfTheHubStatus() async throws {
        let appState = AppState { [:] }
        let environment = LiveLearnEnvironment(appState: appState)
        XCTAssertFalse(environment.iphonePaired, "no hub center")

        for (phones, paired) in [(0, false), (2, true)] {
            let cli = FakeCLIRunner(stdout: Data(#"{"state":"running","phones":\#(phones)}"#.utf8))
            let center = HubCenter(client: NoHubClient(), cli: cli) { _ in try? await parkUntilTaskCancelled() }
            appState.hubCenter = center
            center.start()
            defer { center.stop() }
            await untilObserved { center.status?.phones != nil }
            XCTAssertEqual(center.status?.phones, phones)
            XCTAssertEqual(environment.iphonePaired, paired, "\(phones) phones")
        }
    }
}
