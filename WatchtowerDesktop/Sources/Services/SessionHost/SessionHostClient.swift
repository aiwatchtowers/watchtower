import Foundation
import Network
import os
import WatchtowerCore

/// One connection to the session host (board #496): frames out, frames in.
/// `open` throws when the host cannot be reached. `onClose` reports a
/// connection that ended on its own (the host closed it, or a broken
/// stream) — never one this side ended with `close()`. Callbacks arrive on
/// the main actor.
@MainActor
protocol SessionHostTransport: AnyObject {
    func open(onFrame: @escaping (SessionHostFrame) -> Void, onClose: @escaping () -> Void) async throws
    func send(_ frame: SessionHostFrame)
    func close()
}

enum SessionHostError: Error, Equatable {
    /// The host answered a request with an Error frame.
    case host(String)
    /// No connection to the host, or it ended before the reply.
    case disconnected
    /// The host sent a reply of another type than the request expects.
    case unexpectedReply(UInt8)
}

/// Hello and Error payloads (Go `HelloMsg`/`ErrorMsg`, a dual path).
struct SessionHostHello: Codable, Equatable {
    static let protocolVersion = 1

    let version: Int
    var pid: Int?
}

struct SessionHostErrorMessage: Codable, Equatable {
    let message: String
}

extension SessionHostFrame {
    /// A frame carrying `value` as its JSON payload; the protocol's
    /// messages always encode.
    static func json(_ type: SessionHostFrameType, _ value: some Encodable) -> Self {
        // swiftlint:disable:next force_try
        Self(type: type, payload: Array(try! JSONEncoder().encode(value)))
    }

    func decoded<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(payload))
    }
}

/// The app's side of the session host: makes sure a host serves the socket
/// (starting `watchtower session-host` when none does) and holds the control
/// connection that lists and forgets sessions. Each terminal session talks
/// to the host over a connection of its own (`makeSessionTransport`, one
/// session per connection). Main actor.
@MainActor
final class SessionHostClient {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionHost")
    /// How long a request on the control connection waits for its reply.
    static let replyTimeout: Duration = .seconds(2)
    /// How long a started host gets to serve the socket, and the retry step.
    static let spawnWait: Duration = .seconds(3)
    static let spawnRetryStep: Duration = .milliseconds(100)

    let socketPath: String
    private let cliPath: () -> String?
    private let makeTransport: (String) -> any SessionHostTransport
    /// Starts the host detached (`cli`, `socket`). A seam for tests.
    var spawnHost: (_ cli: String, _ socket: String) throws -> Void = { try SessionHostClient.spawnDetached(cli: $0, socket: $1) }
    /// The pause between connection attempts after a spawn. A seam for tests.
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Signals a hosted session's process group (`killpg`). A seam for tests.
    var signalGroup: (pid_t, Int32) -> Void = { _ = killpg($0, $1) }

    private var control: (any SessionHostTransport)?
    private var waiters: [Waiter] = []
    private var lastWaiterID = 0
    private var starting: Task<Bool, Never>?
    private var connecting: Task<Bool, Never>?

    private struct Waiter {
        let id: Int
        let expecting: SessionHostFrameType
        let continuation: CheckedContinuation<SessionHostFrame, any Error>
    }

    /// `makeTransport` defaults to `UnixSocketTransport` (nil: a closure
    /// default argument would not be main-actor isolated, see
    /// `TerminalCenter.init`).
    init(
        socketPath: String,
        cliPath: @escaping () -> String?,
        makeTransport: ((String) -> any SessionHostTransport)? = nil
    ) {
        self.socketPath = socketPath
        self.cliPath = cliPath
        self.makeTransport = makeTransport ?? { UnixSocketTransport(path: $0) }
    }

    /// Whether a host serves the socket: connects (Hello), and when nothing
    /// answers starts `<cli> session-host --socket <path>` and retries every
    /// `spawnRetryStep` for up to `spawnWait`. Concurrent calls share one
    /// attempt.
    func ensureRunning() async -> Bool {
        if control != nil { return true }
        if let starting { return await starting.value }
        let task = Task { await self.connectOrSpawn() }
        starting = task
        let running = await task.value
        starting = nil
        return running
    }

    /// The host's sessions, sorted by row and run.
    func list() async throws -> [SessionHostSessionInfo] {
        let reply = try await request(SessionHostFrame(type: .list), expecting: .listed)
        return try reply.decoded(SessionHostListResponse.self).sessions
    }

    /// Drops an exited session's record; best effort (a running session's
    /// forget is refused by the host, and logged).
    func forget(row: Int64, run: String) async {
        do {
            _ = try await request(.json(.forget, SessionHostAttachRequest(row: row, run: run)), expecting: .forgot)
        } catch {
            Self.logger.error("forget row \(row) run \(run, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// A new, unopened connection for one terminal session.
    func makeSessionTransport() -> any SessionHostTransport {
        makeTransport(socketPath)
    }

    // MARK: Control connection

    private func connectOrSpawn() async -> Bool {
        if await connectOnce() { return true }
        guard let cli = cliPath() else {
            Self.logger.error("no session host: the watchtower CLI was not found")
            return false
        }
        do {
            try spawnHost(cli, socketPath)
        } catch {
            Self.logger.error("could not start the session host: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Steps and the clock both bound the wait: a connect attempt itself
        // takes time (up to `UnixSocketTransport.openTimeout`).
        let deadline = ContinuousClock.now + Self.spawnWait
        var waited: Duration = .zero
        while waited < Self.spawnWait, ContinuousClock.now < deadline {
            await sleep(Self.spawnRetryStep)
            waited += Self.spawnRetryStep
            if await connectOnce() { return true }
        }
        Self.logger.error("the session host did not answer on \(self.socketPath, privacy: .public)")
        return false
    }

    /// The control connection, opened when there is none; concurrent
    /// callers share one attempt.
    private func connectOnce() async -> Bool {
        if control != nil { return true }
        if let connecting { return await connecting.value }
        let task = Task { await self.connect() }
        connecting = task
        let connected = await task.value
        connecting = nil
        return connected
    }

    /// Opens the control connection and says Hello.
    private func connect() async -> Bool {
        let transport = makeTransport(socketPath)
        do {
            try await transport.open(
                onFrame: { [weak self, weak transport] frame in
                    guard let self, let transport, control === transport else { return }
                    reply(frame)
                },
                onClose: { [weak self, weak transport] in
                    guard let self, let transport, control === transport else { return }
                    dropControl()
                }
            )
        } catch {
            return false
        }
        control = transport
        do {
            _ = try await request(.json(.hello, SessionHostHello(version: SessionHostHello.protocolVersion)), expecting: .helloOK)
            return true
        } catch {
            Self.logger.error("session host hello failed: \(String(describing: error), privacy: .public)")
            if control === transport { dropControl() }
            return false
        }
    }

    /// Sends `frame` on the control connection — reconnecting once, never
    /// starting a host — and waits for its reply. Replies come in request
    /// order. No reply within `replyTimeout` drops the connection.
    private func request(_ frame: SessionHostFrame, expecting: SessionHostFrameType) async throws -> SessionHostFrame {
        if frame.type != .hello, !(await connectOnce()) { throw SessionHostError.disconnected }
        guard let transport = control else { throw SessionHostError.disconnected }
        lastWaiterID += 1
        let id = lastWaiterID
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard !Task.isCancelled, let self, waiters.contains(where: { $0.id == id }) else { return }
            Self.logger.error("session host did not reply to frame \(frame.type.rawValue)")
            dropControl()
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, expecting: expecting, continuation: continuation))
            transport.send(frame)
        }
    }

    private func reply(_ frame: SessionHostFrame) {
        switch frame.type {
        case .helloOK, .listed, .forgot, .error:
            guard !waiters.isEmpty else { return }
            let waiter = waiters.removeFirst()
            if frame.type == .error {
                let message = (try? frame.decoded(SessionHostErrorMessage.self).message) ?? "unreadable error"
                waiter.continuation.resume(throwing: SessionHostError.host(message))
            } else if frame.type != waiter.expecting {
                waiter.continuation.resume(throwing: SessionHostError.unexpectedReply(frame.type.rawValue))
            } else {
                waiter.continuation.resume(returning: frame)
            }
        default:
            break // pushes belong to session connections
        }
    }

    /// Closes the control connection and fails every waiting request; the
    /// next request reconnects.
    private func dropControl() {
        control?.close()
        control = nil
        let failed = waiters
        waiters = []
        for waiter in failed { waiter.continuation.resume(throwing: SessionHostError.disconnected) }
    }

    // MARK: Starting the host

    /// The size over which a spawn empties the host's log first.
    nonisolated static let logCap: UInt64 = 1 << 20

    /// `~/Library/Application Support/Watchtower/session-host.log`, the
    /// host's stdout and stderr.
    nonisolated static func logFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/session-host.log")
    }

    /// Runs `<cli> session-host --socket <socket>` with stdio to the log
    /// file. The host leaves the app's session itself (`setsid`), so the
    /// app's exit does not reach it; one already serving the socket makes
    /// the new one exit at once.
    nonisolated static func spawnDetached(cli: String, socket: String) throws {
        let logURL = logFileURL()
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        // Kept small without rotation: over the cap it starts afresh.
        if try log.seekToEnd() > logCap { try log.truncate(atOffset: 0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["session-host", "--socket", socket]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }
}

/// The live transport: a unix stream socket through `NWConnection`. A path
/// over `sockaddr_un`'s limit is refused before Network sees it (Network
/// traps on one).
@MainActor
final class UnixSocketTransport: SessionHostTransport {
    enum TransportError: Error {
        case pathTooLong
        case unreachable(String)
    }

    /// `sun_path` holds 104 bytes on macOS, the terminating NUL included.
    static let maxPathBytes = 103
    /// How long `open` waits for the connection to become ready: one stuck
    /// preparing must not hold a caller (`ensureRunning`'s 3 s budget).
    static let openTimeout: Duration = .seconds(1)

    private let path: String
    private var connection: NWConnection?
    private var decoder = SessionHostFrameDecoder()
    private var onFrame: ((SessionHostFrame) -> Void)?
    private var onClose: (() -> Void)?
    private var opening: CheckedContinuation<Void, any Error>?

    init(path: String) {
        self.path = path
    }

    /// A transport dropped without `close()` (its owner went away) still
    /// ends its connection, so the host stops queueing to a dead reader.
    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    func open(onFrame: @escaping (SessionHostFrame) -> Void, onClose: @escaping () -> Void) async throws {
        guard path.utf8.count <= Self.maxPathBytes else { throw TransportError.pathTooLong }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        self.onFrame = onFrame
        self.onClose = onClose
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            opening = continuation
            connection.stateUpdateHandler = { [weak self] state in
                // Started on the main queue: handlers run there.
                MainActor.assumeIsolated { self?.stateChanged(state, of: connection) }
            }
            connection.start(queue: .main)
            Task { [weak self] in
                try? await Task.sleep(for: Self.openTimeout)
                guard let self, self.connection === connection, let opening else { return }
                self.opening = nil
                close()
                opening.resume(throwing: TransportError.unreachable("timed out connecting"))
            }
        }
        receive(on: connection)
    }

    func send(_ frame: SessionHostFrame) {
        guard let connection else { return }
        connection.send(content: Data(frame.encoded()), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.finish(connection) }
        })
    }

    func close() {
        onFrame = nil
        onClose = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        opening?.resume(throwing: CancellationError())
        opening = nil
    }

    private func stateChanged(_ state: NWConnection.State, of connection: NWConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .ready:
            opening?.resume()
            opening = nil
        case let .waiting(error), let .failed(error):
            // A missing socket or a refused connection waits for a network
            // change that never comes: either is unreachable.
            if let opening {
                self.opening = nil
                close()
                opening.resume(throwing: TransportError.unreachable(error.localizedDescription))
            } else {
                finish(connection)
            }
        case .cancelled:
            finish(connection)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated { self?.received(data, isComplete: isComplete || error != nil, on: connection) }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, on connection: NWConnection) {
        guard self.connection === connection else { return }
        if let data, !data.isEmpty {
            let frames: [SessionHostFrame]
            do {
                frames = try decoder.append([UInt8](data))
            } catch {
                finish(connection)
                return
            }
            for frame in frames {
                onFrame?(frame)
                // A frame's handler may have closed the connection.
                guard self.connection === connection else { return }
            }
        }
        if isComplete {
            finish(connection)
        } else {
            receive(on: connection)
        }
    }

    /// The connection ended on its own: reported once through `onClose`.
    private func finish(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        let onClose = onClose
        close()
        onClose?()
    }
}
