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

    /// The workspace directory, asked again for every new connection: nil
    /// (no workspace yet, a fresh install before onboarding creates one)
    /// is down.
    private let resolveWorkspace: @Sendable () -> String?
    /// Opens connections and writes call frames, one at a time.
    private let queue = DispatchQueue(label: "tower.socket.calls")
    private let current = OSAllocatedUnfairLock<CallConnection?>(initialState: nil)

    package convenience init(workspace: String) {
        self.init { workspace }
    }

    package init(resolveWorkspace: @escaping @Sendable () -> String?) {
        self.resolveWorkspace = resolveWorkspace
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

    /// Cancelling the calling task drops the connection the call went out
    /// on (a daemon that stopped answering): the call and every other one
    /// waiting on it fail with `.down`, and the next call reconnects.
    package func call(_ request: Request) async throws -> Response {
        let line = try Self.frame(request)
        let ticket = CallTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.send(line, id: request.id, ticket: ticket, continuation) }
            }
        } onCancel: {
            ticket.cancel()
        }
    }

    package func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        let workspace = resolveWorkspace()
        let socket = UnixSocket.WatchSocket()
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
    private func send(_ line: Data, id: String, ticket: CallTicket, _ continuation: CheckedContinuation<Response, Error>) {
        let connection: CallConnection
        do {
            connection = try openConnection()
        } catch {
            continuation.resume(throwing: TowerTransportError.down)
            return
        }
        guard ticket.sent(on: connection), connection.register(id, continuation) else {
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
        guard let workspace = resolveWorkspace(), let path = Self.socketPath(workspace: workspace) else {
            throw TowerTransportError.down
        }
        let connection = CallConnection(fd: try Self.connect(path))
        current.withLock { $0 = connection }
        connection.startReading()
        return connection
    }

    /// One call's link to its connection, so cancelling the call closes the
    /// connection it went out on (or, cancelled before it was sent, the
    /// connection it is about to use).
    private final class CallTicket: Sendable {
        private let state = OSAllocatedUnfairLock<(connection: CallConnection?, cancelled: Bool)>(initialState: (nil, false))

        /// Records the call's connection; false (and the connection closed)
        /// when the call was already cancelled.
        func sent(on connection: CallConnection) -> Bool {
            let cancelled = state.withLock {
                $0.connection = connection
                return $0.cancelled
            }
            if cancelled { connection.close() }
            return !cancelled
        }

        func cancel() {
            let connection = state.withLock {
                $0.cancelled = true
                return $0.connection
            }
            connection?.close()
        }
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
        workspace: String?,
        socket: UnixSocket.WatchSocket,
        yield: (ChangedEvent) -> Void
    ) throws {
        guard let workspace, let path = socketPath(workspace: workspace) else { throw TowerTransportError.down }
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

    // MARK: - POSIX

    private static func frame(_ request: Request) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// A connected socket, or `.down` (nothing serves `path`, or it does not fit).
    private static func connect(_ path: String) throws -> Int32 {
        do {
            return try UnixSocket.connect(path)
        } catch UnixSocket.Failure.absent {
            throw TowerTransportError.down
        } catch {
            log.error("tower socket connect failed: \(String(describing: error), privacy: .public)")
            throw TowerTransportError.down
        }
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        do {
            try UnixSocket.sendAll(fd, data, deadline: Date().addingTimeInterval(writeTimeout))
        } catch {
            throw TowerTransportError.down
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
