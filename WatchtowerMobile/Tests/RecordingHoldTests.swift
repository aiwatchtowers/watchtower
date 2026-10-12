import Foundation
import XCTest
@testable import WatchtowerMobile

/// The hold folder's file moves (board #63).
final class RecordingHoldTests: XCTestCase {
    /// A name already taken in `unreadable` gets a numbered one, and every
    /// file still moves.
    func testProtectingUnreadableAudioNeverStopsAtANameClash() throws {
        let directory = try makeRecordingsDirectory()
        let hold = RecordingHold(recordingsDirectory: directory)
        let unreadable = hold.directory.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: unreadable.appendingPathComponent("a.m4a"))
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.m4a"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("b.m4a"))

        let result = try hold.protectUnreadable()

        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(result.failures.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: unreadable.path).sorted()
        XCTAssertEqual(kept, ["a-2.m4a", "a.m4a", "b.m4a"])
        XCTAssertEqual(try String(contentsOf: unreadable.appendingPathComponent("a.m4a"), encoding: .utf8), "earlier")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { !$0.hasPrefix(".") })
    }
}
