import XCTest
@testable import WatchtowerMobile

/// The signed build's demo (#174): Welcome's Try the Demo builds a demo
/// root whose files and settings live apart from a linked Mac's, Exit Demo
/// removes them, and a new tour waits for the last one to end.
@MainActor
final class DemoTourTests: XCTestCase {
    private var directory: URL {
        get throws { try AppRoot.tourDirectory() }
    }

    private var suite: UserDefaults {
        get throws { try XCTUnwrap(UserDefaults(suiteName: AppRoot.tourDefaultsSuite)) }
    }

    /// Ends whatever tour a test left on screen, also when it failed early.
    private func managed(_ tour: DemoTour) -> DemoTour {
        addTeardownBlock { @MainActor in
            tour.exit()
            await tour.ending?.value
        }
        return tour
    }

    private func hydrated(_ root: AppRoot) async throws {
        try await poll(timeout: 20, {
            root.env.sessions.values.allSatisfy { !$0.workbenchReplica.snapshot.workbenches.isEmpty }
        }, "both demo Macs hydrated")
    }

    /// The tour seeds from its own directory and suite: the live replica
    /// path and `UserDefaults.standard` stay as they were, and Exit Demo
    /// removes the tour's files and settings.
    func testTheTourKeepsItsFilesAndSettingsApartAndExitRemovesThem() async throws {
        let liveReplica = try AppEnvironment.applicationSupportDirectory().appendingPathComponent("replica.sqlite")
        let liveReplicaBefore = try? FileManager.default.attributesOfItem(atPath: liveReplica.path)[.modificationDate] as? Date
        let standardSeq = UserDefaults.standard.string(forKey: DemoSeed.hubSeqCeilingKey)

        let live = try AppRoot.demo(AppEnvironment(transportKind: .inMemoryDemo, defaults: try makeDefaults()), defaults: try makeDefaults())
        let tour = managed(DemoTour())
        await tour.start(over: live)
        let root = try XCTUnwrap(tour.root)
        XCTAssertTrue(root.isDemo)
        XCTAssertFalse(root.showsOnboarding, "the tour opens on the tabs")
        XCTAssertEqual(root.linking.links.map(\.link.macName), ["Acme Mac", "Home Mac"])
        try await hydrated(root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: try directory.appendingPathComponent("replica.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try directory.appendingPathComponent("recordings").path))
        XCTAssertNotNil(try suite.string(forKey: DemoSeed.hubSeqCeilingKey), "the seed's seqs go to the tour's suite")
        XCTAssertEqual(UserDefaults.standard.string(forKey: DemoSeed.hubSeqCeilingKey), standardSeq, "not to the app's")
        let liveReplicaAfter = try? FileManager.default.attributesOfItem(atPath: liveReplica.path)[.modificationDate] as? Date
        XCTAssertEqual(liveReplicaAfter, liveReplicaBefore, "the app's own replica path is untouched")

        tour.exit()
        XCTAssertNil(tour.root, "Exit Demo takes the tour off screen at once")
        await tour.ending?.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: try directory.path), "and removes its files")
        XCTAssertNil(try suite.string(forKey: DemoSeed.hubSeqCeilingKey), "and its settings")
    }

    /// Try the Demo right after Exit Demo waits for the old tour to end, so
    /// the old teardown never removes the new tour's files.
    func testANewTourWaitsForTheLastOneToEnd() async throws {
        let live = try AppRoot.demo(AppEnvironment(transportKind: .inMemoryDemo, defaults: try makeDefaults()), defaults: try makeDefaults())
        let tour = managed(DemoTour())
        await tour.start(over: live)
        let first = try XCTUnwrap(tour.root)
        try await hydrated(first)

        tour.exit()
        await tour.start(over: live)
        let second = try XCTUnwrap(tour.root)
        XCTAssertFalse(first === second)
        try await hydrated(second)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try directory.appendingPathComponent("replica.sqlite").path),
            "the first tour's teardown left the second tour's replica"
        )
        XCTAssertNotNil(try suite.string(forKey: DemoSeed.hubSeqCeilingKey))
    }

    /// A link URL from the Camera during the tour ends it: the live root
    /// gets the URL.
    func testALinkURLEndsTheTour() async throws {
        let live = try AppRoot.demo(AppEnvironment(transportKind: .inMemoryDemo, defaults: try makeDefaults()), defaults: try makeDefaults())
        let tour = managed(DemoTour())
        await tour.start(over: live)
        let root = try XCTUnwrap(tour.root)

        await root.open(try XCTUnwrap(URL(string: "watchtower://link?c=demo")))

        XCTAssertNil(tour.root)
        XCTAssertNil(live.forwardsLinks, "only the tour forwards")
    }

    /// A tour that cannot start says so instead of doing nothing.
    func testATourThatCannotStartLeavesAFailure() async throws {
        let live = try AppRoot.demo(AppEnvironment(transportKind: .inMemoryDemo, defaults: try makeDefaults()), defaults: try makeDefaults())
        let tour = DemoTour { throw CocoaError(.fileWriteNoPermission) }

        await tour.start(over: live)

        XCTAssertNil(tour.root)
        XCTAssertNotNil(tour.failure)
        tour.dismissFailure()
        XCTAssertNil(tour.failure)
    }

    /// A kill mid-tour leaves its files: the live launch and the next tour
    /// clear them.
    func testLeftoversOfAKilledTourAreCleared() throws {
        try FileManager.default.createDirectory(at: try directory, withIntermediateDirectories: true)
        let leftover = try directory.appendingPathComponent("leftover")
        try Data("x".utf8).write(to: leftover)
        try suite.set("1", forKey: DemoSeed.hubSeqCeilingKey)

        AppRoot.clearTourLeftovers()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertNil(try suite.string(forKey: DemoSeed.hubSeqCeilingKey))
    }

    /// Only a live build offers Add Mac: the tour's scan would reach the
    /// owner's iCloud.
    func testTheDemoOffersNoAddMac() {
        XCTAssertFalse(MacsView.offersAdd(transportKind: .inMemoryDemo))
        XCTAssertTrue(MacsView.offersAdd(transportKind: .cloudKit))
    }
}
