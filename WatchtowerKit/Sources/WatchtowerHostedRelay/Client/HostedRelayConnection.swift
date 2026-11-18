import Foundation
import os
import SwiftProtobuf
import WatchtowerRelayProto

extension HostedRelayClient {
    /// Opens and keeps the socket: dial with Authorization → Hello{1, token} → HelloOk → subscribe each zone one by one.
    /// The connection runs until `close()` or a `.stopped` event: the caller must close it.
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
/// - on a wake (live link R6) the socket is pinged; with no pong within 300 ms a second socket is dialled while
///   the first may still pong, and whichever is ready first carries on (`probe`, `redialRace`);
/// - after every connect, each zone subscribed one by one (a refused zone is dropped and
///   reported), then a record-less `zoneChanged` per subscribed zone; a subscribe with no
///   answer within 10 s, or answered "try again later" (unavailable, a rate or traffic limit),
///   cuts the connection and keeps the zone, the redial on `defaultBackoff` of the cuts in a row;
/// - a login failing with `.notSupported` / `.updateRequired` → `.stopped(.attestation(…))`;
///   `.retryLater(after:)` → the next dial waits `max(after, defaultBackoff(attempt))`.
///
/// A connection must be closed: its loop keeps it alive (and keeps reconnecting) until
/// `close()` or a `.stopped` event, whether or not anyone still holds it.
public final class HostedRelayConnection: Sendable {
    static let handshakeTimeout = Duration.seconds(10)
    static let pingInterval = Duration.seconds(30)
    /// How long a wake's ping waits for its pong before a second socket is dialled (live link R6): a starting
    /// value, tuned from the phone's `wake_ms` samples.
    static let wakePingDeadline = Duration.milliseconds(300)
    static let closeNormal = 1000
    static let closeGoingAway = 1001
    static let closeUnsupportedVersion = 4000
    static let closeUnauthenticated = 4001
    /// How long a request waits for its answer after the write: the HTTPS client's request timeout.
    static let requestTimeout = Duration.seconds(URLSessionRelayHTTP.requestTimeout)

    private static var logger: Logger {
        HostedRelayClient.logger
    }

    private struct Live {
        let socket: any RelaySocket
        let generation: Int
    }

    /// A request waiting for its answer, on the socket generation it was written to.
    private struct Waiter {
        let continuation: CheckedContinuation<Relay_V1_Response, any Error>
        let generation: Int
    }

    /// A socket a wake's redial made live while the reconnect loop still serves the one it replaces: the loop
    /// serves it next, with no `disconnected` and no backoff in between.
    private struct Handover {
        let socket: any RelaySocket
        let generation: Int
        let token: String
    }

    private struct State {
        var zones: [String]
        var live: Live?
        var handover: Handover?
        var generation = 0
        var nextID: UInt64 = 0
        var pending: [UInt64: Waiter] = [:]
        var runner: Task<Void, Never>?
        var closed = false
    }

    /// Why one connection ended.
    private enum End: Sendable {
        case dropped, goingAway, sessionExpired, unsupportedVersion, closed
        /// A subscribe got no answer or a "try again later": cut, the zones kept.
        case subscribeCut
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

    /// Whether a socket is connected now (handshake done; zones may still be subscribing).
    var isLive: Bool {
        state.withLock { $0.live != nil }
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
        do {
            return try await request(op)
        } catch is SocketLoss {
            throw HostedRelayError.unreachable
        }
    }

    /// Why a socket request got no answer: what `send` reports as `.unreachable`, told apart for the
    /// session's fallback to HTTPS (`HostedRelaySession.send`).
    enum SocketLoss: Error, Equatable {
        /// Refused before its frame was handed to the socket (no live socket, or the socket was replaced):
        /// the op never reached the relay.
        case notSent
        /// The socket dropped, or failed the write, after the frame was handed to it: the op may have run.
        case lost
    }

    /// `send`, its lost answers as `SocketLoss`.
    func request(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response {
        try await HostedRelayClient.retryingUnavailable(op, clock: clock) {
            guard let live = state.withLock({ $0.live }) else { throw SocketLoss.notSent }
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
    /// Waits for a login already in flight before it returns: the shared login is not
    /// cancellable, and it includes the App Attest / DeviceCheck calls, which have no timeout
    /// of ours, besides its HTTPS requests (30 s each).
    public func close() async {
        let (runner, live, handover, pending) = state.withLock { state in
            state.closed = true
            defer {
                state.live = nil
                state.handover = nil
                state.pending = [:]
            }
            return (state.runner, state.live, state.handover, state.pending)
        }
        for waiter in pending.values { waiter.continuation.resume(throwing: SocketLoss.lost) }
        runner?.cancel()
        await live?.socket.close(code: Self.closeNormal)
        await handover?.socket.close(code: Self.closeNormal)
        await runner?.value
        buffer.finish()
    }

    // MARK: - The reconnect loop

    private func run() async {
        var attempt = 0
        /// Connections in a row cut by a subscribe: their backoff grows although each one
        /// reached `HelloOk` (a rate limit is not retried twice a second).
        var cuts = 0
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
                let (end, lastToken) = await serveHandingOver(socket, token: token)
                if end == .closed || isClosed { return }
                buffer.push(.disconnected)
                cuts = end == .subscribeCut ? cuts + 1 : 0
                switch end {
                case .unsupportedVersion:
                    return stop(.unsupportedVersion)
                case .goingAway:
                    wait = .milliseconds(Int.random(in: 1_000...3_000))
                case .sessionExpired:
                    // Only this connection's token: `perform` may already hold a newer one.
                    stale = lastToken
                    wait = backoff(0)
                case .subscribeCut:
                    wait = backoff(cuts - 1)
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

    /// Serves `socket`, then each socket a wake's redial handed over in its place, at once (no `disconnected`, no
    /// backoff); how the last one ended, and the token it was opened with.
    private func serveHandingOver(_ socket: any RelaySocket, token: String) async -> (End, token: String) {
        guard let generation = attach(socket) else {
            await socket.close(code: Self.closeNormal)
            return (.closed, token)
        }
        var current = Handover(socket: socket, generation: generation, token: token)
        var end = await serve(current.socket, generation: current.generation)
        while end != .closed, !isClosed, let next = takeHandover() {
            current = next
            end = await serve(current.socket, generation: current.generation)
        }
        return (end, current.token)
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
            let dialed = try await deadline(Self.handshakeTimeout, discard: Self.closeLateSocket) {
                try await self.dialer.dial(self.url, headers: headers)
            }
            guard let dialed else {
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

    /// Runs one open socket, live as `generation`, until it ends: the reader, the keepalive and the subscribes.
    private func serve(_ socket: any RelaySocket, generation: Int) async -> End {
        Self.logger.info("relay socket: connected")
        buffer.push(.connected)
        let zones = state.withLock { $0.zones }
        return await withTaskGroup(of: End?.self) { group in
            group.addTask { await self.read(socket) }
            group.addTask { await self.keepAlive(socket) }
            group.addTask { await self.subscribe(zones, on: socket, generation: generation) ? nil : .subscribeCut }
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

    // MARK: - Wake (live link R6)

    /// What decided a wake's redial race.
    private enum Redial: Sendable {
        /// The old socket answered its ping.
        case pong
        /// The second socket said `HelloOk` first.
        case opened(any RelaySocket, token: String)
        /// Neither within the handshake timeout.
        case timedOut
    }

    /// Pings the live socket; true when its pong comes within `limit`. False while disconnected, when the ping
    /// fails, or when the pong is late: the ping stays out (it is not cancellable), so `redialRace` can still
    /// see the old socket answer.
    func probe(deadline limit: Duration = wakePingDeadline) async -> Bool {
        guard let live = state.withLock({ $0.live }) else { return false }
        let clock = clock
        let answered = await Self.firstAnswer([
            {
                do {
                    try await live.socket.ping()
                    return true
                } catch {
                    return false
                }
            },
            {
                do { try await clock.sleep(for: limit) } catch { return nil }
                return false
            }
        ])
        return answered ?? false
    }

    /// The wake after a silent `probe`: a second socket is dialled (the session token reused while valid) while
    /// the old one is pinged again, and whichever is ready first carries on. A new socket that wins becomes live
    /// at once as the next generation (requests go to it from now; the old generation's waiters fail as lost
    /// when its socket ends) and the reconnect loop serves it next; the old socket is closed. An old socket that
    /// pongs first stays, and the dial is abandoned (a socket it still makes is closed). Neither within the
    /// handshake timeout: the old socket is closed (no pong in 10 s, the keepalive's rule) and the loop redials.
    /// Nothing while disconnected: the reconnect loop is already dialling.
    func redialRace() async {
        guard let old = state.withLock({ $0.closed ? nil : $0.live }) else { return }
        let clock = clock
        let racers: [@Sendable () async -> Redial?] = [
            {
                do {
                    try await old.socket.ping()
                    return .pong
                } catch {
                    return nil
                }
            },
            {
                guard case let .open(socket, token) = await self.handshake(stale: nil) else { return nil }
                return Redial.opened(socket, token: token)
            },
            {
                do { try await clock.sleep(for: Self.handshakeTimeout) } catch { return nil }
                return .timedOut
            }
        ]
        let winner = await Self.firstAnswer(racers, endsAfterNils: 2) { late in
            if case .opened(let socket, _) = late { await socket.close(code: Self.closeNormal) }
        }
        switch winner {
        case .pong?:
            Self.logger.info("relay socket: wake, the socket answered")
        case let .opened(socket, token)?:
            guard handOver(socket, token: token, replacing: old.generation) else {
                await socket.close(code: Self.closeNormal)
                return
            }
            Self.logger.info("relay socket: wake, a second socket was ready first")
            await old.socket.close(code: Self.closeNormal)
        case .timedOut?, nil:
            Self.logger.error("relay socket: wake, no pong and no second socket, reconnecting")
            await old.socket.close(code: Self.closeNormal)
        }
    }

    /// Makes `socket` live as the next generation in place of `generation`, for the reconnect loop to serve once
    /// the replaced socket's serve ends. False when `generation` is no longer the live one or the connection closed.
    private func handOver(_ socket: any RelaySocket, token: String, replacing generation: Int) -> Bool {
        state.withLock { state in
            guard !state.closed, state.live?.generation == generation else { return false }
            state.generation += 1
            state.live = Live(socket: socket, generation: state.generation)
            state.handover = Handover(socket: socket, generation: state.generation, token: token)
            return true
        }
    }

    private func takeHandover() -> Handover? {
        state.withLock { state in
            defer { state.handover = nil }
            return state.handover
        }
    }

    /// `firstAnswer`'s state: its caller, whether the race is decided, and how many racers answered nil.
    private struct Answering<T: Sendable> {
        var continuation: CheckedContinuation<T?, Never>?
        var decided = false
        var nils = 0
    }

    /// The first non-nil answer of `racers`, each run in a task of its own; nil once `endsAfterNils` of them
    /// answered nil (or the caller is cancelled). The others are cancelled then, and not awaited: a ping is not
    /// cancellable. A non-nil answer that comes after the race was decided goes to `discard`.
    private static func firstAnswer<T: Sendable>(
        _ racers: [@Sendable () async -> T?],
        endsAfterNils: Int? = nil,
        discard: @escaping @Sendable (T) async -> Void = { _ in }
    ) async -> T? {
        let needed = endsAfterNils ?? racers.count
        let race = OSAllocatedUnfairLock(initialState: Answering<T>())
        let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
        @Sendable func decide(_ answer: T?) -> Bool {
            let continuation: CheckedContinuation<T?, Never>? = race.withLock { race in
                if answer == nil { race.nils += 1 }
                guard !race.decided, answer != nil || race.nils >= needed else { return nil }
                race.decided = true
                defer { race.continuation = nil }
                return race.continuation
            }
            continuation?.resume(returning: answer)
            return continuation != nil
        }
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let cancelled = race.withLock { race in
                    if race.decided { return true }
                    race.continuation = continuation
                    return false
                }
                if cancelled { return continuation.resume(returning: nil) }
                let started = racers.map { racer in
                    Task {
                        let answer = await racer()
                        if !decide(answer), let answer { await discard(answer) }
                    }
                }
                tasks.withLock { $0 = started }
            }
        } onCancel: {
            let continuation = race.withLock { race -> CheckedContinuation<T?, Never>? in
                guard !race.decided else { return nil }
                race.decided = true
                defer { race.continuation = nil }
                return race.continuation
            }
            continuation?.resume(returning: nil)
        }
        tasks.withLock { $0.forEach { $0.cancel() } }
        return answer
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

    /// A relay answer that refuses the zone. "Try again later" (unavailable, a rate or traffic
    /// limit), a lost connection, a session or version problem are about the connection, not
    /// the zone: cut it and keep the zone, so no zone goes quiet for good.
    private static func refuses(_ error: HostedRelayError) -> Bool {
        switch error {
        case .server(code: .unavailable, _), .server(code: .rateLimited, _), .server(code: .trafficLimitExceeded, _),
             .server(code: .unauthenticated, _), .unreachable, .unsupportedVersion:
            return false
        default:
            return true
        }
    }

    // MARK: - Requests

    /// One `Request` frame on `socket`, answered by id. `SocketLoss.notSent` when the socket is no
    /// longer the live one, `.lost` when it drops (or fails the write) before the answer, or when no
    /// answer comes within `requestTimeout` (a relay that still pongs but never answers, or a write that
    /// never returns): the socket is then retired (`expire`).
    private func roundTrip(_ op: Relay_V1_Request.OneOf_Op, on socket: any RelaySocket, generation: Int) async throws -> Relay_V1_Response {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        var frame = Relay_V1_Frame()
        frame.request.id = id
        frame.request.op = op
        let data = try frame.serializedData()
        // The request's deadline and its write, both cancelled once it is answered, failed or cancelled.
        let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
        defer { tasks.withLock { $0.forEach { $0.cancel() } } }
        let response: Relay_V1_Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let refusal: (any Error)? = state.withLock { state in
                    if Task.isCancelled { return CancellationError() }
                    guard state.live?.generation == generation else { return SocketLoss.notSent }
                    state.pending[id] = Waiter(continuation: continuation, generation: generation)
                    return nil
                }
                if let refusal { return continuation.resume(throwing: refusal) }
                // Started before the write, so a write that never returns is covered too.
                let timer = Task {
                    do { try await self.clock.sleep(for: Self.requestTimeout) } catch { return }
                    await self.expire(id, op: op, socket: socket, generation: generation)
                }
                let writer = Task {
                    guard !Task.isCancelled else { return }
                    do {
                        try await socket.send(data)
                    } catch {
                        self.fail(id, with: SocketLoss.lost)
                    }
                }
                tasks.withLock { $0 += [timer, writer] }
            }
        } onCancel: {
            fail(id, with: CancellationError())
        }
        if case .error(let error) = response.result { throw HostedRelayClient.error(error) }
        return response
    }

    private func resolve(_ response: Relay_V1_Response) {
        let waiter = state.withLock { $0.pending.removeValue(forKey: response.id) }
        waiter?.continuation.resume(returning: response)
    }

    /// Fails request `id`; false when it was already answered or failed.
    @discardableResult
    private func fail(_ id: UInt64, with error: any Error) -> Bool {
        guard let waiter = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return false }
        waiter.continuation.resume(throwing: error)
        return true
    }

    /// Request `id` got no answer within `requestTimeout`: it is lost (it may have run), and the socket is
    /// retired, since a relay that pongs but never answers would hold every later request for as long.
    /// The connection redials; until then a request is refused before its write (`.notSent`). The socket
    /// stops being live in the same step that takes the requests of its generation, and is closed before any
    /// of them is resumed, so a caller sending again at once is refused (`.notSent`) rather than written to it.
    private func expire(_ id: UInt64, op: Relay_V1_Request.OneOf_Op, socket: any RelaySocket, generation: Int) async {
        let retired: [Waiter]? = state.withLock { state in
            guard state.pending[id] != nil else { return nil }
            return Self.retire(generation, in: &state)
        }
        guard let retired else { return }
        Self.logger.error("relay socket: \(HostedRelayClient.name(op), privacy: .public) got no answer in time, reconnecting")
        await socket.close(code: Self.closeNormal)
        for waiter in retired { waiter.continuation.resume(throwing: SocketLoss.lost) }
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

    /// Forgets the socket of `generation` and fails the requests written to it; a newer socket's requests
    /// stay. Internal for tests.
    func detach(_ generation: Int) {
        let retired = state.withLock { Self.retire(generation, in: &$0) }
        for waiter in retired { waiter.continuation.resume(throwing: SocketLoss.lost) }
    }

    /// `generation` stops being live, and its waiters leave `pending` (lock held): the caller resumes them.
    private static func retire(_ generation: Int, in state: inout State) -> [Waiter] {
        if state.live?.generation == generation { state.live = nil }
        let ids = state.pending.filter { $0.value.generation == generation }.map(\.key)
        return ids.compactMap { state.pending.removeValue(forKey: $0) }
    }

    /// The live socket's generation, nil while disconnected. Internal for tests.
    var liveGeneration: Int? {
        state.withLock { $0.live?.generation }
    }

    /// `body`, or nil when `limit` passes on the clock first. Whenever `body` did not finish
    /// (timeout, error, cancellation), `closing` is closed before the group waits for `body`:
    /// a socket read or ping is not cancellable, the close is what makes it return. A value
    /// `body` still produces after the timeout won goes to `discard` (a dialed socket is closed).
    private func deadline<T: Sendable>(
        _ limit: Duration,
        closing socket: (any RelaySocket)? = nil,
        discard: (@Sendable (T) async -> Void)? = nil,
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
            group.cancelAll()
            while let late = try? await group.next() {
                if case .done(let value) = late { await discard?(value) }
            }
            return nil
        }
    }

    /// Closes a socket the dial produced after its deadline had already passed.
    private static let closeLateSocket: @Sendable (any RelaySocket) async -> Void = { socket in
        await socket.close(code: closeNormal)
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
