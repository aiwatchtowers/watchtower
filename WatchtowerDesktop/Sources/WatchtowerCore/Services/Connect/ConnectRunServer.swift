import Foundation

/// The per-run socket of one connect assistant run (agent connect spec
/// §5.3): `watchtower mcp --connect <svc>` dials it and forwards each connect
/// tool call as one JSON line (`ConnectWire`). The socket lives in a fresh
/// 0700 directory under the per-user temp dir from `start` to `stop`.
///
/// Admission: the peer's uid is this process's (`getpeereid`), and its hello
/// carries the run's token and service. A bad peer is closed without a
/// reply. One connection at a time: a second valid peer while the first is
/// connected gets the `busy` refusal and is closed; once the first hangs up,
/// the next one (the next turn's MCP server) is admitted.
///
/// Requests are read on a queue of their own and handed to `handler` on the
/// main actor in arrival order; calls may overlap (one waiting call does not
/// hold the others), and each answer is written when its handler returns.
/// When the peer hangs up or the run stops, the peer's running handlers are
/// cancelled and their answers dropped. The token is never logged.
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
    /// `sun_path` holds 104 bytes on macOS, the terminating NUL included.
    static let maxPathBytes = 103

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
    /// Every open connection, admitted or still before its hello.
    private var peers: [ObjectIdentifier: ConnectRunPeer] = [:]
    private var admitted: ConnectRunPeer?

    private let acceptQueue = DispatchQueue(label: "connect-run.accept")
    private let connectionQueue = DispatchQueue(label: "connect-run.connection", attributes: .concurrent)

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
        self.service = service
        self.temporaryDirectory = temporaryDirectory
        self.ownerUID = ownerUID
        self.helloWithin = helloWithin
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// The child's environment entries: the socket path and the token
    /// (empty before `start`).
    package var environment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let socketPath, !stopped else { return [:] }
        return [ConnectWire.socketEnv: socketPath, ConnectWire.tokenEnv: token]
    }

    /// Makes the run's 0700 directory, binds `connect.sock` (0600) in it and
    /// draws the 256-bit token. Once per server.
    package func start() throws -> (socketPath: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { throw ServerError.alreadyStarted }
        started = true

        let base = (temporaryDirectory as NSString).appendingPathComponent("wt-connect-XXXXXX")
        var template = Array(base.utf8CString)
        guard let made = mkdtemp(&template) else { throw ServerError.directory(errno) }
        let dir = String(cString: made)
        let path = (dir as NSString).appendingPathComponent(Self.socketName)
        do {
            guard chmod(dir, 0o700) == 0 else { throw ServerError.directory(errno) }
            guard path.utf8.count <= Self.maxPathBytes else { throw ServerError.pathTooLong }
            source = try listen(path: path)
        } catch {
            unlink(path)
            rmdir(dir)
            throw error
        }
        directory = dir
        socketPath = path
        token = Self.drawToken()
        return (path, token)
    }

    /// Ends the run: refuses new connections, closes every open one (its
    /// running handlers are cancelled), removes the socket and its directory.
    package func stop() {
        lock.lock()
        stopped = true
        let source = self.source
        self.source = nil
        let open = Array(peers.values)
        admitted = nil
        let path = socketPath
        let dir = directory
        directory = nil
        lock.unlock()

        source?.cancel()
        for peer in open { peer.cut() }
        if let path { unlink(path) }
        if let dir { rmdir(dir) }
    }

    // MARK: - Listening

    private func listen(path: String) throws -> DispatchSourceRead {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var addr = OwnerConfirmIO.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let err = errno
            close(fd)
            throw ServerError.socket(err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            // An accepted socket inherits O_NONBLOCK; its reads block in poll.
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard Self.peerUID(conn) == ownerUID else {
                close(conn)
                continue
            }
            let peer = ConnectRunPeer(fd: conn)
            lock.lock()
            let open = !stopped
            if open { peers[ObjectIdentifier(peer)] = peer }
            lock.unlock()
            guard open else {
                peer.finish()
                continue
            }
            connectionQueue.async { [weak self] in
                self?.serve(peer)
                peer.finish()
                self?.forget(peer)
            }
        }
    }

    private func forget(_ peer: ConnectRunPeer) {
        lock.lock()
        peers[ObjectIdentifier(peer)] = nil
        if admitted === peer { admitted = nil }
        lock.unlock()
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    // MARK: - One connection

    /// On the connection queue: the hello, the admission, then every request
    /// until the peer hangs up, sends a bad line, or the run stops.
    private func serve(_ peer: ConnectRunPeer) {
        var reader = ConnectLineReader(fd: peer.fd)
        let helloDeadline = helloWithin.map { Date().addingTimeInterval($0) }
        guard case let .line(helloLine) = reader.next(until: helloDeadline),
              let hello = try? JSONDecoder().decode(ConnectWireHello.self, from: helloLine),
              admits(hello)
        else { return }

        guard admit(peer) else {
            peer.send(ConnectWireHelloReply.busy)
            return
        }
        peer.send(ConnectWireHelloReply.admitted)

        while case let .line(line) = reader.next(until: nil) {
            guard let request = try? JSONDecoder().decode(ConnectWireRequest.self, from: line) else { return }
            dispatch(request, on: peer)
        }
    }

    private func admits(_ hello: ConnectWireHello) -> Bool {
        lock.lock()
        let token = self.token
        lock.unlock()
        return hello.v == ConnectWire.protocolVersion
            && hello.service == service
            && Self.sameBytes(hello.token, token)
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

    private func dispatch(_ request: ConnectWireRequest, on peer: ConnectRunPeer) {
        let handler = self.handler
        // Tasks made in arrival order from this one thread start on the main
        // actor in that order.
        let task = Task { @MainActor in
            let response = await handler(request)
            peer.answer(response.answering(request.id), for: request.id)
        }
        peer.track(request.id, task)
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
}

/// One connection's descriptor, its writes and its running calls. Writes go
/// through one serial queue (a line is never cut by another, and a peer that
/// stops reading never blocks the main actor); the descriptor is closed on
/// that queue too, so no write races its close.
final class ConnectRunPeer: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    /// False once the descriptor is closed.
    private var open = true
    /// True once the connection ended: answers are dropped.
    private var ended = false
    private var calls: [Int64: Task<Void, Never>] = [:]
    private let writeQueue = DispatchQueue(label: "connect-run.write")

    init(fd: Int32) {
        self.fd = fd
    }

    func track(_ id: Int64, _ task: Task<Void, Never>) {
        lock.lock()
        let live = !ended
        if live { calls[id] = task }
        lock.unlock()
        if !live { task.cancel() }
    }

    /// Writes a call's answer, unless the connection ended meanwhile. An
    /// answer too long for the wire becomes a `failed` error.
    func answer(_ response: ConnectWireResponse, for id: Int64) {
        lock.lock()
        calls[id] = nil
        let live = !ended
        lock.unlock()
        guard live else { return }
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
            // A cut line: end the connection, the reader wakes and finishes.
            if !sent { cut() }
        }
    }

    /// Ends the connection from outside its reader (the run stopped, a newer
    /// peer took over, a write failed): running calls are cancelled and the
    /// socket is shut, which wakes the reader.
    func cut() {
        lock.lock()
        ended = true
        let running = Array(calls.values)
        calls = [:]
        if open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        for task in running { task.cancel() }
    }

    /// The reader is done with the descriptor: cancel what runs, drop later
    /// answers, and close it after the lines already queued (a `busy`
    /// refusal).
    func finish() {
        lock.lock()
        ended = true
        let running = Array(calls.values)
        calls = [:]
        lock.unlock()
        for task in running { task.cancel() }
        writeQueue.async { [self] in
            lock.lock()
            let wasOpen = open
            open = false
            lock.unlock()
            if wasOpen { close(fd) }
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
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
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
