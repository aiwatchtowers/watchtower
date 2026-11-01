import Foundation
import XCTest
import WatchtowerCore

/// The `MOVED` note a newer Watchtower leaves in `MobileHub/` once its Go hub
/// adopted the Swift hub (go hub spec §12.1). Fails closed: only a missing note,
/// or a readable one without the line `hub_impl=go`, keeps the Swift hub.
final class MobileHubMovedGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileHubMovedGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let note = dir.appendingPathComponent(MobileHubMovedGuard.noteName)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private var note: URL { dir.appendingPathComponent(MobileHubMovedGuard.noteName) }

    private func writeNote(_ bytes: [UInt8]) throws {
        try Data(bytes).write(to: note)
    }

    private func writeNote(_ text: String) throws {
        try writeNote(Array(text.utf8))
    }

    func testTheNoteTheGoHubWritesStopsTheSwiftHub() throws {
        try writeNote("hub_impl=go\nmoved_to=/var/empty/.hub\n")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testTheImplLineMayComeAnywhereInTheNote() throws {
        try writeNote("moved_to=/var/empty/.hub\nhub_impl=go")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testACRLFNoteStopsTheSwiftHub() throws {
        try writeNote("hub_impl=go\r\nmoved_to=/var/empty/.hub\r\n")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
        try writeNote("  hub_impl=go \r\n")
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir), "spaces around the line are trimmed")
    }

    func testANoteWithoutTheImplLineIsIgnored() throws {
        for text in ["", "\n", "moved_to=/var/empty/.hub\n", "hub_impl=swift\n", "hub_impl=go2\n", "# hub_impl=go\n"] {
            try writeNote(text)
            XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir), "note \(text.debugDescription)")
        }
    }

    func testNoNoteKeepsTodaysBehaviour() {
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir.appendingPathComponent("absent", isDirectory: true)))
    }

    func testADirectoryNamedLikeTheNoteCountsAsMoved() throws {
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testASymlinkCountsAsMovedAndIsNeverFollowed() throws {
        let target = dir.appendingPathComponent("elsewhere")
        try Data("moved_to=/var/empty/.hub\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: target)
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir), "a symlink to a note without the line")
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: dir.appendingPathComponent("dangling"))
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir), "a dangling symlink")
    }

    func testAnUnreadableNoteCountsAsMoved() throws {
        try writeNote("moved_to=/var/empty/.hub\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: note.path)
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testANoteThatIsNotUTF8CountsAsMoved() throws {
        try writeNote([0xFF, 0xFE, 0x0A] + Array("moved_to=/var/empty/.hub\n".utf8))
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    /// A note longer than the cap, cut in the middle of a multi-byte character:
    /// the cut last line is skipped, the complete lines still decide.
    func testALongNoteCutMidCharacterIsStillRead() throws {
        let cap = 4096
        func note(first: String) -> [UInt8] {
            var bytes = Array("\(first)\nmoved_to=/var/empty/".utf8)
            while bytes.count < cap - 1 { bytes.append(UInt8(ascii: "a")) }
            return bytes + Array("é\n".utf8) // "é" is two bytes: the cap falls between them
        }
        try writeNote(note(first: "hub_impl=go"))
        XCTAssertTrue(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
        try writeNote(note(first: "hub_impl=swift"))
        XCTAssertFalse(MobileHubMovedGuard.isMoved(mobileHubDir: dir))
    }

    func testThePinnedNames() {
        XCTAssertEqual(MobileHubMovedGuard.noteName, "MOVED")
        XCTAssertEqual(MobileHubMovedGuard.message, "Mobile is run by a newer Watchtower")
    }
}
