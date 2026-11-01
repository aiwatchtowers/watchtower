import Foundation
import XCTest
import WatchtowerCore

/// The `MOVED` note a newer Watchtower leaves in `MobileHub/` once its Go hub
/// adopted the Swift hub (go hub spec §12.1): only a note with the line
/// `hub_impl=go` stops the Swift hub.
final class MobileHubMovedGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileHubMovedGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeNote(_ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(MobileHubMovedGuard.noteName))
    }

    func testTheNoteTheGoHubWritesStopsTheSwiftHub() throws {
        try writeNote("hub_impl=go\nmoved_to=/var/empty/.hub\n")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testTheImplLineMayComeAnywhereInTheNote() throws {
        try writeNote("moved_to=/var/empty/.hub\nhub_impl=go")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testANoteWithoutTheImplLineIsIgnored() throws {
        for text in ["", "moved_to=/var/empty/.hub\n", "hub_impl=swift\n", "hub_impl=go2\n", "# hub_impl=go\n", " hub_impl=go\n"] {
            try writeNote(text)
            XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir), "note \(text.debugDescription)")
        }
    }

    func testNoNoteKeepsTodaysBehaviour() {
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir.appendingPathComponent("absent", isDirectory: true)))
    }

    func testADirectoryNamedLikeTheNoteIsIgnored() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(MobileHubMovedGuard.noteName), withIntermediateDirectories: true)
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testThePinnedNames() {
        XCTAssertEqual(MobileHubMovedGuard.noteName, "MOVED")
        XCTAssertEqual(MobileHubMovedGuard.message, "Mobile is run by a newer Watchtower")
    }
}
