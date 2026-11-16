import ChatWire
import Darwin
import Foundation

/// The time the chat client waits on: the reconnect backoff and the "unavailable" window. Tests inject a manual one,
/// so no test waits on the wall clock.
package protocol ChatClientClock: Sendable {
    func sleep(for duration: Duration) async throws
    var now: ContinuousClock.Instant { get }
}

/// The real clock.
package struct SystemChatClientClock: ChatClientClock {
    package init() {}

    package func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    package var now: ContinuousClock.Instant { ContinuousClock.now }
}

/// When the Mac chat says what about Watchtower's background service (unified chat spec §6.2, D11).
package enum ChatReachabilityPolicy {
    /// `<workspace>/daemon.stopped`: written by the owner's `watchtower sync stop`, removed by every daemon start.
    package static let stoppedMarkerName = "daemon.stopped"
    /// "Chat is unavailable" shows after this long without a connection.
    package static let unavailableAfter: Duration = .seconds(10)
    /// The reconnect backoff: 100 ms doubling to 2 s.
    package static let firstBackoff: Duration = .milliseconds(100)
    package static let maxBackoff: Duration = .seconds(2)

    package static func backoff(attempt: Int) -> Duration {
        let doubled = firstBackoff * (1 << min(max(attempt, 0), 5))
        return min(doubled, maxBackoff)
    }
}

/// The connection dropped before the engine's answer arrived (`ChatConnectionError`): the operation may or may not
/// have been applied, so a turn goes again with the same client key.
package struct ChatSocketDropped: ChatConnectionError, Equatable {
    package init() {}
}

/// The Mac's `ChatClient` (unified chat spec §5.1, §6.2): one connection to the daemon's chat engine on `chat.sock`,
/// newline-delimited JSON both ways. The server greets first (`{"event":"ready","protocol":1}`), the client says
/// `hello` with the part kinds it draws, then requests carry ids and their answers echo them; subscriptions push
/// events tagged with the subscription the server named.
///
/// The connection is kept for the app's life: after a drop it reconnects with backoff (100 ms doubling to 2 s),
/// resubscribes every open feed and list (each gets a fresh snapshot) and reports `.connected` again. While the socket
/// cannot be reached it reads the stopped marker: present, the owner stopped Watchtower (`.stoppedOnPurpose`, nothing
/// starts it); absent, it starts the daemon once per outage through the app's start chain (`.starting`), and reports
/// `.unavailable` after 10 s. A write that fails (a half-open socket after sleep) drops the connection at once.
package final class SocketChatClient: ChatClient {
    private let core: Core

    /// `partKinds` are the part kinds the app draws (`ChatPartRegistry.registered`; Core never imports ChatUI).
    package init(
        socketPath: String,
        markerPath: String,
        startDaemon: @escaping @Sendable () async -> Void,
        clock: any ChatClientClock,
        partKinds: [String]
    ) {
        core = Core(socketPath: socketPath, markerPath: markerPath, startDaemon: startDaemon, clock: clock,
                    partKinds: partKinds)
        Task { [core] in await core.run() }
    }

    package func send(_ op: ChatOperation) async throws -> ChatEcho {
        try await core.request(op)
    }

    package func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatFeedUpdate.self)
        let token = UUID()
        let core = core
        continuation.onTermination = { _ in Task { await core.remove(token) } }
        Task { await core.add(token, .feed(conversation, continuation)) }
        return stream
    }

    package func list() -> AsyncStream<ChatListUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatListUpdate.self)
        let token = UUID()
        let core = core
        continuation.onTermination = { _ in Task { await core.remove(token) } }
        Task { await core.add(token, .list(continuation)) }
        return stream
    }

    package var reachability: AsyncStream<ChatReachability> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatReachability.self)
        let token = UUID()
        let core = core
        continuation.onTermination = { _ in Task { await core.removeWatcher(token) } }
        Task { await core.addWatcher(token, continuation) }
        return stream
    }

    /// The state line's Retry or Start: runs the start chain now and tries at once ("Chat is starting…" until it
    /// answers; the marker the start removes is not read meanwhile).
    package func startDaemonNow() {
        Task { [core] in await core.ownerStart() }
    }

    /// Ends every chat turn and session (`chat_shutdown`): the app's quit, wipe and compaction stops (T10b). False
    /// when the engine could not be reached or refused it.
    package func shutdown() async -> Bool {
        guard case .applied? = try? await core.request(.shutdown) else { return false }
        return true
    }

    /// Makes the next write fail as a half-open socket's does (a unix socket gives no such state to provoke in a
    /// test: its peer's end always reads as closed at once).
    func failNextWrite() async {
        await core.failNextWrite()
    }

    /// Stops reconnecting and closes the connection (tests; the app keeps its client for its life).
    package func close() async {
        await core.close()
    }
}

// MARK: - The connection

extension SocketChatClient {
    enum Subscriber {
        case feed(Int64, AsyncStream<ChatFeedUpdate>.Continuation)
        case list(AsyncStream<ChatListUpdate>.Continuation)
    }

    /// One open subscription: what it is, and the server's name for it on the current connection.
    struct Subscription {
        let subscriber: Subscriber
        var wireID: String?
    }

    enum Pending {
        case operation(ChatOperation, CheckedContinuation<ChatEcho, any Error>)
        case hello
        case subscribe(UUID)
        case ignored
    }

    actor Core {
        private let socketPath: String
        private let markerPath: String
        private let startDaemon: @Sendable () async -> Void
        private let clock: any ChatClientClock
        private let partKinds: [String]

        private var connection: SocketLine?
        private var connected = false
        private var nextID = 0
        private var pending: [String: Pending] = [:]
        private var subscriptions: [UUID: Subscription] = [:]
        private var byWireID: [String: UUID] = [:]
        /// Tokens whose stream ended before their registration ran (the two hops race).
        private var removedEarly: Set<UUID> = []
        private var watchers: [UUID: AsyncStream<ChatReachability>.Continuation] = [:]
        private var removedWatchers: Set<UUID> = []
        private var state: ChatReachability?

        private var closed = false
        private var attempt = 0
        private var outageStart: ContinuousClock.Instant?
        private var startedThisOutage = false
        /// The owner pressed Start: the marker that start removes is not read until the chat answers.
        private var ownerStarted = false
        private var forbidden = false
        private var sleeper: Task<Void, Never>?
        private let decoder = ChatWireCoder.makeDecoder()
        private var retryWaiter: CheckedContinuation<Void, Never>?

        init(
            socketPath: String,
            markerPath: String,
            startDaemon: @escaping @Sendable () async -> Void,
            clock: any ChatClientClock,
            partKinds: [String]
        ) {
            self.socketPath = socketPath
            self.markerPath = markerPath
            self.startDaemon = startDaemon
            self.clock = clock
            self.partKinds = partKinds
        }

        // MARK: Run loop

        func run() async {
            var sleepFirst = false
            while !closed {
                if forbidden {
                    await waitForOwner()
                    continue
                }
                if sleepFirst { await backoffSleep() }
                guard !closed else { return }
                sleepFirst = true
                guard let line = try? SocketLine(path: socketPath) else {
                    unreachable()
                    continue
                }
                await serve(line)
            }
        }

        /// Talks on one connection until it drops.
        private func serve(_ line: SocketLine) async {
            connection = line
            var greeted = false
            var reachedEngine = false
            reading: for await batch in line.lines {
                for data in batch {
                    if !greeted {
                        guard Self.isReady(data) else { break reading }
                        greeted = true
                        sendHello()
                        continue
                    }
                    if !connected, let answer = Answer(data), case .hello? = pending[answer.id] {
                        pending[answer.id] = nil
                        guard answer.ok else {
                            if answer.errorCode == "forbidden" { forbidden = true }
                            break reading
                        }
                        reachedEngine = true
                        becameConnected()
                        continue
                    }
                    handle(data)
                }
            }
            line.shutdown()
            connection = nil
            let wasConnected = connected
            connected = false
            dropped(wasConnected: wasConnected)
            if closed { return }
            if forbidden {
                setState(.unavailable)
            } else if !reachedEngine {
                unreachable()
            }
        }

        private func becameConnected() {
            connected = true
            attempt = 0
            outageStart = nil
            startedThisOutage = false
            ownerStarted = false
            // Reported after every reconnect, even an unchanged one: a send waiting on a lost answer goes again.
            setState(.connected, always: true)
            for token in subscriptions.keys { subscribe(token) }
        }

        /// The connection dropped: every waiting answer is lost, every subscription is shown stale until its fresh
        /// snapshot on the next connection.
        private func dropped(wasConnected: Bool) {
            let lost = pending
            pending = [:]
            byWireID = [:]
            for (_, entry) in lost {
                if case let .operation(_, continuation) = entry { continuation.resume(throwing: ChatSocketDropped()) }
            }
            for token in subscriptions.keys { subscriptions[token]?.wireID = nil }
            guard wasConnected else { return }
            for subscription in subscriptions.values {
                switch subscription.subscriber {
                case let .feed(_, continuation): continuation.yield(.resync)
                case let .list(continuation): continuation.yield(.resync)
                }
            }
        }

        /// The socket could not be reached (or the engine never answered hello).
        private func unreachable() {
            let now = clock.now
            if outageStart == nil { outageStart = now }
            if !ownerStarted, FileManager.default.fileExists(atPath: markerPath) {
                setState(.stoppedOnPurpose)
                return
            }
            if !startedThisOutage {
                startedThisOutage = true
                setState(.starting)
                Task { [startDaemon] in await startDaemon() }
                return
            }
            if let outageStart, now - outageStart >= ChatReachabilityPolicy.unavailableAfter {
                setState(.unavailable)
            }
        }

        private func backoffSleep() async {
            let duration = ChatReachabilityPolicy.backoff(attempt: attempt)
            attempt += 1
            let clock = clock
            let task = Task { _ = try? await clock.sleep(for: duration) }
            sleeper = task
            await task.value
            sleeper = nil
        }

        /// Forbidden by the engine: waits for the owner's Retry rather than knocking every 2 s.
        private func waitForOwner() async {
            await withCheckedContinuation { retryWaiter = $0 }
        }

        func ownerStart() {
            forbidden = false
            ownerStarted = true
            startedThisOutage = true
            attempt = 0
            outageStart = clock.now
            if !connected { setState(.starting) }
            Task { [startDaemon] in await startDaemon() }
            wake()
        }

        private var writeFails = false

        func failNextWrite() {
            writeFails = true
        }

        func close() {
            closed = true
            connection?.shutdown()
            wake()
        }

        private func wake() {
            sleeper?.cancel()
            retryWaiter?.resume()
            retryWaiter = nil
        }

        // MARK: Requests

        func request(_ op: ChatOperation) async throws -> ChatEcho {
            guard connected, let connection else { throw ChatSocketDropped() }
            let params = try op.wireParams()
            let id = newID()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .operation(op, continuation)
                if !write(connection, id: id, op: op.wireOp, params: params) {
                    // The write failed: the reader ends, and the drop answers the waiter.
                    connection.shutdown()
                }
            }
        }

        private func sendHello() {
            guard let connection else { return }
            let id = newID()
            pending[id] = .hello
            let params = (try? JSONSerialization.data(withJSONObject: [
                "protocol": 1, "client": "mac", "part_kinds": partKinds
            ])) ?? Data("{}".utf8)
            if !write(connection, id: id, op: "hello", params: params) { connection.shutdown() }
        }

        private func newID() -> String {
            nextID += 1
            return "m\(nextID)"
        }

        private func write(_ connection: SocketLine, id: String, op: String, params: Data) -> Bool {
            var line = Data(#"{"id":"\#(id)","op":"\#(op)","params":"#.utf8)
            line.append(params)
            line.append(contentsOf: Array("}\n".utf8))
            if writeFails {
                writeFails = false
                return false
            }
            return connection.write(line)
        }

        // MARK: Subscriptions

        func add(_ token: UUID, _ subscriber: Subscriber) {
            if removedEarly.remove(token) != nil { return }
            subscriptions[token] = Subscription(subscriber: subscriber)
            if connected { subscribe(token) }
        }

        func remove(_ token: UUID) {
            guard let subscription = subscriptions.removeValue(forKey: token) else {
                removedEarly.insert(token)
                return
            }
            guard let wireID = subscription.wireID else { return }
            unsubscribe(wireID)
        }

        private func unsubscribe(_ wireID: String) {
            byWireID[wireID] = nil
            guard let connection, connected else { return }
            let id = newID()
            pending[id] = .ignored
            let params = (try? JSONSerialization.data(withJSONObject: ["subscription": wireID])) ?? Data("{}".utf8)
            if !write(connection, id: id, op: "unsubscribe", params: params) { connection.shutdown() }
        }

        private func subscribe(_ token: UUID) {
            guard let subscription = subscriptions[token], let connection else { return }
            let params: [String: Any] = switch subscription.subscriber {
            case let .feed(conversation, _): ["conversation_id": conversation]
            case .list: ["list": true]
            }
            let id = newID()
            pending[id] = .subscribe(token)
            let body = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            if !write(connection, id: id, op: "subscribe", params: body) { connection.shutdown() }
        }

        // MARK: Reachability

        func addWatcher(_ token: UUID, _ continuation: AsyncStream<ChatReachability>.Continuation) {
            if removedWatchers.remove(token) != nil { return }
            watchers[token] = continuation
            if let state { continuation.yield(state) }
        }

        func removeWatcher(_ token: UUID) {
            if watchers.removeValue(forKey: token) == nil { removedWatchers.insert(token) }
        }

        private func setState(_ new: ChatReachability, always: Bool = false) {
            guard always || new != state else { return }
            state = new
            for continuation in watchers.values { continuation.yield(new) }
        }

        // MARK: Incoming lines

        private func handle(_ data: Data) {
            if data.starts(with: Self.eventPrefix) {
                guard let event = try? decoder.decode(ChatSocketEvent.self, from: data),
                      let token = byWireID[event.subscription], let subscription = subscriptions[token] else { return }
                switch subscription.subscriber {
                case let .feed(_, continuation):
                    if let update = event.feedUpdate { continuation.yield(update) }
                case let .list(continuation):
                    if let update = event.listUpdate { continuation.yield(update) }
                }
                return
            }
            guard let answer = Answer(data), let entry = pending.removeValue(forKey: answer.id) else { return }
            switch entry {
            case let .operation(op, continuation):
                continuation.resume(with: Result { try answer.echo(for: op) })
            case let .subscribe(token):
                guard answer.ok, let wireID = answer.subscription else { return }
                guard subscriptions[token] != nil else {
                    // Its stream ended while the subscribe was on its way.
                    unsubscribe(wireID)
                    return
                }
                subscriptions[token]?.wireID = wireID
                byWireID[wireID] = token
            case .hello, .ignored:
                break
            }
        }

        private static let eventPrefix = Data(#"{"event":"#.utf8)

        private static func isReady(_ data: Data) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["event"] as? String == "ready"
        }
    }

    /// An answer line: `{"id":…,"ok":true,"result":{…}}` or `{"id":…,"ok":false,"error":{"code":…,"message":…}}`.
    struct Answer {
        let id: String
        let ok: Bool
        let result: Any?
        let errorCode: String
        let errorMessage: String

        init?(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else { return nil }
            self.id = id
            ok = object["ok"] as? Bool ?? false
            result = object["result"]
            let error = object["error"] as? [String: Any]
            errorCode = error?["code"] as? String ?? ""
            errorMessage = error?["message"] as? String ?? ""
        }

        var subscription: String? { (result as? [String: Any])?["subscription"] as? String }

        func echo(for op: ChatOperation) throws -> ChatEcho {
            guard ok else { return .refused(code: errorCode, message: errorMessage) }
            let data = try result.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                ?? Data("{}".utf8)
            return .applied(try op.decodeResult(data))
        }
    }
}

/// One unix-socket connection's two halves: the lines read by a reader thread (in order, ending when the socket
/// does), and blocking writes bounded by a poll. The reader thread alone closes the descriptor, after its last read
/// and under the lock the writes take, so no number is ever used after it may have been reused.
final class SocketLine: @unchecked Sendable {
    /// A write the peer does not take within this long fails (a socket whose peer stopped reading).
    static let writeBound: Double = 5
    private let fd: Int32
    /// The lines of each read, in order (one hop per read, not per line).
    let lines: AsyncStream<[Data]>
    private let lock = NSLock()
    private var isShut = false
    private var isClosed = false

    init(path: String) throws {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ChatSocketDropped() }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatSocketDropped() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw ChatSocketDropped()
        }
        self.fd = fd
        let (stream, continuation) = AsyncStream.makeStream(of: [Data].self)
        lines = stream
        Thread.detachNewThread { [self] in read(into: continuation) }
    }

    /// Reads lines until the socket ends, closes the descriptor, then finishes the stream.
    private func read(into continuation: AsyncStream<[Data]>.Continuation) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            var start = buffer.startIndex
            var batch: [Data] = []
            while let end = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if end > start { batch.append(Data(buffer[start..<end])) }
                start = buffer.index(after: end)
            }
            if !batch.isEmpty { continuation.yield(batch) }
            if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        }
        lock.lock()
        isClosed = true
        Darwin.close(fd)
        lock.unlock()
        continuation.finish()
    }

    /// Writes the whole line; false when the socket refused it (the caller drops the connection).
    func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShut, !isClosed else { return false }
        let deadline = Date().addingTimeInterval(Self.writeBound)
        var sent = 0
        while sent < data.count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, left * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, raw.count - sent)
            }
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// Ends both directions: the reader sees the end, closes the descriptor and finishes `lines`.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isShut, !isClosed else { return }
        isShut = true
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}
