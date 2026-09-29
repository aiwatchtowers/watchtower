import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class ClipPlayerTests: XCTestCase {
    func testPlaysOnlyTheSpan() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }

        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 10, end: 15))

        XCTAssertEqual(fake.currentTime, 10)
        XCTAssertTrue(fake.isPlaying)
        XCTAssertEqual(p.playingSpan, ClipSpan(start: 10, end: 15))

        fake.currentTime = 15.01
        p.tick()

        XCTAssertFalse(fake.isPlaying)
        XCTAssertNil(p.playingSpan)
    }

    func testPlayingASecondSpanStopsTheFirst() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 10, end: 15))

        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 30, end: 35))

        XCTAssertEqual(fake.currentTime, 30)
        XCTAssertEqual(p.playingSpan, ClipSpan(start: 30, end: 35))
    }

    // Degenerate: a factory that fails to produce a player must leave
    // nothing playing rather than crash.
    func testPlayFailureLeavesNothingPlaying() {
        struct BoomError: Error {}
        let p = ClipPlayer { _ in throw BoomError() }

        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 0, end: 5))

        XCTAssertNil(p.playingSpan)
    }

    func testStopClearsPlayingSpan() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 0, end: 5))

        p.stop()

        XCTAssertNil(p.playingSpan)
        XCTAssertFalse(fake.isPlaying)
    }

    // Degenerate: the player stopping itself (natural end / underlying
    // error) must be picked up by tick() too, not just reaching span.end.
    func testTickStopsWhenPlayerStopsItself() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 0, end: 30))
        fake.pause() // simulates the player's own isPlaying flipping false

        p.tick()

        XCTAssertNil(p.playingSpan)
    }
}
