import XCTest
@testable import WatchtowerCore

/// Spec 2026-11-15 §5 "A turn run elsewhere": the line's exact copy, Send
/// off while the hub holds the open chat, and the reload cadence (every read
/// while held, once at the release, never otherwise).
final class ChatForeignTurnModelTests: XCTestCase {
    private func lease(_ owner: ChatLease.Owner, turn: String = "t1", heartbeat: Int64 = 10_000) -> ChatLease {
        ChatLease(conversationID: 1, owner: owner, ownerID: "x", turnID: turn, startedAtMS: heartbeat, heartbeatAtMS: heartbeat)
    }

    func testCopy() {
        XCTAssertEqual(ChatForeignTurnModel.answeringFromPhone, "Answering from your iPhone — you can watch here")
        XCTAssertEqual(ChatForeignTurnModel.pollInterval, .seconds(1))
    }

    func testReloadCadence() {
        var model = ChatForeignTurnModel()
        XCTAssertNil(model.line)
        XCTAssertFalse(model.blocksSend)

        XCTAssertEqual(model.observe(nil, nowMS: 10_000), .init(reloadThread: false, reloadPanel: false), "idle: nothing re-read")

        XCTAssertEqual(model.observe(lease(.hub), nowMS: 10_500), .init(reloadThread: true, reloadPanel: true), "the hub's turn starts")
        XCTAssertEqual(model.line, "Answering from your iPhone — you can watch here")
        XCTAssertTrue(model.blocksSend)
        XCTAssertEqual(model.turnID, "t1")

        XCTAssertEqual(model.observe(lease(.hub, heartbeat: 11_000), nowMS: 11_500), .init(reloadThread: true, reloadPanel: false),
                       "every read while held re-reads the thread")

        XCTAssertEqual(model.observe(nil, nowMS: 12_500), .init(reloadThread: true, reloadPanel: true), "once at the release")
        XCTAssertNil(model.line)
        XCTAssertFalse(model.blocksSend)
        XCTAssertEqual(model.observe(nil, nowMS: 13_500), .init(reloadThread: false, reloadPanel: false), "and only once")
    }

    func testOwnAndStaleLeasesAreNotForeign() {
        var model = ChatForeignTurnModel()
        XCTAssertEqual(model.observe(lease(.desktop), nowMS: 10_500), .init(reloadThread: false, reloadPanel: false),
                       "the Mac's own turn is shown live by its driver")
        XCTAssertNil(model.line)
        XCTAssertEqual(model.observe(lease(.hub), nowMS: 10_000 + 60_001), .init(reloadThread: false, reloadPanel: false),
                       "a stale hub lease: its owner is dead, anyone may send")
        XCTAssertFalse(model.blocksSend)
    }

    func testNextHubTurnAndReset() {
        var model = ChatForeignTurnModel()
        _ = model.observe(lease(.hub, turn: "a"), nowMS: 10_000)
        XCTAssertEqual(model.observe(lease(.hub, turn: "b"), nowMS: 10_000), .init(reloadThread: true, reloadPanel: true))
        model.reset()
        XCTAssertNil(model.turnID)
        XCTAssertNil(model.line)
    }
}
