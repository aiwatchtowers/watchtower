import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// Live link R2: a socket request gets no more time than an HTTPS one (`HostedRelayConnection.requestTimeout`,
/// on the manual clock). Its expiry is a loss after the write (a read is resent over HTTPS, an upload is not
/// replayed), and it retires the socket, so the next op does not wait again.
final class HostedRelayRequestDeadlineTests: XCTestCase {
    private static let timeout = HostedRelayConnection.requestTimeout
    private var sessions: [(HostedRelaySession, SessionOwner)] = []

    override func tearDown() async throws {
        for (session, owner) in sessions { await session.detach(owner: ObjectIdentifier(owner)) }
        sessions = []
        try await super.tearDown()
    }

    /// The next unconditional op after a timed-out one goes out at once (over HTTPS, the socket retired),
    /// not after a second wait; the timed-out op itself is not replayed.
    func testTheNextOpAfterATimeoutDoesNotWaitAgain() async throws {
        let harness = try RelayClientHarness()
        let socket = ScriptedRelaySocket(requests: ["removeSlot": .silent])
        let session = await liveSession(harness, socket)

        let first = Task { try await session.send(RelayClientHarness.removeSlot) }
        await harness.clock.waitForSleeps(Self.timeout, count: 2)
        harness.clock.manual.advance(by: Self.timeout)
        let lost = await finish(first)
        XCTAssertEqual(lost?.error as? HostedRelayError, .unreachable)
        XCTAssertEqual(harness.http.requests("removeSlot").count, 0, "the timed-out op is not replayed")
        XCTAssertEqual(socket.closedWith, 1000, "the socket is retired")

        let next = Task { try await session.send(RelayClientHarness.removeSlot) }
        let answered = await finish(next)
        XCTAssertNotNil(answered?.value, "answered without moving the clock")
        XCTAssertEqual(harness.http.requests("removeSlot").count, 1, "over HTTPS")
    }

    /// An unanswered read is resent over HTTPS once its deadline passes.
    func testAnUnansweredReadIsResentOverHTTPS() async throws {
        let harness = try RelayClientHarness()
        var download = Relay_V1_Response()
        download.download = Relay_V1_Download()
        harness.http.script("getDownload", [.ok(download)])
        let session = await liveSession(harness, ScriptedRelaySocket(requests: ["getDownload": .silent]))

        let read = Task { try await session.getDownload(Relay_V1_GetDownload()) }
        await harness.clock.waitForSleeps(Self.timeout, count: 2)
        harness.clock.manual.advance(by: Self.timeout)

        let result = await finish(read)
        XCTAssertNotNil(result?.value)
        XCTAssertEqual(harness.http.requests("getDownload").count, 1)
    }

    /// An unanswered `create_upload` may have run: `.unreachable`, never replayed over HTTPS.
    func testAnUnansweredUploadIsNotReplayed() async throws {
        let harness = try RelayClientHarness()
        let session = await liveSession(harness, ScriptedRelaySocket(requests: ["createUpload": .silent]))

        let upload = Task { try await session.createUpload(Relay_V1_CreateUpload()) }
        await harness.clock.waitForSleeps(Self.timeout, count: 2)
        harness.clock.manual.advance(by: Self.timeout)

        let result = await finish(upload)
        XCTAssertEqual(result?.error as? HostedRelayError, .unreachable)
        XCTAssertEqual(harness.http.requests("createUpload").count, 0)
    }

    /// The deadline covers a write that never returns: it starts before the write.
    func testTheDeadlineCoversAWriteThatNeverReturns() async throws {
        let harness = try RelayClientHarness()
        let socket = ScriptedRelaySocket(hangsRequests: true)
        harness.sockets.script([.socket(socket)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        let request = Task { try await connection.send(RelayClientHarness.removeSlot) }
        let timed = await bounded { harness.clock.sleeps(of: Self.timeout) >= 2 }
        guard timed else { return XCTFail("the request's deadline did not start while its write hangs") }
        await harness.clock.waitForSleeps(Self.timeout, count: 2)
        harness.clock.manual.advance(by: Self.timeout)

        let result = await finish(request)
        XCTAssertEqual(result?.error as? HostedRelayError, .unreachable)
        XCTAssertEqual(socket.closedWith, 1000)
        await connection.close()
    }

    // MARK: - Helpers

    /// A session on `harness` whose socket is `socket`, live and settled: the post-connect account read
    /// answered (its deadline gone) and only the ping's 30 s sleep waiting.
    private func liveSession(_ harness: RelayClientHarness, _ socket: ScriptedRelaySocket) async -> HostedRelaySession {
        harness.sockets.script([.socket(socket)])
        let session = HostedRelaySession(client: harness.client)
        let owner = SessionOwner()
        sessions.append((session, owner))
        await session.attach(owner: ObjectIdentifier(owner), zones: []) { _ in }
        // The ping's sleep and the account read's deadline were both asked for; then only the ping waits.
        await spin { harness.clock.sleeps(of: Self.timeout) >= 2 }
        await harness.clock.waitForSleeps(Self.timeout, count: 1)
        return session
    }

    /// Whether `condition` holds within a bounded number of yields (no wall clock).
    private func bounded(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.yieldBound {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// `task`'s result within a bounded number of yields; a test failure (and the task cancelled) past it.
    private func finish<T: Sendable>(
        _ task: Task<T, any Error>, file: StaticString = #filePath, line: UInt = #line
    ) async -> Outcome<T>? {
        let box = OSAllocatedUnfairLock<Outcome<T>?>(initialState: nil)
        let watcher = Task {
            let result = await task.result
            box.withLock { $0 = Outcome(result) }
        }
        let done = await bounded { box.withLock { $0 } != nil }
        guard done else {
            XCTFail("did not finish without moving the clock", file: file, line: line)
            task.cancel()
            watcher.cancel()
            return nil
        }
        return box.withLock { $0 }
    }

    private static let yieldBound = 50_000

    /// A task's result, as plain fields.
    struct Outcome<T: Sendable>: Sendable {
        let value: T?
        let error: (any Error)?

        init(_ result: Result<T, any Error>) {
            switch result {
            case .success(let value): (self.value, self.error) = (value, nil)
            case .failure(let error): (self.value, self.error) = (nil, error)
            }
        }
    }
}
