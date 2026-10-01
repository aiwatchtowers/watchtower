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
        XCTAssertNotNil(p.errorMessage, "a clip that cannot play must say so, not look like a dead button")
    }

    func testRefusedPlaybackIsReportedAndClearedByTheNextPlay() {
        let refusing = RefusingPlayback()
        var player: AudioPlayback = refusing
        let p = ClipPlayer { _ in player }

        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 0, end: 5))
        XCTAssertNil(p.playingSpan)
        XCTAssertNotNil(p.errorMessage)

        player = FakeAudioPlayback(duration: 60)
        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 0, end: 5))
        XCTAssertNil(p.errorMessage)
        XCTAssertEqual(p.playingSpan, ClipSpan(start: 0, end: 5))
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

    func testToggleStopsTheClipThatIsPlaying() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        let url = URL(fileURLWithPath: "/tmp/x.caf")
        let span = ClipSpan(start: 10, end: 15)

        p.toggle(url: url, span: span)
        XCTAssertTrue(p.isPlaying(url: url, span: span))

        p.toggle(url: url, span: span)
        XCTAssertFalse(p.isPlaying(url: url, span: span))
        XCTAssertFalse(fake.isPlaying)
    }

    func testToggleOnAnotherClipSwitchesToIt() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        let url = URL(fileURLWithPath: "/tmp/x.caf")

        p.toggle(url: url, span: ClipSpan(start: 10, end: 15))
        p.toggle(url: url, span: ClipSpan(start: 30, end: 35))

        XCTAssertTrue(p.isPlaying(url: url, span: ClipSpan(start: 30, end: 35)))
        XCTAssertFalse(p.isPlaying(url: url, span: ClipSpan(start: 10, end: 15)))
        XCTAssertEqual(fake.currentTime, 30)
        XCTAssertTrue(fake.isPlaying)
    }

    // The same span of a different recording is a different clip: toggling
    // it switches playback instead of stopping.
    func testSameSpanOfAnotherRecordingIsAnotherClip() {
        let fake = FakeAudioPlayback(duration: 60)
        let p = ClipPlayer { _ in fake }
        let span = ClipSpan(start: 10, end: 15)
        let a = URL(fileURLWithPath: "/tmp/a.caf")
        let b = URL(fileURLWithPath: "/tmp/b.caf")

        p.toggle(url: a, span: span)
        p.toggle(url: b, span: span)

        XCTAssertTrue(p.isPlaying(url: b, span: span))
        XCTAssertFalse(p.isPlaying(url: a, span: span))
        XCTAssertTrue(fake.isPlaying)
    }
}

/// An output that refuses to start — `play()` returns false.
private final class RefusingPlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 60
    var isPlaying: Bool { false }
    func play() -> Bool { false }
    func pause() {}
    func stop() {}
}
