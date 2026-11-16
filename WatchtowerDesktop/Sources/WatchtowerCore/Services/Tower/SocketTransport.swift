import Darwin
import Foundation
import os
import WatchtowerInterface

/// The Mac's `TowerTransport`: the daemon's tower socket (mobile Inbox spec
/// §3; Go `tower.ServeWorkspace`). Newline-delimited JSON: a `Request` line
/// out, a `Response` line with the same `id` back.
///
/// - Calls share one connection, opened on the first call and again after
///   it closed; answers may come out of order and are matched by `id`. A
///   closed connection fails every call still waiting with `.down`.
/// - Each watch has a connection of its own: it answers `ok` once, then
///   streams `ChangedEvent` lines until the consumer stops (which closes
///   that connection, the only way to end a watch).
/// - Every new connection finds the socket again (`socketPath`), so a
///   daemon that moved to the fallback path is found.
///
/// Blocking POSIX I/O on a queue and threads of its own, never the caller's.
package final class SocketTransport: TowerTransport {
    /// The socket's name in the workspace (Go `socketName`).
    package static let socketName = "tower.sock"
    /// The file naming the fallback socket (Go `SocketPathFile`).
    package static let pathFileName = "tower.sock.path"
    /// A line longer than this closes the connection (a feed is well under it).
    static let maxFrame = 64 << 20
    /// One frame's write gives up after this (Go's server side uses the same).
    static let writeTimeout: TimeInterval = 10

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "tower-socket")

    package let workspace: String
    /// Opens connections and writes call frames, one at a time.
    private let queue = DispatchQueue(label: "tower.socket.calls")
    private let current = OSAllocatedUnfairLock<CallConnection?>(initialState: nil)

    package init(workspace: String) {
        self.workspace = workspace
    }

    /// The socket the daemon of `workspace` serves: the path written in
    /// `tower.sock.path` when that file exists, else `<workspace>/tower.sock`.
    /// Nil when the file exists but names nothing readable (the daemon is
    /// writing it, or it is damaged): no connection is tried.
    package static func socketPath(workspace: String) -> String? {
        let dir = workspace as NSString
        let file = dir.appendingPathComponent(pathFileName)
        guard FileManager.default.fileExists(atPath: file) else { return dir.appendingPathComponent(socketName) }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            log.error("tower.sock.path exists but cannot be read")
            return nil
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            log.error("tower.sock.path is empty")
            return nil
        }
        return path
    }

    // MARK: - TowerTransport

    package func call(_ request: Request) async throws -> Response {
        let line = try Self.frame(request)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.send(line, id: request.id, continuation) }
        }
    }

    package func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        let workspace = workspace
        let socket = WatchSocket()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in socket.stop() }
            let thread = Thread {
                do {
                    try Self.runWatch(request, workspace: workspace, socket: socket) { continuation.yield($0) }
                } catch {
                    if socket.isStopped { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            thread.name = "tower.socket.watch"
            thread.start()
        }
    }

    // MARK: - Calls

    /// On `queue`: registers the call on the open connection (opening one
    /// when none is) and writes its frame. A failed write closes the
    /// connection, which fails this call and every other one waiting.
    private func send(_ line: Data, id: String, _ continuation: CheckedContinuation<Response, Error>) {
        let connection: CallConnection
        do {
            connection = try openConnection()
        } catch {
            continuation.resume(throwing: TowerTransportError.down)
            return
        }
        guard connection.register(id, continuation) else {
            continuation.resume(throwing: TowerTransportError.down)
            return
        }
        do {
            try Self.sendAll(connection.fd, line)
        } catch {
            connection.close()
        }
    }

    private func openConnection() throws -> CallConnection {
        if let open = current.withLock({ $0 }), open.isOpen { return open }
        guard let path = Self.socketPath(workspace: workspace) else { throw TowerTransportError.down }
        let connection = CallConnection(fd: try Self.connect(path))
        current.withLock { $0 = connection }
        connection.startReading()
        return connection
    }

    /// The calls' connection: the calls waiting for an answer, by `id`. Its
    /// reader thread resolves them; `close` fails the rest with `.down`.
    /// The descriptor is closed only when the connection is freed, so no
    /// write or shutdown ever reaches a reused number.
    private final class CallConnection: Sendable {
        private struct State {
            var open = true
            var pending: [String: CheckedContinuation<Response, Error>] = [:]
        }

        let fd: Int32
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(fd: Int32) {
            self.fd = fd
        }

        deinit {
            Darwin.close(fd)
        }

        var isOpen: Bool { state.withLock { $0.open } }

        /// False when the connection already closed.
        func register(_ id: String, _ continuation: CheckedContinuation<Response, Error>) -> Bool {
            let (kept, replaced) = state.withLock { state -> (Bool, CheckedContinuation<Response, Error>?) in
                guard state.open else { return (false, nil) }
                return (true, state.pending.updateValue(continuation, forKey: id))
            }
            // Two calls with one id cannot both be answered: the first gives up.
            replaced?.resume(throwing: TowerTransportError.down)
            return kept
        }

        func close() {
            let waiting = state.withLock { state -> [CheckedContinuation<Response, Error>] in
                guard state.open else { return [] }
                state.open = false
                defer { state.pending = [:] }
                return Array(state.pending.values)
            }
            Darwin.shutdown(fd, SHUT_RDWR)
            waiting.forEach { $0.resume(throwing: TowerTransportError.down) }
        }

        func startReading() {
            let thread = Thread { [self] in
                var reader = FrameReader(fd: fd)
                while let line = reader.next() {
                    guard let response = try? JSONDecoder().decode(Response.self, from: line) else {
                        SocketTransport.log.error("tower socket: a line that is not a response")
                        continue
                    }
                    let waiting = state.withLock { $0.pending.removeValue(forKey: response.id) }
                    waiting?.resume(returning: response)
                }
                close()
            }
            thread.name = "tower.socket.reader"
            thread.start()
        }
    }

    // MARK: - Watch

    /// On the watch's thread: connects, sends the request, waits for its
    /// `ok`, then hands every `changed` frame to `yield` until the
    /// connection ends (`.down`) or the consumer stops it.
    private static func runWatch(
        _ request: Request,
        workspace: String,
        socket: WatchSocket,
        yield: (ChangedEvent) -> Void
    ) throws {
        guard let path = socketPath(workspace: workspace) else { throw TowerTransportError.down }
        let fd = try connect(path)
        guard socket.adopt(fd) else {
            Darwin.close(fd)
            return
        }
        defer { socket.close() }
        try sendAll(fd, try frame(request))
        var reader = FrameReader(fd: fd)
        var answered = false
        while let line = reader.next() {
            if answered {
                guard let event = try? JSONDecoder().decode(ChangedEvent.self, from: line), event.id == request.id else { continue }
                yield(event)
                continue
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: line), response.id == request.id else { continue }
            switch response.status {
            case .ok:
                answered = true
            case .refused:
                throw TowerTransportError.refused(response.refusal ?? Refusal(code: .unsupported, sentence: TowerText.unreadableAnswer))
            case .unknownStatus, .unknown:
                throw TowerTransportError.down
            }
        }
        throw TowerTransportError.down
    }

    /// A watch's socket: `stop` shuts it down (waking a blocked read) while
    /// it is open; only the watch thread closes it, under the same lock.
    private final class WatchSocket: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (fd: Int32(-1), stopped: false))

        var isStopped: Bool { state.withLock { $0.stopped } }

        /// Keeps `fd` unless the stream already ended (then false: the caller closes it).
        func adopt(_ fd: Int32) -> Bool {
            state.withLock {
                guard !$0.stopped else { return false }
                $0.fd = fd
                return true
            }
        }

        func stop() {
            state.withLock {
                $0.stopped = true
                if $0.fd >= 0 { Darwin.shutdown($0.fd, SHUT_RDWR) }
            }
        }

        func close() {
            state.withLock {
                if $0.fd >= 0 { Darwin.close($0.fd) }
                $0.fd = -1
            }
        }
    }

    // MARK: - POSIX

    private static func frame(_ request: Request) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// A connected socket, or `.down` (nothing serves `path`, or it does not fit).
    private static func connect(_ path: String) throws -> Int32 {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            log.error("tower socket path does not fit sockaddr_un")
            throw TowerTransportError.down
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TowerTransportError.down }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            if err != ENOENT, err != ECONNREFUSED, err != ENOTDIR {
                log.error("tower socket connect failed: errno \(err, privacy: .public)")
            }
            throw TowerTransportError.down
        }
        return fd
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        let deadline = Date().addingTimeInterval(writeTimeout)
        var sent = 0
        while sent < data.count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw TowerTransportError.down }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, left * 1000))) > 0 else { continue }
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, raw.count - sent)
            }
            guard n > 0 else {
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                throw TowerTransportError.down
            }
            sent += n
        }
    }

    /// The lines of one connection, kept across reads; blocks with no timer.
    private struct FrameReader {
        let fd: Int32
        var buffer = Data()
        /// How far `buffer` is known to hold no newline.
        var scanned = 0

        /// The next whole line; nil when the connection ended, failed or
        /// sent a line past `maxFrame`.
        mutating func next() -> Data? {
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                if let end = buffer[(buffer.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(buffer[buffer.startIndex..<end])
                    buffer = Data(buffer[buffer.index(after: end)...])
                    scanned = 0
                    return line
                }
                scanned = buffer.count
                guard buffer.count <= SocketTransport.maxFrame else {
                    SocketTransport.log.error("tower socket: a frame past maxFrame, connection closed")
                    return nil
                }
                let n = read(fd, &chunk, chunk.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                guard n > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }
}
