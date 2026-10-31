import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerRelayProto

/// The fake on the client's network seams: `POST /v1/op` and the blob URLs through `http`,
/// `GET /v1/ws` through `sockets` (README "Transports"; Worker `http/op.ts`, `http/blob.ts`,
/// `do/device/ws.ts`, `do/zone/fanout.ts`). Everything answers at once: an op runs under the
/// fake's lock and its answer, events and closes are queued on the socket before `send` returns.
extension FakeHostedRelay {
    public var http: any RelayHTTP {
        FakeRelayHTTP(relay: self)
    }

    public var sockets: any RelaySocketDialer {
        FakeRelayDialer(relay: self)
    }

    static let closeGoingAway = 1001
    static let closePolicyViolation = 1008
    static let closeUnsupportedVersion = 4000
    static let closeUnauthenticated = 4001
    /// Worker `fanout.ts` `MAX_INLINE_RECORD_BYTES`: the largest envelope an event carries.
    static let maxInlineRecordBytes = 64 << 10

    // MARK: - HTTPS

    /// README "HTTP status": 400 + `UNSUPPORTED_VERSION` without `Relay-Protocol-Version: 1`,
    /// 400 + `ERROR_CODE_UNSPECIFIED` for a body that is not a `Request`, else `respond`.
    func post(_ url: URL, body: Data, headers: [String: String]) throws -> (status: Int, body: Data) {
        try locked {
            guard !state.faults.crashed else { throw URLError(.cannotConnectToHost) }
            guard url.path == "/v1/op" else { return (404, Data()) }
            var answer: (status: Int, response: Relay_V1_Response)
            if headers["Relay-Protocol-Version"] != String(HostedRelay.protocolVersion) {
                answer = (400, Self.failure(.unsupportedVersion, "unsupported protocol version"))
            } else if let request = try? Relay_V1_Request(serializedBytes: body) {
                answer = respond(request, bearer: Self.bearer(headers))
            } else {
                answer = (400, Self.failure(.unspecified, "invalid request"))
            }
            return (answer.status, try answer.response.serializedData())
        }
    }

    /// Worker `blob.ts` PUT: the URL's attachment (404 when it is gone), before its upload URL
    /// expires (403), exactly the declared size (413 longer, 400 shorter).
    func putBlob(_ url: URL, _ data: Data) throws -> Int {
        try locked {
            guard !state.faults.crashed else { throw URLError(.cannotConnectToHost) }
            guard let id = Self.blobID(url), let attachment = attachment(id) else { return 404 }
            guard now <= attachment.writableUntil else { return 403 }
            if data.count > attachment.size { return 413 }
            if data.count < attachment.size { return 400 }
            state.blobs[id] = data
            return 200
        }
    }

    /// Worker `blob.ts` GET: the bytes of a committed attachment no record write dropped, else 404.
    func getBlob(_ url: URL) throws -> (status: Int, data: Data?) {
        try locked {
            guard !state.faults.crashed else { throw URLError(.cannotConnectToHost) }
            guard let id = Self.blobID(url), attachment(id)?.committed == true, let data = state.blobs[id] else { return (404, nil) }
            return (200, data)
        }
    }

    private func attachment(_ id: String) -> Zone.Attachment? {
        state.zones.values.lazy.compactMap { $0.attachments[id] }.first
    }

    private static func blobID(_ url: URL) -> String? {
        let prefix = "/v1/blob/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let id = String(url.path.dropFirst(prefix.count))
        return id.isEmpty || id.contains("/") ? nil : id
    }

    static func bearer(_ headers: [String: String]) -> String? {
        guard let value = headers["Authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }

    // MARK: - WebSocket

    /// Worker `ws.ts` `accept`: 401 unless the bearer is a live session; then every earlier
    /// socket of the device is displaced (`GoingAway`, 1001) and this one waits for `Hello`.
    func dial(_ url: URL, headers: [String: String]) throws -> FakeRelaySocket {
        try locked {
            guard !state.faults.crashed else { throw RelayDialError.unreachable }
            if !state.faults.dialRefusals.isEmpty { throw RelayDialError.http(status: state.faults.dialRefusals.removeFirst()) }
            guard url.path == "/v1/ws" else { throw RelayDialError.http(status: 404) }
            guard let token = Self.bearer(headers), let session = holding(token) else { throw RelayDialError.http(status: 401) }
            for earlier in state.sockets where earlier.deviceID == session.deviceID { goAway(earlier) }
            let socket = FakeRelaySocket(relay: self, deviceID: session.deviceID, token: token)
            state.sockets.append(socket)
            return socket
        }
    }

    /// A frame from the client (`send`). A socket the server already closed ignores it.
    func receive(_ data: Data, on socket: FakeRelaySocket) {
        locked {
            guard state.sockets.contains(where: { $0 === socket }) else { return }
            guard let frame = try? Relay_V1_Frame(serializedBytes: data) else { return close(socket, code: Self.closePolicyViolation) }
            guard socket.hello else { return hello(frame, on: socket) }
            guard case .request(let request) = frame.kind else { return close(socket, code: Self.closePolicyViolation) }
            // Expired or revoked: every frame ends the connection.
            guard let session = holding(socket.token) else { return expire(socket) }
            var response: Relay_V1_Response
            switch request.op {
            case .register(let op)?:
                state.log.append(.register(op))
                response = Self.publicOnSocket
            case .challenge(let op)?:
                state.log.append(.challenge(op))
                response = Self.publicOnSocket
            case .login(let op)?:
                state.log.append(.login(op))
                response = Self.publicOnSocket
            case .subscribe(let subscribe)?:
                state.log.append(.subscribe(subscribe))
                guard let answer = self.subscribe(subscribe.zones, session, on: socket) else { return }
                response = answer
            default:
                response = respond(request, bearer: socket.token).response
            }
            response.id = request.id
            var out = Relay_V1_Frame()
            out.response = response
            socket.deliver(out)
        }
    }

    private static var publicOnSocket: Relay_V1_Response {
        failure(.unspecified, "register, challenge and login: use POST /v1/op")
    }

    /// The client closed its socket: it stops getting frames.
    func forget(_ socket: FakeRelaySocket) {
        locked { state.sockets.removeAll { $0 === socket } }
    }

    /// Worker `ws.ts` `hello`: the protocol version (else an error `Response` and 4000), the
    /// upgrade's token still holding (else 4001), then `HelloOk`.
    private func hello(_ frame: Relay_V1_Frame, on socket: FakeRelaySocket) {
        guard case .hello(let hello) = frame.kind else { return close(socket, code: Self.closePolicyViolation) }
        guard hello.protocolVersion == HostedRelay.protocolVersion else {
            var out = Relay_V1_Frame()
            out.response = Self.failure(.unsupportedVersion, "unsupported protocol version")
            socket.deliver(out)
            return close(socket, code: Self.closeUnsupportedVersion)
        }
        guard hello.sessionToken == socket.token, holding(socket.token) != nil else {
            return close(socket, code: Self.closeUnauthenticated)
        }
        socket.hello = true
        var out = Relay_V1_Frame()
        out.helloOk.connectionID = socket.connectionID
        socket.deliver(out)
    }

    /// Worker `ws.ts` `subscribe`: every zone must pass the read check, or none is added.
    /// Nil when `silenceSubscribe` swallows the answer.
    private func subscribe(_ zones: [String], _ session: Session, on socket: FakeRelaySocket) -> Relay_V1_Response? {
        if zones.contains(where: state.faults.silenced.contains) {
            state.faults.silenced.subtract(zones)
            return nil
        }
        if let code = takeFault("subscribe") { return Self.failure(code, "injected fault") }
        for zone in zones {
            do {
                try access(zone, session, .read)
            } catch let failure as RelayFailure {
                return Self.failure(failure.code, failure.message)
            } catch {
                return Self.failure(.unspecified, "internal error")
            }
        }
        socket.subscriptions.formUnion(zones)
        return Self.okResponse()
    }

    // MARK: - Fan-out

    /// The seq of every zone `op` may write, before it runs (lock held).
    func zoneSeqs(_ op: Relay_V1_Request.OneOf_Op?) -> [String: UInt64] {
        let zones: [String]
        switch op {
        case .save(let save)?: zones = save.items.map(\.record.zone)
        case .delete(let delete)?: zones = [delete.zone]
        default: zones = []
        }
        return Dictionary(zones.map { ($0, state.zones[$0]?.lastSeq ?? 0) }) { first, _ in first }
    }

    /// Worker `fanout.ts`: a `ZoneChanged` for every zone whose seq moved, carrying the record
    /// when the write produced exactly one and its envelope fits 64 KiB, to every socket past
    /// Hello subscribed to the zone whose session still holds (else it ends, 4001) and may read it.
    func fanOut(since before: [String: UInt64]) {
        for (name, old) in before.sorted(by: { $0.key < $1.key }) {
            guard let zone = state.zones[name], zone.lastSeq > old else { continue }
            var changed = Relay_V1_ZoneChanged()
            changed.zone = name
            changed.seq = zone.lastSeq
            if zone.lastSeq == old + 1, let record = zone.records.values.first(where: { $0.seq == zone.lastSeq }),
               record.envelope.count <= Self.maxInlineRecordBytes {
                changed.record = Self.proto(record, zone: name, envelope: true)
            }
            var frame = Relay_V1_Frame()
            frame.event.zoneChanged = changed
            for socket in state.sockets where socket.hello && socket.subscriptions.contains(name) {
                guard let session = holding(socket.token) else {
                    expire(socket)
                    continue
                }
                guard (try? access(name, session, .read)) != nil else { continue }
                socket.deliver(frame)
            }
        }
    }

    // MARK: - Server-side socket actions (lock held)

    /// The session of `token` when it is still live.
    func holding(_ token: String) -> Session? {
        guard let session = state.sessions[token], now < session.expiresAt else { return nil }
        return session
    }

    /// The device's socket past Hello.
    func liveSocket(of deviceID: String) -> FakeRelaySocket? {
        state.sockets.first { $0.deviceID == deviceID && $0.hello }
    }

    func close(_ socket: FakeRelaySocket, code: Int) {
        socket.serverClose(code)
        state.sockets.removeAll { $0 === socket }
    }

    /// Displacement or drain: `GoingAway`, then 1001.
    func goAway(_ socket: FakeRelaySocket) {
        var frame = Relay_V1_Frame()
        frame.goingAway = Relay_V1_GoingAway()
        socket.deliver(frame)
        close(socket, code: Self.closeGoingAway)
    }

    /// The session ended mid-connection: `Control{SESSION_EXPIRED}`, then 4001.
    func expire(_ socket: FakeRelaySocket) {
        var frame = Relay_V1_Frame()
        frame.event.control.kind = .sessionExpired
        socket.deliver(frame)
        close(socket, code: Self.closeUnauthenticated)
    }
}

/// `FakeHostedRelay.http`: ops, blob uploads and downloads, as `URLSessionRelayHTTP` would see them.
struct FakeRelayHTTP: RelayHTTP {
    let relay: FakeHostedRelay

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        try relay.post(url, body: body, headers: headers)
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        try relay.putBlob(url, try Data(contentsOf: file))
    }

    /// Like `URLSessionRelayHTTP`: only a 2xx body is written, and a body past `maxBytes`
    /// throws `URLError(.dataLengthExceedsMaximum)`.
    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        let (status, data) = try relay.getBlob(url)
        guard let data else { return status }
        if Int64(data.count) > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        try data.write(to: file)
        return status
    }
}

struct FakeRelayDialer: RelaySocketDialer {
    let relay: FakeHostedRelay

    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        try relay.dial(url, headers: headers)
    }
}

/// One socket of the fake. Its server side (`hello`, `subscriptions`) is guarded by the
/// relay's lock; its pipe (what the client reads) by its own lock, always taken after the
/// relay's and never the other way round.
final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    struct Gone: Error {}

    private struct Pipe {
        var inbound: [RelaySocketMessage] = []
        var receiver: CheckedContinuation<RelaySocketMessage, any Error>?
        var pingWaiters: [CheckedContinuation<Void, any Error>] = []
        /// Closed by either side or cut: nothing more goes either way; what is queued is still read.
        var ended = false
    }

    let deviceID: String
    /// The upgrade's token: `Hello` must repeat it.
    let token: String
    let connectionID = UUID().uuidString
    var hello = false
    var subscriptions: Set<String> = []

    private let relay: FakeHostedRelay
    private let pipe = OSAllocatedUnfairLock(initialState: Pipe())

    init(relay: FakeHostedRelay, deviceID: String, token: String) {
        self.relay = relay
        self.deviceID = deviceID
        self.token = token
    }

    // MARK: - Server side

    func deliver(_ frame: Relay_V1_Frame) {
        guard let data = try? frame.serializedData() else { return }
        push(.binary(data))
    }

    /// The server's close frame, read after what is queued.
    func serverClose(_ code: Int) {
        push(.closed(code: code))
        let waiters = pipe.withLock { pipe in
            pipe.ended = true
            defer { pipe.pingWaiters = [] }
            return pipe.pingWaiters
        }
        for waiter in waiters { waiter.resume(throwing: Gone()) }
    }

    /// A crash: no close frame, unread frames lost.
    func cut() {
        let (receiver, waiters) = pipe.withLock { pipe in
            pipe.ended = true
            pipe.inbound = []
            defer {
                pipe.receiver = nil
                pipe.pingWaiters = []
            }
            return (pipe.receiver, pipe.pingWaiters)
        }
        receiver?.resume(throwing: Gone())
        for waiter in waiters { waiter.resume(throwing: Gone()) }
    }

    private func push(_ message: RelaySocketMessage) {
        let receiver: CheckedContinuation<RelaySocketMessage, any Error>? = pipe.withLock { pipe in
            guard !pipe.ended else { return nil }
            guard let receiver = pipe.receiver else {
                pipe.inbound.append(message)
                return nil
            }
            pipe.receiver = nil
            return receiver
        }
        receiver?.resume(returning: message)
    }

    // MARK: - RelaySocket

    func send(_ data: Data) async throws {
        guard !pipe.withLock({ $0.ended }) else { throw Gone() }
        relay.receive(data, on: self)
    }

    func receive() async throws -> RelaySocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<RelaySocketMessage, any Error>? = pipe.withLock { pipe in
                if !pipe.inbound.isEmpty { return .success(pipe.inbound.removeFirst()) }
                if pipe.ended { return .failure(Gone()) }
                pipe.receiver = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func ping() async throws {
        let pongs = relay.pongs
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = pipe.withLock { pipe in
                if pipe.ended { return .failure(Gone()) }
                if pongs { return .success(()) }
                pipe.pingWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func close(code: Int) async {
        let (receiver, waiters) = pipe.withLock { pipe in
            pipe.ended = true
            defer {
                pipe.receiver = nil
                pipe.pingWaiters = []
            }
            return (pipe.receiver, pipe.pingWaiters)
        }
        receiver?.resume(throwing: Gone())
        for waiter in waiters { waiter.resume(throwing: Gone()) }
        relay.forget(self)
    }
}
