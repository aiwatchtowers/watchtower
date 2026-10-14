import Foundation
import XCTest
@testable import WatchtowerMobile

/// The hold folder's file moves (board #63).
final class RecordingHoldTests: XCTestCase {
    /// A name already taken in `unreadable` gets a numbered one, and every
    /// file still moves.
    func testProtectingUnreadableAudioNeverStopsAtANameClash() throws {
        let directory = try makeRecordingsDirectory()
        let hold = RecordingHold(directory: directory.appendingPathComponent(".held", isDirectory: true))
        let unreadable = hold.directory.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: unreadable.appendingPathComponent("a.m4a"))
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.m4a"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("b.m4a"))

        let result = try hold.protectUnreadable(in: directory)

        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(result.failures.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: unreadable.path).sorted()
        XCTAssertEqual(kept, ["a-2.m4a", "a.m4a", "b.m4a"])
        XCTAssertEqual(try String(contentsOf: unreadable.appendingPathComponent("a.m4a"), encoding: .utf8), "earlier")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { !$0.hasPrefix(".") })
    }

    /// A manifest entry as a removal writes it.
    private func held(_ id: String, file: String) throws -> HeldRecording {
        let json = """
        {"id":"\(id)","fileName":"\(file)","hubID":"hub-gone","startedAt":0,"endedAt":30,"durationSec":30,"marks":[]}
        """
        return try JSONDecoder().decode(HeldRecording.self, from: Data(json.utf8))
    }

    /// Board #171: deleting one held recording removes its audio and its
    /// manifest entry, and leaves the others held.
    func testDiscardingAHeldRecordingRemovesItsAudioAndEntry() throws {
        let directory = try makeRecordingsDirectory()
        let hold = RecordingHold(directory: directory.appendingPathComponent(".held", isDirectory: true))
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.m4a"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("b.m4a"))
        try hold.hold([held("a", file: "a.m4a"), held("b", file: "b.m4a")], from: directory)

        try hold.discard(id: "a")

        XCTAssertEqual(try hold.load().map(\.id), ["b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hold.directory.appendingPathComponent("a.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hold.directory.appendingPathComponent("b.m4a").path))
        XCTAssertNoThrow(try hold.discard(id: "missing"), "an id no longer held deletes nothing")
    }

    /// Board #171: the unreadable audio is listed by name, one file is
    /// deleted by name, and a name outside the folder deletes nothing.
    func testUnreadableAudioIsListedAndDeletedByName() throws {
        let directory = try makeRecordingsDirectory()
        let hold = RecordingHold(directory: directory.appendingPathComponent(".held", isDirectory: true))
        XCTAssertEqual(try hold.unreadableAudio(), [], "no folder, nothing listed")
        try Data("bb".utf8).write(to: directory.appendingPathComponent("b.m4a"))
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.m4a"))
        try hold.protectUnreadable(in: directory)
        try Data("keep".utf8).write(to: hold.directory.appendingPathComponent("keep.m4a"))

        let listed = try hold.unreadableAudio()
        XCTAssertEqual(listed.map(\.name), ["a.m4a", "b.m4a"])
        XCTAssertEqual(listed.map(\.byteCount), [1, 2])

        try hold.deleteUnreadable(named: "../keep.m4a")
        try hold.deleteUnreadable(named: "a.m4a")

        XCTAssertEqual(try hold.unreadableAudio().map(\.name), ["b.m4a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hold.directory.appendingPathComponent("keep.m4a").path))
    }
}
