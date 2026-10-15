import XCTest
@testable import WatchtowerMobile

/// The signed build's demo (#174): Welcome's Try the Demo builds a demo
/// root whose files and settings live apart from a linked Mac's, and Exit
/// Demo removes them.
@MainActor
final class DemoTourTests: XCTestCase {
    func testTheTourShowsTheDemoMacsFromItsOwnFilesAndExitRemovesThem() async throws {
        let root = try AppRoot.tour()
        let directory = try AppRoot.tourDirectory()
        XCTAssertTrue(root.isDemo)
        XCTAssertFalse(root.showsOnboarding, "the tour opens on the tabs")
        XCTAssertEqual(root.linking.links.map(\.link.macName), ["Acme Mac", "Home Mac"])
        try await poll(timeout: 20, {
            root.env.sessions.values.allSatisfy { !$0.workbenchReplica.snapshot.workbenches.isEmpty }
        }, "both demo Macs hydrated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replica.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recordings").path))

        await root.endTour()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Exit Demo removes the tour's files")
        XCTAssertTrue(
            UserDefaults(suiteName: AppRoot.tourDefaultsSuite)?.dictionaryRepresentation()
                .keys.allSatisfy { !$0.hasPrefix("demo.") } ?? false,
            "and its settings"
        )
    }

    /// A kill mid-tour leaves its files: the next tour starts from none.
    func testANewTourStartsWithoutAnEarlierTourLeftovers() async throws {
        let directory = try AppRoot.tourDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = directory.appendingPathComponent("leftover")
        try Data("x".utf8).write(to: leftover)

        let root = try AppRoot.tour()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        await root.endTour()
    }
}
