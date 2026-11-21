import Foundation

/// The per-run socket of one connect assistant run (agent connect spec
/// §5.3): `watchtower mcp --connect <svc>` dials it and forwards each connect
/// tool call as one JSON line (`ConnectWire`). The socket lives in a fresh
/// 0700 directory under the per-user temp dir from `start` to `stop` (or
/// until the server is released: nothing on its queues keeps it alive, and
/// its deinit stops the run).
///
/// Admission: the peer's uid is this process's (`getpeereid`), and its hello
/// carries the run's token and service. A bad peer is closed without a
/// reply. One connection at a time: a second valid peer while the first is
/// connected gets the `busy` refusal and is closed; once the first hangs up,
/// the next one (the next turn's MCP server) is admitted.
///
/// Requests are read on a queue of their own and handed to `handler` on the
/// main actor through one FIFO: each handler starts in arrival order, and
/// calls overlap (a waiting call does not hold the next one). Each answer is
/// written when its handler returns. When the peer hangs up or the run
/// stops, the peer's running handlers are cancelled, its queued requests
/// never start, and their answers are dropped. The token is never logged.
package final class ConnectRunServer: @unchecked Sendable {
    package enum ServerError: Error, Equatable {
        case alreadyStarted
        case pathTooLong
        case directory(Int32)
        case socket(Int32)
    }

    package static let socketName = "connect.sock"
    /// Seconds a connection has to send its hello.
    package static let helloTimeout: TimeInterval = 5
    /// Seconds one answer may wait for a peer that stopped reading before
    /// the connection is cut.
    static let writeTimeout = 45
    /// `sun_path` holds 104 bytes on macOS, the terminating NUL included.
    static let maxPathBytes = 103

    let core: ConnectRunCore

    /// `service` is the run's service (a hello naming another is refused).
    /// `ownerUID` and `helloWithin` are for tests: a peer uid other than
    /// this process's, and no hello deadline (nil) so a loaded machine never
    /// runs it out.
    package init(
        service: String,
        temporaryDirectory: String = NSTemporaryDirectory(),
        ownerUID: uid_t = getuid(),
        helloWithin: TimeInterval? = helloTimeout,
        handler: @escaping @MainActor (ConnectWireRequest) async -> ConnectWireResponse
    ) {
        core = ConnectRunCore(service: service, temporaryDirectory: temporaryDirectory, ownerUID: ownerUID,
                              helloWithin: helloWithin, handler: handler)
    }

    deinit {
        core.stop()
    }

    /// The child's environment entries: the socket path and the token
    /// (empty before `start` and after `stop`).
    package var environment: [String: String] { core.environment }

    /// Makes the run's 0700 directory, binds `connect.sock` (0600) in it and
    /// draws the 256-bit token. Once per server, never after `stop`.
    package func start() throws -> (socketPath: String, token: String) {
        try core.start()
    }

    /// Ends the run: refuses new connections, closes every open one (its
    /// running handlers are cancelled, its queued requests never start),
    /// removes the socket and its directory.
    package func stop() {
        core.stop()
    }

    // MARK: - Token

    /// 32 bytes from the system CSPRNG, as 64 lowercase hex digits.
    static func drawToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }

    /// Compares in time that depends only on the lengths.
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }
}

/// The run's state and IO, owned by `ConnectRunServer`. The listener, the
/// connection loops and the main-actor dispatcher hold this, never the
/// server, so releasing the server stops the run.
final class ConnectRunCore: @unchecked Sendable {
    private typealias Queued = (request: ConnectWireRequest, peer: ConnectRunPeer)

    private let service: String
    private let handler: @MainActor (ConnectWireRequest) async -> ConnectWireResponse
    private let temporaryDirectory: String
    private let ownerUID: uid_t
    private let helloWithin: TimeInterval?

    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var directory: String?
    private var socketPath: String?
    private var token = ""
    private var source: DispatchSourceRead?
    /// Every connection whose descriptor is still open, admitted or not.
    private var peers: [ObjectIdentifier: ConnectRunPeer] = [:]
    private var admitted: ConnectRunPeer?
    private var queue: AsyncStream<Queued>.Continuation?
    private var dispatcherTask: Task<Void, Never>?

    /// Tests: told when a request is queued for the main actor, and when a
    /// connection's descriptor is closed.
    var onQueued: (@Sendable () -> Void)?
    var onClosed: (@Sendable () -> Void)?

    private let acceptQueue = DispatchQueue(label: "connect-run.accept")
    private let connectionQueue = DispatchQueue(label: "connect-run.connection", attributes: .concurrent)

    init(
        service: String,
        temporaryDirectory: String,
        ownerUID: uid_t,
        helloWithin: TimeInterval?,
        handler: @escaping @MainActor (ConnectWireRequest) async -> ConnectWireResponse
    ) {
        self.service = service
        self.temporaryDirectory = temporaryDirectory
        self.ownerUID = ownerUID
        self.helloWithin = helloWithin
        self.handler = handler
    }

    var environment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let socketPath, !stopped else { return [:] }
        return [ConnectWire.socketEnv: socketPath, ConnectWire.tokenEnv: token]
    }

    /// The main-actor loop that starts handlers; it ends after `stop` once
    /// the queue drains (tests).
    var dispatcher: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return dispatcherTask
    }

    /// Connections whose descriptor is still open (tests).
    var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.count
    }

    /// The admitted connection's running calls (tests).
    var runningCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return admitted?.runningCalls ?? 0
    }

    func start() throws -> (socketPath: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !stopped else { throw ConnectRunServer.ServerError.alreadyStarted }
        started = true

        let base = (temporaryDirectory as NSString).appendingPathComponent("wt-connect-XXXXXX")
        var template = Array(base.utf8CString)
        guard let made = mkdtemp(&template) else { throw ConnectRunServer.ServerError.directory(errno) }
        let dir = String(cString: made)
        let path = (dir as NSString).appendingPathComponent(ConnectRunServer.socketName)
        do {
            guard chmod(dir, 0o700) == 0 else { throw ConnectRunServer.ServerError.directory(errno) }
            guard path.utf8.count <= ConnectRunServer.maxPathBytes else {
                throw ConnectRunServer.ServerError.pathTooLong
            }
            source = try listen(path: path)
        } catch {
            unlink(path)
            rmdir(dir)
            throw error
        }
        directory = dir
        socketPath = path
        token = ConnectRunServer.drawToken()
        let (stream, continuation) = AsyncStream.makeStream(of: Queued.self)
        queue = continuation
        dispatcherTask = Self.dispatch(stream, handler: handler)
        return (path, token)
    }

    func stop() {
        lock.lock()
        stopped = true
        let source = self.source
        self.source = nil
        let open = Array(peers.values)
        admitted = nil
        let path = socketPath
        let dir = directory
        directory = nil
        let queue = self.queue
        self.queue = nil
        lock.unlock()

        source?.cancel()
        for peer in open { peer.cut() }
        // What is still queued drains without starting: its peers are cut.
        queue?.finish()
        if let path { unlink(path) }
        if let dir { rmdir(dir) }
    }

    // MARK: - The main actor

    /// Starts each queued request's handler, one at a time in arrival order:
    /// the loop takes the next request only once the previous handler has
    /// started (run to its first suspension), so the handlers start in order
    /// and still overlap. A request whose peer ended is skipped.
    private static func dispatch(
        _ stream: AsyncStream<Queued>,
        handler: @escaping @MainActor (ConnectWireRequest) async -> ConnectWireResponse
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await (request, peer) in stream {
                guard peer.isLive else { continue }
                await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
                    // This task cannot run before the loop suspends here, so
                    // it is tracked before it starts and untracked as it ends.
                    let key = peer.callKey()
                    let task = Task { @MainActor in
                        started.resume()
                        defer { peer.untrack(key) }
                        guard !Task.isCancelled, peer.isLive else { return }
                        let response = await handler(request)
                        peer.answer(response.answering(request.id), for: request.id)
                    }
                    peer.track(task, key: key)
                }
            }
        }
    }

    // MARK: - Listening

    private func listen(path: String) throws -> DispatchSourceRead {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectRunServer.ServerError.socket(errno) }
        var addr = OwnerConfirmIO.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let err = errno
            close(fd)
            throw ConnectRunServer.ServerError.socket(err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            acceptAll(fd, source: source)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func acceptAll(_ fd: Int32, source: DispatchSourceRead) {
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else {
                // Out of descriptors: the pending connection stays readable,
                // so pause the listener instead of spinning on it.
                if errno == EMFILE || errno == ENFILE {
                    source.suspend()
                    acceptQueue.asyncAfter(deadline: .now() + .milliseconds(200)) { source.resume() }
                }
                return
            }
            // An accepted socket inherits O_NONBLOCK; its reads block in poll.
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: ConnectRunServer.writeTimeout, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            guard ConnectRunServer.peerUID(conn) == ownerUID else {
                close(conn)
                continue
            }
            let peer = ConnectRunPeer(fd: conn) { [weak self] peer in self?.forget(peer) }
            lock.lock()
            let open = !stopped
            if open { peers[ObjectIdentifier(peer)] = peer }
            lock.unlock()
            guard open else {
                peer.finish(flush: false)
                continue
            }
            connectionQueue.async { [self] in
                // Only the busy refusal is still worth delivering after the
                // loop: anything else answers a peer that is gone.
                peer.finish(flush: serve(peer))
            }
        }
    }

    /// The peer's descriptor is closed: it no longer holds the run.
    private func forget(_ peer: ConnectRunPeer) {
        lock.lock()
        peers[ObjectIdentifier(peer)] = nil
        if admitted === peer { admitted = nil }
        let onClosed = self.onClosed
        lock.unlock()
        onClosed?()
    }

    // MARK: - One connection

    /// On the connection queue: the hello, the admission, then every request
    /// until the peer hangs up, sends a bad line, or the run stops. True when
    /// the peer was refused as busy (the refusal is queued to be written).
    private func serve(_ peer: ConnectRunPeer) -> Bool {
        var reader = ConnectLineReader(fd: peer.fd)
        let helloDeadline = helloWithin.map { Date().addingTimeInterval($0) }
        guard case let .line(helloLine) = reader.next(until: helloDeadline),
              let hello = try? JSONDecoder().decode(ConnectWireHello.self, from: helloLine),
              admits(hello)
        else { return false }

        guard admit(peer) else {
            peer.send(ConnectWireHelloReply.busy)
            return true
        }
        peer.send(ConnectWireHelloReply.admitted)

        while case let .line(line) = reader.next(until: nil) {
            guard let request = try? JSONDecoder().decode(ConnectWireRequest.self, from: line) else { return false }
            lock.lock()
            let queue = self.queue
            let onQueued = self.onQueued
            lock.unlock()
            guard let queue else { return false }
            queue.yield((request, peer))
            onQueued?()
        }
        return false
    }

    private func admits(_ hello: ConnectWireHello) -> Bool {
        lock.lock()
        let token = self.token
        lock.unlock()
        return hello.v == ConnectWire.protocolVersion
            && hello.service == service
            && ConnectRunServer.sameBytes(hello.token, token)
    }

    /// Takes the run's one connection. A connected peer that has already
    /// hung up (its reader not yet woken) gives it up.
    private func admit(_ peer: ConnectRunPeer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if let current = admitted {
            guard current.hasHungUp() else { return false }
            current.cut()
        }
        admitted = peer
        return true
    }
}

/// One connection's descriptor, its writes and its running calls. Writes go
/// through one serial queue (a line is never cut by another, and a peer that
/// stops reading never blocks the main actor; `SO_SNDTIMEO` bounds each
/// write); the descriptor is closed on that queue too, so no write races its
/// close. The server keeps the peer registered until that close, so `stop`
/// can always cut it.
final class ConnectRunPeer: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private let onClose: @Sendable (ConnectRunPeer) -> Void
    /// False once the descriptor is closed.
    private var open = true
    /// True once the connection ended: queued requests do not start and
    /// answers are dropped.
    private var ended = false
    private var nextCall = 0
    private var calls: [Int: Task<Void, Never>] = [:]
    private let writeQueue = DispatchQueue(label: "connect-run.write")

    init(fd: Int32, onClose: @escaping @Sendable (ConnectRunPeer) -> Void) {
        self.fd = fd
        self.onClose = onClose
    }

    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ended
    }

    /// Running calls (tests).
    var runningCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    /// A key for the next call's task.
    func callKey() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextCall += 1
        return nextCall
    }

    /// Holds a call's task until it ends (`untrack`), so ending the
    /// connection cancels it; an ended connection cancels it at once.
    func track(_ task: Task<Void, Never>, key: Int) {
        lock.lock()
        let live = !ended
        if live { calls[key] = task }
        lock.unlock()
        if !live { task.cancel() }
    }

    func untrack(_ key: Int) {
        lock.lock()
        calls[key] = nil
        lock.unlock()
    }

    /// Writes a call's answer, unless the connection ended meanwhile. An
    /// answer too long for the wire becomes a `failed` error.
    func answer(_ response: ConnectWireResponse, for id: Int64) {
        guard isLive else { return }
        guard let line = try? ConnectWire.line(response), line.count < ConnectWire.maxLine else {
            return send(ConnectWireResponse(id: id, error: .failed,
                                            message: "the Watchtower app's answer is too long for the connect wire"))
        }
        write(line)
    }

    func send(_ value: some Encodable) {
        guard let line = try? ConnectWire.line(value) else { return }
        write(line)
    }

    private func write(_ line: Data) {
        writeQueue.async { [self] in
            lock.lock()
            let live = open
            lock.unlock()
            guard live else { return }
            let sent = line.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, base + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    offset += n
                }
                return true
            }
            // A cut line or a peer that stopped reading past SO_SNDTIMEO:
            // end the connection, the reader wakes and finishes.
            if !sent { cut() }
        }
    }

    /// Ends the connection from outside its reader (the run stopped, a newer
    /// peer took over, a write failed): running calls are cancelled and the
    /// socket is shut, which wakes the reader and fails a blocked write.
    func cut() {
        lock.lock()
        ended = true
        let running = Array(calls.values)
        calls = [:]
        if open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        for task in running { task.cancel() }
    }

    /// The reader is done with the descriptor. Running calls are cancelled.
    /// `flush` (a `busy` refusal is queued) closes it after the queued lines;
    /// otherwise the socket is shut first, so a write blocked on a peer that
    /// stopped reading fails now instead of pinning the descriptor.
    func finish(flush: Bool) {
        if flush {
            lock.lock()
            ended = true
            let running = Array(calls.values)
            calls = [:]
            lock.unlock()
            for task in running { task.cancel() }
        } else {
            cut()
        }
        writeQueue.async { [self] in
            lock.lock()
            let wasOpen = open
            open = false
            lock.unlock()
            guard wasOpen else { return }
            close(fd)
            onClose(self)
        }
    }

    /// True when the peer closed its side (nothing unread is left).
    func hasHungUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open, !ended else { return true }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return Self.peekMeansHungUp(n, errno: n < 0 ? errno : 0)
    }

    /// A peek of 0 bytes is EOF. Nothing to read yet (EAGAIN, EWOULDBLOCK,
    /// EINTR) or data waiting is a live peer; any other error is a broken
    /// socket.
    static func peekMeansHungUp(_ n: Int, errno err: Int32) -> Bool {
        if n > 0 { return false }
        if n == 0 { return true }
        return err != EAGAIN && err != EWOULDBLOCK && err != EINTR
    }
}

/// Reads newline-ended lines off a stream socket, keeping what follows a
/// line for the next one.
struct ConnectLineReader {
    enum Read: Equatable {
        case line(Data)
        /// The peer hung up, the read failed, the line ran past
        /// `ConnectWire.maxLine`, or the deadline passed.
        case end
    }

    let fd: Int32
    private var buffer = Data()
    /// Bytes of `buffer` already searched for a newline.
    private var scanned = 0

    init(fd: Int32) {
        self.fd = fd
    }

    /// The next line, without its newline; `deadline` nil waits for as long
    /// as it takes.
    mutating func next(until deadline: Date?) -> Read {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let end = buffer[(buffer.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[(end + 1)...])
                scanned = 0
                return line.count < ConnectWire.maxLine ? .line(line) : .end
            }
            scanned = buffer.count
            guard buffer.count < ConnectWire.maxLine else { return .end }
            var wait: Int32 = -1
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return .end }
                wait = Int32(max(1, left * 1000))
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, wait)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return .end }
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .end }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
