import XCTest
@testable import WatchtowerCore

/// CHAT-03's decision half: at most 3 live sessions, LRU eviction, idle TTL.
final class ChatSessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)
    private typealias Snap = ChatSessionPolicy.SessionSnapshot

    private func snap(_ id: Int64, idle: TimeInterval, busy: Bool = false, alive: Bool = true) -> Snap {
        Snap(conversationID: id, lastActivity: now.addingTimeInterval(-idle), busy: busy, alive: alive)
    }

    func testConstants() {
        XCTAssertEqual(ChatSessionPolicy.maxLive, 3)
        XCTAssertEqual(ChatSessionPolicy.idleTTL, 600)
        XCTAssertEqual(ChatSessionPolicy.pollInterval, .seconds(30))
    }

    func testSpawnsWhenBelowTheBound() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5)], now: now, wanted: 2), [.spawn(2)])
    }

    func testWantedAndAliveIsANoOp() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5)], now: now, wanted: 1), [])
    }

    func testEvictsTheLeastRecentlyUsedIdleSessionAtTheBound() {
        let sessions = [snap(1, idle: 30), snap(2, idle: 90), snap(3, idle: 10)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(2), .spawn(4)])
    }

    func testPrefersIdleOverBusyWhenEvicting() {
        let sessions = [snap(1, idle: 300, busy: true), snap(2, idle: 20), snap(3, idle: 10)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(2), .spawn(4)])
    }

    /// A running turn is never cut to make room: with three busy sessions
    /// the fourth conversation is queued (no spawn), nothing is evicted.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03NeverEvictsABusySessionQueuesInstead() {
        let sessions = [snap(1, idle: 30, busy: true), snap(2, idle: 90, busy: true), snap(3, idle: 10, busy: true)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [])
    }

    /// A process still shutting down occupies a slot.
    func testRetiringProcessesOccupySlots() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5, busy: true)], now: now, wanted: 2, retiring: 2),
                       [])
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5)], now: now, wanted: 2, retiring: 2),
                       [.evict(1), .spawn(2)])
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [], now: now, wanted: 2, retiring: 2), [.spawn(2)])
    }

    /// Invariant over every reachable shape (occupied slots <= maxLive):
    /// applying the plan never exceeds the bound, never evicts a busy
    /// session, and spawns whenever an idle session could make room.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03DecisionNeverExceedsTheBound() {
        for count in 0...ChatSessionPolicy.maxLive {
            for retiring in 0...(ChatSessionPolicy.maxLive - count) {
                for busyMask in 0..<(1 << count) {
                    let sessions = (0..<count).map {
                        snap(Int64($0), idle: TimeInterval($0 * 7), busy: busyMask & (1 << $0) != 0)
                    }
                    let actions = ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 99, retiring: retiring)
                    var live = Set(sessions.map(\.conversationID))
                    for action in actions {
                        switch action {
                        case let .evict(id):
                            XCTAssertFalse(sessions.first { $0.conversationID == id }?.busy ?? true, "evicted busy \(id)")
                            live.remove(id)
                        case let .spawn(id):
                            live.insert(id)
                        }
                    }
                    let label = "count \(count) retiring \(retiring) mask \(busyMask)"
                    XCTAssertLessThanOrEqual(live.count + retiring, ChatSessionPolicy.maxLive, label)
                    let idle = sessions.contains { !$0.busy }
                    let hasRoom = count + retiring < ChatSessionPolicy.maxLive
                    XCTAssertEqual(live.contains(99), idle || hasRoom, label)
                }
            }
        }
    }

    func testIdleTTLExpiresOnlyIdleNonWantedSessions() {
        let sessions = [snap(1, idle: 600), snap(2, idle: 599), snap(3, idle: 900, busy: true), snap(4, idle: 700)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(1)])
    }

    func testDeadSessionsAreEvictedAndRespawnedWhenWanted() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 1, alive: false)], now: now, wanted: 1),
                       [.evict(1), .spawn(1)])
    }

    func testNoSessionsNoWantIsEmpty() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [], now: now, wanted: nil), [])
    }
}
