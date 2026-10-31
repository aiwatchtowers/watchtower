import Foundation
import os
import SwiftProtobuf
import WatchtowerRelayProto

extension HostedRelayClient {
    /// Opens and keeps the socket: dial with Authorization → Hello{1, token} → HelloOk → subscribe each zone one by one.
    /// The connection runs until `close()` or a `.stopped` event.
    public func connect(zones: [String], eventBuffer: Int = 256) -> HostedRelayConnection {
        let connection = HostedRelayConnection(client: self, url: socketURL, zones: zones, eventBuffer: eventBuffer)
        connection.start()
        return connection
    }
}

/// The client's WebSocket that survives drops (the Go `client.Conn`; relay
/// `proto/README.md` "WebSocket"):
/// - HTTP 401 at the upgrade or close 4001 after `Hello` → one login, one redial at once;
/// - close 4001 mid-connection (after `Control{SESSION_EXPIRED}` or alone) → the token
///   this connection used is replaced by a login, then reconnect;
/// - close 1001, with or without a `GoingAway` frame → `onGoingAway` once, reconnect after a uniform 1–3 s;
/// - close 4000 → `.stopped(.unsupportedVersion)`, no more dials;
/// - 4008, 1006, 1011, a failed dial or a dead socket → `defaultBackoff(attempt)`, the attempt
///   reset by a connection that reached `HelloOk`;
/// - a ping every 30 s while open; no pong within 10 s closes and reconnects;
/// - after every connect, each zone subscribed one by one (a refused zone is dropped and
///   reported), then a record-less `zoneChanged` per subscribed zone; a subscribe with no
///   answer within 10 s cuts the connection;
/// - a login failing with `.notSupported` / `.updateRequired` → `.stopped(.attestation(…))`;
///   `.retryLater(after:)` → the next dial waits `max(after, defaultBackoff(attempt))`.
public final class HostedRelayConnection: Sendable {
    static let handshakeTimeout = Duration.seconds(10)
    static let pingInterval = Duration.seconds(30)
    static let closeNormal = 1000
    static let closeGoingAway = 1001
    static let closeUnsupportedVersion = 4000
    static let closeUnauthenticated = 4001

    private static var logger: Logger {
        HostedRelayClient.logger
    }

    private struct Live {
        let socket: any RelaySocket
        let generation: Int
    }

    private struct State {
        var zones: [String]
        var live: Live?
        var generation = 0
        var nextID: UInt64 = 0
        var pending: [UInt64: CheckedContinuation<Relay_V1_Response, any Error>] = [:]
        var runner: Task<Void, Never>?
        var closed = false
    }

    /// Why one connection ended.
    private enum End: Sendable {
        case dropped, goingAway, sessionExpired, unsupportedVersion, closed
    }

    private enum Handshake: Sendable {
        case open(any RelaySocket, token: String)
        /// `refused`: the token the relay refused twice in a row, so the next attempt logs in.
        case retry(after: Duration?, refused: String?)
        case stop(HostedRelayError)
        case closed
    }

    private enum Opening: Sendable {
        case open(any RelaySocket)
        case unauthenticated, unsupportedVersion, failed
    }

    private enum Race<T: Sendable>: Sendable {
        case done(T)
        case timedOut
    }

    private let client: HostedRelayClient
    private let url: URL
    private let dialer: any RelaySocketDialer
    private let clock: any RelayClock
    private let backoff: @Sendable (Int) -> Duration
    private let onGoingAway: (@Sendable () -> Void)?
    private let buffer: RelayEventBuffer
    private let stream: AsyncStream<HostedRelayClientEvent>
    private let state: OSAllocatedUnfairLock<State>

    init(client: HostedRelayClient, url: URL, zones: [String], eventBuffer: Int) {
        self.client = client
        self.url = url
        self.dialer = client.sockets
        self.clock = client.clock
        self.backoff = client.backoff
        self.onGoingAway = client.onGoingAway
        let buffer = RelayEventBuffer(capacity: eventBuffer)
        self.buffer = buffer
        self.stream = AsyncStream { await buffer.next() }
        self.state = OSAllocatedUnfairLock(initialState: State(zones: Self.unique(zones)))
    }

    /// The connection's events, for one reader. Ends after `close()` or `.stopped`.
    public var events: AsyncStream<HostedRelayClientEvent> {
        stream
    }

    func start() {
        let runner = Task { await self.run() }
        state.withLock { $0.runner = runner }
    }

    // MARK: - Public

    /// A Request over the socket, answered by id; UNAVAILABLE retried like `perform`.
    /// `.unreachable` while disconnected, or when the connection drops before the answer
    /// (the request may or may not have run).
    public func send(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response {
        try await HostedRelayClient.retryingUnavailable(op, clock: clock) {
            guard let live = state.withLock({ $0.live }) else { throw HostedRelayError.unreachable }
            return try await roundTrip(op, on: live.socket, generation: live.generation)
        }
    }

    /// Replaces the zone set. New zones are subscribed now when connected (one by one, as
    /// after a connect); every connect subscribes the whole set. There is no unsubscribe:
    /// a removed zone stays subscribed on the relay until the next connect, its events unreported.
    public func setZones(_ zones: [String]) async {
        let (added, live) = state.withLock { state in
            let wanted = Self.unique(zones)
            let added = wanted.filter { !state.zones.contains($0) }
            state.zones = wanted
            return (added, state.live)
        }
        guard let live, !added.isEmpty else { return }
        let subscribed = await subscribe(added, on: live.socket, generation: live.generation)
        if !subscribed { await live.socket.close(code: Self.closeNormal) }
    }

    /// Closes the connection for good; the events stream ends after what is queued.
    public func close() async {
        let (runner, live, pending) = state.withLock { state in
            state.closed = true
            defer {
                state.live = nil
                state.pending = [:]
            }
            return (state.runner, state.live, state.pending)
        }
        for waiter in pending.values { waiter.resume(throwing: HostedRelayError.unreachable) }
        runner?.cancel()
        await live?.socket.close(code: Self.closeNormal)
        await runner?.value
        buffer.finish()
    }

    // MARK: - The reconnect loop

    private func run() async {
        var attempt = 0
        var wait: Duration?
        var stale: String?
        while !isClosed {
            if let wait {
                Self.logger.info("relay socket: reconnecting in \(wait.components.seconds, privacy: .public) s, attempt \(attempt, privacy: .public)")
                do { try await clock.sleep(for: wait) } catch { return }
            }
            switch await handshake(stale: stale) {
            case let .open(socket, token):
                stale = nil
                let end = await serve(socket)
                if end == .closed || isClosed { return }
                buffer.push(.disconnected)
                switch end {
                case .unsupportedVersion:
                    return stop(.unsupportedVersion)
                case .goingAway:
                    wait = .milliseconds(Int.random(in: 1_000...3_000))
                case .sessionExpired:
                    // Only this connection's token: `perform` may already hold a newer one.
                    stale = token
                    wait = backoff(0)
                case .dropped, .closed:
                    wait = backoff(0)
                }
                attempt = 1
            case let .retry(after, refused):
                if let refused { stale = refused }
                wait = max(after ?? .zero, backoff(attempt))
                attempt += 1
            case .stop(let error):
                return stop(error)
            case .closed:
                return
            }
        }
    }

    /// A session token and a socket that said `HelloOk`. A token the relay refuses
    /// (401 or 4001) gets one login and one immediate redial.
    private func handshake(stale: String?) async -> Handshake {
        var stale = stale
        var refusedOnce = false
        while true {
            let token: String
            do {
                token = try await client.sessionToken(stale: stale)
            } catch {
                return loginFailure(error)
            }
            switch await open(token) {
            case .open(let socket):
                return .open(socket, token: token)
            case .unauthenticated:
                Self.logger.info("relay socket: session refused, logging in again")
                if refusedOnce { return .retry(after: nil, refused: token) }
                refusedOnce = true
                stale = token
            case .unsupportedVersion:
                return .stop(.unsupportedVersion)
            case .failed:
                return isClosed ? .closed : .retry(after: nil, refused: nil)
            }
        }
    }

    private func loginFailure(_ error: any Error) -> Handshake {
        if isClosed || error is CancellationError { return .closed }
        Self.logger.error("relay socket: login failed, \(String(describing: error as? HostedRelayError), privacy: .public)")
        switch error as? HostedRelayError {
        case .unsupportedVersion?:
            return .stop(.unsupportedVersion)
        case .attestation(.retryLater(let after))?:
            return .retry(after: after, refused: nil)
        case .attestation(let outcome)?:
            return .stop(.attestation(outcome))
        default:
            return .retry(after: nil, refused: nil)
        }
    }

    /// Dial, `Hello`, `HelloOk`, each step within the 10 s handshake timeout.
    private func open(_ token: String) async -> Opening {
        let socket: any RelaySocket
        do {
            let headers = ["Authorization": "Bearer \(token)"]
            guard let dialed = try await deadline(Self.handshakeTimeout, { try await self.dialer.dial(self.url, headers: headers) }) else {
                Self.logger.error("relay socket: dial timed out")
                return .failed
            }
            socket = dialed
        } catch RelayDialError.http(status: 401) {
            return .unauthenticated
        } catch {
            Self.logger.error("relay socket: dial failed, \(String(describing: error as? RelayDialError), privacy: .public)")
            return .failed
        }

        var frame = Relay_V1_Frame()
        frame.hello.protocolVersion = HostedRelay.protocolVersion
        frame.hello.sessionToken = token
        let opening: Opening?
        do {
            let hello = try frame.serializedData()
            opening = try await deadline(Self.handshakeTimeout, closing: socket) {
                try await socket.send(hello)
                return try await Self.helloAnswer(socket)
            }
        } catch {
            opening = nil
        }
        if case .open? = opening { return .open(socket) }
        await socket.close(code: Self.closeNormal)
        return opening ?? .failed
    }

    /// Reads until `HelloOk` or a close. An error `Response` before the close
    /// (unsupported version) is followed by the close frame.
    private static func helloAnswer(_ socket: any RelaySocket) async throws -> Opening {
        while true {
            switch try await socket.receive() {
            case .closed(code: closeUnauthenticated):
                return .unauthenticated
            case .closed(code: closeUnsupportedVersion):
                return .unsupportedVersion
            case .closed(let code):
                logger.error("relay socket: closed at hello, \(code, privacy: .public)")
                return .failed
            case .binary(let data):
                if case .helloOk? = (try? Relay_V1_Frame(serializedBytes: data))?.kind { return .open(socket) }
            }
        }
    }

    private func stop(_ error: HostedRelayError) {
        Self.logger.error("relay socket: stopped, \(String(describing: error), privacy: .public)")
        state.withLock { $0.closed = true }
        buffer.push(.stopped(error))
        buffer.finish()
    }

    // MARK: - One connection

    /// Runs one open socket until it ends: the reader, the keepalive and the subscribes.
    private func serve(_ socket: any RelaySocket) async -> End {
        guard let generation = attach(socket) else {
            await socket.close(code: Self.closeNormal)
            return .closed
        }
        Self.logger.info("relay socket: connected")
        buffer.push(.connected)
        let zones = state.withLock { $0.zones }
        return await withTaskGroup(of: End?.self) { group in
            group.addTask { await self.read(socket) }
            group.addTask { await self.keepAlive(socket) }
            group.addTask { await self.subscribe(zones, on: socket, generation: generation) ? nil : .dropped }
            var end = End.dropped
            for await result in group {
                if let result {
                    end = result
                    break
                }
            }
            detach(generation)
            await socket.close(code: Self.closeNormal)
            group.cancelAll()
            return end
        }
    }

    /// Reads frames until the socket ends and says why. 1001 is GoingAway whether or not a
    /// `GoingAway` frame came first; `onGoingAway` runs once per connection either way.
    private func read(_ socket: any RelaySocket) async -> End {
        var reason = End.dropped
        var announced = false
        func goingAway() {
            reason = .goingAway
            if !announced { onGoingAway?() }
            announced = true
        }
        while true {
            let message: RelaySocketMessage
            do {
                message = try await socket.receive()
            } catch {
                return isClosed ? .closed : reason
            }
            switch message {
            case .closed(let code):
                if isClosed { return .closed }
                Self.logger.info("relay socket: closed \(code, privacy: .public)")
                switch code {
                case Self.closeUnauthenticated:
                    return .sessionExpired
                case Self.closeUnsupportedVersion:
                    return .unsupportedVersion
                case Self.closeGoingAway:
                    goingAway()
                    return .goingAway
                default:
                    return reason
                }
            case .binary(let data):
                guard let frame = try? Relay_V1_Frame(serializedBytes: data) else { continue }
                switch handle(frame) {
                case .goingAway?:
                    goingAway()
                case .some(let signal):
                    reason = signal
                case nil:
                    break
                }
            }
        }
    }

    /// One frame from the relay; returns what it says about how the connection will end.
    private func handle(_ frame: Relay_V1_Frame) -> End? {
        switch frame.kind {
        case .response(let response):
            resolve(response)
        case .goingAway:
            return .goingAway
        case .event(let event):
            switch event.kind {
            case .control(let control) where control.kind == .sessionExpired:
                return .sessionExpired
            case .control(let control):
                buffer.push(.control(kind: control.kind, detail: control.detail))
            case .zoneChanged(let changed):
                if wants(changed.zone) { buffer.zoneChanged(changed.zone, seq: changed.seq) }
            case nil:
                break
            }
        default:
            break
        }
        return nil
    }

    /// A ping every 30 s; `.dropped` when one gets no pong within 10 s.
    private func keepAlive(_ socket: any RelaySocket) async -> End? {
        while true {
            do {
                try await clock.sleep(for: Self.pingInterval)
            } catch {
                return nil
            }
            do {
                // A ping is not cancellable: closing the socket is what ends a missing pong.
                let pong = try await deadline(Self.handshakeTimeout, closing: socket) {
                    try await socket.ping()
                }
                if pong != nil { continue }
                Self.logger.error("relay socket: no pong within 10 s")
            } catch {
                if Task.isCancelled || isClosed { return nil }
                Self.logger.error("relay socket: ping failed")
            }
            return .dropped
        }
    }

    /// Subscribes `zones` one at a time. A refused zone is dropped and reported; the others
    /// are owed a record-less `zoneChanged`. False when a subscribe got no answer in 10 s
    /// (or the socket went away): the caller cuts the connection.
    private func subscribe(_ zones: [String], on socket: any RelaySocket, generation: Int) async -> Bool {
        for zone in zones where wants(zone) {
            var request = Relay_V1_Subscribe()
            request.zones = [zone]
            let op = Relay_V1_Request.OneOf_Op.subscribe(request)
            do {
                let answered = try await deadline(Self.handshakeTimeout) {
                    try await self.roundTrip(op, on: socket, generation: generation)
                }
                guard answered != nil else {
                    Self.logger.error("relay socket: subscribe \(Self.kind(of: zone), privacy: .public) got no answer")
                    return false
                }
                buffer.owe(zone)
            } catch let error as HostedRelayError where Self.refuses(error) {
                state.withLock { $0.zones.removeAll { $0 == zone } }
                Self.logger.error(
                    "relay socket: subscribe \(Self.kind(of: zone), privacy: .public) refused, \(String(describing: error), privacy: .public)"
                )
                buffer.push(.zoneRefused(zone: zone, error: error))
            } catch {
                return false
            }
        }
        return true
    }

    /// A relay answer that refuses the zone (not "try again later" and not a lost connection).
    private static func refuses(_ error: HostedRelayError) -> Bool {
        switch error {
        case .server(code: .unavailable, _), .unreachable:
            return false
        default:
            return true
        }
    }

    // MARK: - Requests

    /// One `Request` frame on `socket`, answered by id. `.unreachable` when the socket is no
    /// longer the live one or drops before the answer.
    private func roundTrip(_ op: Relay_V1_Request.OneOf_Op, on socket: any RelaySocket, generation: Int) async throws -> Relay_V1_Response {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        var frame = Relay_V1_Frame()
        frame.request.id = id
        frame.request.op = op
        let data = try frame.serializedData()
        let response: Relay_V1_Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let refusal: (any Error)? = state.withLock { state in
                    if Task.isCancelled { return CancellationError() }
                    guard state.live?.generation == generation else { return HostedRelayError.unreachable }
                    state.pending[id] = continuation
                    return nil
                }
                if let refusal { return continuation.resume(throwing: refusal) }
                Task {
                    do {
                        try await socket.send(data)
                    } catch {
                        self.fail(id, with: HostedRelayError.unreachable)
                    }
                }
            }
        } onCancel: {
            fail(id, with: CancellationError())
        }
        if case .error(let error) = response.result { throw HostedRelayClient.error(error) }
        return response
    }

    private func resolve(_ response: Relay_V1_Response) {
        let waiter = state.withLock { $0.pending.removeValue(forKey: response.id) }
        waiter?.resume(returning: response)
    }

    private func fail(_ id: UInt64, with error: any Error) {
        let waiter = state.withLock { $0.pending.removeValue(forKey: id) }
        waiter?.resume(throwing: error)
    }

    // MARK: - State

    private var isClosed: Bool {
        state.withLock { $0.closed }
    }

    private func wants(_ zone: String) -> Bool {
        state.withLock { $0.zones.contains(zone) }
    }

    /// Makes `socket` the live one; nil once the connection is closed.
    private func attach(_ socket: any RelaySocket) -> Int? {
        state.withLock { state in
            guard !state.closed else { return nil }
            state.generation += 1
            state.live = Live(socket: socket, generation: state.generation)
            return state.generation
        }
    }

    /// Forgets the live socket and fails the requests waiting on it.
    private func detach(_ generation: Int) {
        let pending = state.withLock { state in
            if state.live?.generation == generation { state.live = nil }
            defer { state.pending = [:] }
            return state.pending
        }
        for waiter in pending.values { waiter.resume(throwing: HostedRelayError.unreachable) }
    }

    /// `body`, or nil when `limit` passes on the clock first. Whenever `body` did not finish
    /// (timeout, error, cancellation), `closing` is closed before the group waits for `body`:
    /// a socket read or ping is not cancellable, the close is what makes it return.
    private func deadline<T: Sendable>(
        _ limit: Duration,
        closing socket: (any RelaySocket)? = nil,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: Race<T>.self) { group in
            group.addTask { .done(try await body()) }
            group.addTask {
                try await self.clock.sleep(for: limit)
                return .timedOut
            }
            defer { group.cancelAll() }
            do {
                if case .done(let value)? = try await group.next() { return value }
            } catch {
                await socket?.close(code: Self.closeNormal)
                throw error
            }
            await socket?.close(code: Self.closeNormal)
            return nil
        }
    }

    /// The zone's kind (`hub`, `mailbox`, `pair`, ...) for logs: never its ids.
    private static func kind(of zone: String) -> String {
        String(zone.prefix { $0 != "/" })
    }

    private static func unique(_ zones: [String]) -> [String] {
        var seen = Set<String>()
        return zones.filter { seen.insert($0).inserted }
    }
}
