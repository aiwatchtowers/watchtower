import Foundation
import os
import SwiftProtobuf
import WatchtowerHostedRelay
import WatchtowerRelayProto
import XCTest

/// The server end of one scripted WebSocket. It answers `Hello` and each
/// `Request` from its script as soon as the client sends them, and lets the
/// test push frames or close the socket from the server's side.
final class ScriptedRelaySocket: RelaySocket, @unchecked Sendable {
    enum HelloReply: Sendable {
        case ok
        case close(Int)
        case silent
    }

    enum Answer: Sendable {
        case ok
        case error(Relay_V1_ErrorCode)
        case silent
    }

    struct ClosedByClient: Error {}

    private struct State {
        var inbound: [RelaySocketMessage] = []
        var receiver: CheckedContinuation<RelaySocketMessage, any Error>?
        var sent: [Relay_V1_Frame] = []
        var pings = 0
        var pingWaiters: [CheckedContinuation<Void, any Error>] = []
        var closedWith: Int?
    }

    private let hello: HelloReply
    private let pongs: Bool
    private let subscribeAnswers: [String: Answer]
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `subscribe`: the answer per zone (every other zone, and every other op, gets `Ok`).
    init(hello: HelloReply = .ok, pongs: Bool = true, subscribe: [String: Answer] = [:]) {
        self.hello = hello
        self.pongs = pongs
        self.subscribeAnswers = subscribe
    }

    // MARK: - What the test sees

    /// Every frame the client sent, in order.
    var sent: [Relay_V1_Frame] {
        state.withLock { $0.sent }
    }

    /// The zones of every `subscribe` the client sent, one list per request.
    var subscribes: [[String]] {
        sent.compactMap { frame in
            guard case .subscribe(let subscribe) = frame.request.op else { return nil }
            return subscribe.zones
        }
    }

    var pings: Int {
        state.withLock { $0.pings }
    }

    /// The close code the client closed with, nil while it has not.
    var closedWith: Int? {
        state.withLock { $0.closedWith }
    }

    /// True once the client waits in `receive` with nothing left to read:
    /// everything pushed so far has been handled.
    var drained: Bool {
        state.withLock { $0.receiver != nil && $0.inbound.isEmpty }
    }

    func waitForPings(_ count: Int) async {
        await spin { self.pings >= count }
    }

    func waitUntilDrained() async {
        await spin { self.drained }
    }

    func waitUntilClosedByClient() async {
        await spin { self.closedWith != nil }
    }

    // MARK: - The server's side

    func push(_ frame: Relay_V1_Frame) {
        // swiftlint:disable:next force_try
        deliver(.binary(try! frame.serializedData()))
    }

    func pushZoneChanged(_ zone: String, seq: UInt64) {
        var changed = Relay_V1_ZoneChanged()
        changed.zone = zone
        changed.seq = seq
        var frame = Relay_V1_Frame()
        frame.event.zoneChanged = changed
        push(frame)
    }

    func pushControl(_ kind: Relay_V1_ControlKind, detail: String = "") {
        var control = Relay_V1_Control()
        control.kind = kind
        control.detail = detail
        var frame = Relay_V1_Frame()
        frame.event.control = control
        push(frame)
    }

    func pushGoingAway() {
        var frame = Relay_V1_Frame()
        frame.goingAway = Relay_V1_GoingAway()
        push(frame)
    }

    func closeFromServer(_ code: Int) {
        deliver(.closed(code: code))
    }

    // MARK: - RelaySocket

    func send(_ data: Data) async throws {
        let frame = try Relay_V1_Frame(serializedBytes: data)
        try state.withLock { state in
            guard state.closedWith == nil else { throw ClosedByClient() }
            state.sent.append(frame)
        }
        switch frame.kind {
        case .hello:
            switch hello {
            case .ok:
                var reply = Relay_V1_Frame()
                reply.helloOk = Relay_V1_HelloOk()
                push(reply)
            case .close(let code):
                closeFromServer(code)
            case .silent:
                break
            }
        case .request(let request):
            answer(request)
        default:
            break
        }
    }

    func receive() async throws -> RelaySocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<RelaySocketMessage, any Error>? = state.withLock { state in
                if !state.inbound.isEmpty { return .success(state.inbound.removeFirst()) }
                if state.closedWith != nil { return .failure(ClosedByClient()) }
                state.receiver = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if state.closedWith != nil { return .failure(ClosedByClient()) }
                state.pings += 1
                if pongs { return .success(()) }
                state.pingWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func close(code: Int) async {
        let (receiver, pingWaiters) = state.withLock { state in
            if state.closedWith == nil { state.closedWith = code }
            defer {
                state.receiver = nil
                state.pingWaiters = []
            }
            return (state.receiver, state.pingWaiters)
        }
        receiver?.resume(throwing: ClosedByClient())
        for waiter in pingWaiters { waiter.resume(throwing: ClosedByClient()) }
    }

    // MARK: - Private

    private func answer(_ request: Relay_V1_Request) {
        var response = Relay_V1_Response()
        response.id = request.id
        var answer = Answer.ok
        if case .subscribe(let subscribe) = request.op, let zone = subscribe.zones.first {
            answer = subscribeAnswers[zone] ?? .ok
        }
        switch answer {
        case .ok:
            response.ok = Relay_V1_Ok()
        case .error(let code):
            var error = Relay_V1_Error()
            error.code = code
            response.error = error
        case .silent:
            return
        }
        var frame = Relay_V1_Frame()
        frame.response = response
        push(frame)
    }

    private func deliver(_ message: RelaySocketMessage) {
        let receiver: CheckedContinuation<RelaySocketMessage, any Error>? = state.withLock { state in
            guard let receiver = state.receiver else {
                state.inbound.append(message)
                return nil
            }
            state.receiver = nil
            return receiver
        }
        receiver?.resume(returning: message)
    }
}

/// A `RelaySocketDialer` that hands out scripted sockets, one step per dial:
/// a socket, an HTTP status refusing the upgrade, or no answer. A dial with
/// nothing scripted gets a default `ScriptedRelaySocket`.
final class ScriptedRelayDialer: RelaySocketDialer, @unchecked Sendable {
    enum Step: Sendable {
        case socket(ScriptedRelaySocket)
        case http(Int)
        case unreachable
    }

    struct Dial: Sendable {
        let url: URL
        let headers: [String: String]
        let at: Date
        /// The socket this dial returned, nil when it failed.
        let socket: ScriptedRelaySocket?
    }

    private struct State {
        var steps: [Step] = []
        var dials: [Dial] = []
    }

    private let clock: any RelayClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(clock: any RelayClock) {
        self.clock = clock
    }

    func script(_ steps: [Step]) {
        state.withLock { $0.steps.append(contentsOf: steps) }
    }

    var dials: [Dial] {
        state.withLock { $0.dials }
    }

    /// The sockets dials returned, in order.
    var sockets: [ScriptedRelaySocket] {
        dials.compactMap(\.socket)
    }

    func waitForDials(_ count: Int) async {
        await spin { self.dials.count >= count }
    }

    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        let now = clock.now()
        let step: Step = state.withLock { state in
            state.steps.isEmpty ? .socket(ScriptedRelaySocket()) : state.steps.removeFirst()
        }
        var socket: ScriptedRelaySocket?
        if case .socket(let scripted) = step { socket = scripted }
        state.withLock { $0.dials.append(Dial(url: url, headers: headers, at: now, socket: socket)) }
        switch step {
        case .socket(let scripted):
            return scripted
        case .http(let status):
            throw RelayDialError.http(status: status)
        case .unreachable:
            throw RelayDialError.unreachable
        }
    }
}

/// Yields until `condition` holds, for at most 5 s of wall-clock time; past that
/// the test fails and this returns false.
@discardableResult
func spin(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("condition not met within 5 s", file: file, line: line)
            return false
        }
        await Task.yield()
    }
    return true
}

/// Reads a connection's events, each read capped like `spin`: a read that gets no
/// event within 5 s fails the test and returns nil (the read is cancelled).
/// `pump`, when given, runs on every wait step (a scenario moves its manual clock there).
final class EventProbe: @unchecked Sendable {
    private var iterator: AsyncStream<HostedRelayClientEvent>.Iterator
    private let pump: (@Sendable () -> Void)?

    init(_ connection: HostedRelayConnection, pump: (@Sendable () -> Void)? = nil) {
        iterator = connection.events.makeAsyncIterator()
        self.pump = pump
    }

    func next(file: StaticString = #filePath, line: UInt = #line) async -> HostedRelayClientEvent? {
        let result = OSAllocatedUnfairLock<HostedRelayClientEvent??>(initialState: nil)
        let read = Task {
            let event = await self.advance()
            result.withLock { $0 = .some(event) }
        }
        let ready = await spin(file: file, line: line) {
            if result.withLock({ $0 != nil }) { return true }
            pump?()
            return false
        }
        guard ready else {
            read.cancel()
            await read.value
            return nil
        }
        return result.withLock { $0 }.flatMap { $0 }
    }

    private func advance() async -> HostedRelayClientEvent? {
        await iterator.next()
    }
}
