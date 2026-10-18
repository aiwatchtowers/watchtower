import Foundation
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `session_chat` runner (cadence, watches, failures) and the kind's
/// place in the publisher.
final class SessionChatRunnerTests: XCTestCase {
    private static func feed(_ sessionID: Int64, text: String = "Hello") throws -> SessionFeedPayload {
        let entry = #"{"id":"e1","kind":"owner","at":"2026-01-01T10:00:00Z","text":"\#(text)"}"#
        let json = #"{"session_id":\#(sessionID),"cursor":"c1","entries":[\#(entry)],"subagents":[]}"#
        return try JSONDecoder().decode(SessionFeedPayload.self, from: Data(json.utf8))
    }

    private final class Calls: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [(Int64, String?)]())
        var all: [(Int64, String?)] { state.withLock { $0 } }
        var count: Int { all.count }
        func add(_ id: Int64, _ agent: String?) { state.withLock { $0.append((id, agent)) } }
    }

    private func runner(
        calls: Calls = Calls(),
        clock: TestInstant,
        live: Set<Int64> = [],
        timing: SessionChatRunner.Timing = .standard,
        fetch: SessionChatRunner.Fetch? = nil
    ) -> SessionChatRunner {
        SessionChatRunner(
            fetch: fetch ?? { id, agent in
                calls.add(id, agent)
                return try Self.feed(id)
            },
            isLive: { live.contains($0) },
            timing: timing,
            clock: { clock.now } // swiftlint:disable:this trailing_closure
        )
    }

    func testNoWatchPublishesNothing() async throws {
        let calls = Calls()
        let chat = runner(calls: calls, clock: TestInstant(), live: [7])
        await chat.runDue()
        XCTAssertTrue(chat.payloads().isEmpty)
        XCTAssertEqual(calls.count, 0)
    }

    func testRequestRunsAndPublishes() async throws {
        let calls = Calls()
        let chat = runner(calls: calls, clock: TestInstant())
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertEqual(calls.count, 1)
        let payloads = chat.payloads()
        XCTAssertEqual(Set(payloads.keys), ["session_chat-7"])
        let object = try SliceJSON.object(try XCTUnwrap(payloads["session_chat-7"]))
        XCTAssertEqual(object["session_id"] as? Int, 7)
    }

    func testLiveSessionRefreshesEvery10s() async throws {
        let calls = Calls()
        let clock = TestInstant()
        let chat = runner(calls: calls, clock: clock, live: [7])
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        clock.advance(by: .seconds(9))
        await chat.runDue()
        XCTAssertEqual(calls.count, 1, "not due before 10 s")
        clock.advance(by: .seconds(1))
        await chat.runDue()
        XCTAssertEqual(calls.count, 2)
    }

    func testFinishedSessionRunsOncePerWatch() async throws {
        let calls = Calls()
        let clock = TestInstant()
        let chat = runner(calls: calls, clock: clock)
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        clock.advance(by: .seconds(60))
        chat.request(sessionID: 7, agentID: nil)
        clock.advance(by: .seconds(60))
        await chat.runDue()
        XCTAssertEqual(calls.count, 1)
    }

    func testExpiredWatchLeavesWindow() async throws {
        let clock = TestInstant()
        let chat = runner(clock: clock)
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        clock.advance(by: .seconds(299))
        XCTAssertEqual(chat.payloads().count, 1)
        clock.advance(by: .seconds(2))
        XCTAssertTrue(chat.payloads().isEmpty)
        XCTAssertTrue(chat.watches.withLock { $0.isEmpty }, "the watch and its payload are freed")
    }

    func testRepeatRequestExtendsWatch() async throws {
        let clock = TestInstant()
        let chat = runner(clock: clock)
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        clock.advance(by: .seconds(200))
        chat.request(sessionID: 7, agentID: nil)
        clock.advance(by: .seconds(200))
        XCTAssertEqual(chat.payloads().count, 1, "400 s after the first request, 200 s after the last")
        clock.advance(by: .seconds(101))
        XCTAssertTrue(chat.payloads().isEmpty)
    }

    func testSubagentWatchIsSeparate() async throws {
        let calls = Calls()
        let chat = runner(calls: calls, clock: TestInstant())
        chat.request(sessionID: 7, agentID: nil)
        chat.request(sessionID: 7, agentID: "a1b2")
        await chat.runDue()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(chat.payloads().keys), ["session_chat-7", "session_chat-7-a1b2"])
        XCTAssertEqual(
            SessionChatRunner.arguments(sessionID: 7, agentID: "a1b2"),
            ["workbench", "session-feed", "--session", "7", "--json", "--subagent", "a1b2"]
        )
        XCTAssertEqual(SessionChatRunner.arguments(sessionID: 7, agentID: nil), ["workbench", "session-feed", "--session", "7", "--json"])
    }

    func testCliFetchRunsTheArgvAndDecodes() async throws {
        let json = #"{"session_id":7,"cursor":"c","entries":[{"id":"e1","kind":"owner","text":"Hi"}],"subagents":[]}"#
        let cli = FakeCLIRunner(stdout: Data(json.utf8))
        let feed = try await SessionChatRunner.cliFetch(cli)(7, "a1b2")
        XCTAssertEqual(feed.entries.map(\.id), ["e1"])
        XCTAssertEqual(cli.invocations, [SessionChatRunner.arguments(sessionID: 7, agentID: "a1b2")])
    }

    func testFetchFailureKeepsLastPayload() async throws {
        let failing = OSAllocatedUnfairLock(initialState: false)
        let clock = TestInstant()
        let chat = runner(clock: clock, live: [7]) { id, _ in
            if failing.withLock({ $0 }) { throw CocoaError(.fileReadUnknown) }
            return try Self.feed(id)
        }
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        let first = try XCTUnwrap(chat.payloads()["session_chat-7"])
        failing.withLock { $0 = true }
        clock.advance(by: .seconds(10))
        let attempted = await chat.runDue()
        XCTAssertEqual(attempted.count, 1)
        XCTAssertEqual(chat.payloads()["session_chat-7"], first)
        failing.withLock { $0 = false }
        clock.advance(by: .seconds(10))
        let next = await chat.runDue()
        XCTAssertEqual(next.count, 1, "the next run is still scheduled")
    }

    func testTimeoutBoundsRun() async throws {
        let chat = runner(
            clock: TestInstant(),
            timing: .init(every: .seconds(10), watch: .seconds(300), timeout: .milliseconds(50), wake: .seconds(2))
        ) { id, _ in
            try await Task.sleep(for: .seconds(30))
            return try Self.feed(id)
        }
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertTrue(chat.payloads().isEmpty)
    }

    func testStopDropsEverything() async throws {
        let chat = runner(clock: TestInstant())
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertEqual(chat.payloads().count, 1)
        chat.stop()
        XCTAssertTrue(chat.payloads().isEmpty)
    }

    func testLoopRunsOnlyWhilePhoneIsLinked() async throws {
        let linked = OSAllocatedUnfairLock(initialState: false)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let calls = Calls()
        let chat = SessionChatRunner(
            fetch: { id, agent in
                calls.add(id, agent)
                return try Self.feed(id)
            },
            isLive: { _ in false },
            timing: .init(every: .seconds(10), watch: .seconds(300), timeout: .seconds(5), wake: .milliseconds(10)),
            isActive: { // swiftlint:disable:this trailing_closure
                checks.withLock { $0 += 1 }
                return linked.withLock { $0 }
            }
        )
        chat.request(sessionID: 7, agentID: nil)
        chat.start()
        defer { chat.stop() }
        await awaitHubCondition("the loop woke three times") { checks.withLock { $0 } >= 3 }
        XCTAssertEqual(calls.count, 0)
    }

    func testNotUrgent() {
        XCTAssertFalse(SlicePublisher.urgentKinds.contains(.sessionChat))
        XCTAssertFalse(RelayProcessor.nonIdempotentKinds.contains(.sessionChatRequest))
    }

    func testUnlinkedPhoneDropsPayloadsForGood() async throws {
        let active = OSAllocatedUnfairLock(initialState: true)
        let chat = SessionChatRunner(
            fetch: { id, _ in try Self.feed(id) },
            isLive: { _ in false },
            isActive: { active.withLock { $0 } }
        )
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertEqual(chat.payloads().count, 1)
        active.withLock { $0 = false }
        XCTAssertTrue(chat.payloads().isEmpty)
        active.withLock { $0 = true }
        XCTAssertTrue(chat.payloads().isEmpty, "the old payload is not resurrected")
    }

    func testNewRequestAfterExpiryRunsAgain() async throws {
        let calls = Calls()
        let clock = TestInstant()
        let chat = runner(calls: calls, clock: clock)
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        clock.advance(by: .seconds(301))
        XCTAssertTrue(chat.payloads().isEmpty)
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(chat.payloads().count, 1)
    }

    func testFetchInFlightWhenWatchExpiresStoresNothing() async throws {
        let clock = TestInstant()
        let chat = runner(clock: clock) { id, _ in
            clock.advance(by: .seconds(301))
            return try Self.feed(id)
        }
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        XCTAssertTrue(chat.payloads().isEmpty)
        XCTAssertTrue(chat.watches.withLock { $0.isEmpty })
    }

    func testStopDuringFetchStoresNothing() async throws {
        let box = OSAllocatedUnfairLock<SessionChatRunner?>(initialState: nil)
        let chat = runner(clock: TestInstant()) { id, _ in
            box.withLock { $0 }?.stop()
            return try Self.feed(id)
        }
        box.withLock { $0 = chat }
        chat.request(sessionID: 7, agentID: nil)
        await chat.runDue()
        chat.request(sessionID: 7, agentID: nil)
        XCTAssertTrue(chat.payloads().isEmpty, "the run cut by stop() stored nothing")
    }
}
