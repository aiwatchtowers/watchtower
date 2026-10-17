import Foundation
import Network

/// One request from the CLI — Go `ownerconfirm.Request`, one JSON line.
package struct OwnerConfirmRequest: Codable, Equatable, Sendable {
    package let v: Int
    package let verb: String
    package let detail: String?
    package let args: [String]
    package let agent: String?

    package init(v: Int = 1, verb: String, detail: String? = nil, args: [String], agent: String? = nil) {
        self.v = v
        self.verb = verb
        self.detail = detail
        self.args = args
        self.agent = agent
    }

    /// Longest text the window shows for the command or the detail.
    package static let displayLimit = 600

    /// The command as the window shows it: `watchtower` and the args, an
    /// arg with spaces quoted, control and format characters (bidi
    /// overrides, zero-width marks) replaced so the text reads as it runs.
    package var commandLine: String {
        let words = ["watchtower"] + args.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }
        return Self.displayable(words.joined(separator: " "))
    }

    package var displayDetail: String? {
        guard let detail, !detail.isEmpty else { return nil }
        return Self.displayable(detail)
    }

    package static func displayable(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                out.append("\u{FFFD}")
            default:
                out.append(scalar)
            }
        }
        let clean = String(out)
        return clean.count <= displayLimit ? clean : String(clean.prefix(displayLimit)) + "…"
    }
}

/// The Desktop's answer — Go `ownerconfirm.Reply`.
package struct OwnerConfirmReply: Codable, Equatable, Sendable {
    package static let confirmed = "confirmed"
    package static let denied = "denied"

    package let decision: String
    package let reason: String?

    package init(decision: String, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }
}

/// The open confirmation window's side of one request: the window calls
/// `answer` with the owner's click; the server calls `onWithdraw` when the
/// request ends without one (the CLI went away, the wait ran out), and the
/// window then closes.
@MainActor
package final class OwnerConfirmPrompt {
    package let request: OwnerConfirmRequest
    package var onWithdraw: (() -> Void)?
    fileprivate var reply: ((Bool) -> Void)?

    fileprivate init(request: OwnerConfirmRequest) {
        self.request = request
    }

    /// The owner's click: true confirms. Only the first answer counts.
    package func answer(_ confirmed: Bool) {
        let reply = self.reply
        self.reply = nil
        reply?(confirmed)
    }
}

/// Serves `<workspace>/owner-confirm.sock` (AGENT-07, board #568, ask #306;
/// Go `internal/ownerconfirm`): the CLI asks before an owner-only gesture.
/// A command this Desktop started (`OwnerConfirmGrants`) is confirmed at
/// once; any other request opens one confirmation window (`present`) and is
/// answered with the owner's click. One window at a time: a second request
/// while one is open is denied. There is no CLI, MCP or file path to answer —
/// only `OwnerConfirmPrompt.answer`, which the window's buttons call.
@MainActor
package final class OwnerConfirmServer {
    /// How long a window may wait for the owner — past the CLI's own wait
    /// (Go `ownerconfirm.Wait`, 100 s), which ends the request first.
    package static let promptTimeout: Duration = .seconds(110)
    /// Longest request line read.
    package static let maxRequestBytes = 64 * 1024
    /// `sun_path` holds 104 bytes on macOS, the terminating NUL included.
    package static let maxPathBytes = 103
    package static let fileName = "owner-confirm.sock"

    package enum ServerError: Error {
        case pathTooLong
        case anotherServer
    }

    /// The socket next to the workspace database (Go `ownerconfirm.SocketPath`).
    package static func socketPath(databasePath: String) -> String {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    private let path: String
    private let grants: OwnerConfirmGrants
    private let present: (OwnerConfirmPrompt) -> Void
    private let timeout: Duration
    private var listener: NWListener?
    private var open: OwnerConfirmPrompt?

    package init(
        path: String,
        grants: OwnerConfirmGrants = .shared,
        timeout: Duration = promptTimeout,
        present: @escaping (OwnerConfirmPrompt) -> Void
    ) {
        self.path = path
        self.grants = grants
        self.timeout = timeout
        self.present = present
    }

    /// Binds the socket. A stale socket file is replaced; one another live
    /// Desktop serves is left alone (`anotherServer`).
    package func start() throws {
        guard path.utf8.count <= Self.maxPathBytes else { throw ServerError.pathTooLong }
        if FileManager.default.fileExists(atPath: path) {
            if Self.answers(path) { throw ServerError.anotherServer }
            try? FileManager.default.removeItem(atPath: path)
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [path] state in
            // Owner-only, beside the 0700 workspace directory's own fence.
            if case .ready = state { chmod(path, 0o600) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    package func stop() {
        listener?.cancel()
        listener = nil
        open?.onWithdraw?()
        open?.answer(false)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Whether something accepts connections on `path` (a live server).
    private static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        readLine(conn, buffer: Data())
    }

    private func readLine(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return conn.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    self.handle(conn, line: buffer[..<newline])
                } else if done || error != nil || buffer.count > Self.maxRequestBytes {
                    conn.cancel()
                } else {
                    self.readLine(conn, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ conn: NWConnection, line: Data) {
        guard let request = try? JSONDecoder().decode(OwnerConfirmRequest.self, from: line) else {
            return send(conn, OwnerConfirmReply(decision: OwnerConfirmReply.denied, reason: "the request was not readable"))
        }
        if grants.consume(request.args) {
            return send(conn, OwnerConfirmReply(decision: OwnerConfirmReply.confirmed))
        }
        guard open == nil else {
            return send(conn, OwnerConfirmReply(decision: OwnerConfirmReply.denied,
                                                reason: "another confirmation is already open"))
        }
        let prompt = OwnerConfirmPrompt(request: request)
        open = prompt
        let deadline = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.withdraw(prompt)
        }
        prompt.reply = { [weak self] confirmed in
            deadline.cancel()
            self?.finish(prompt)
            self?.send(conn, OwnerConfirmReply(decision: confirmed ? OwnerConfirmReply.confirmed : OwnerConfirmReply.denied))
        }
        watchHangUp(conn, prompt: prompt)
        present(prompt)
    }

    /// The CLI sends nothing after its line: any read completing means it
    /// hung up (or the connection broke), and the request is withdrawn.
    private func watchHangUp(_ conn: NWConnection, prompt: OwnerConfirmPrompt) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            MainActor.assumeIsolated { self?.withdraw(prompt) }
        }
    }

    private func withdraw(_ prompt: OwnerConfirmPrompt) {
        guard prompt.reply != nil else { return }
        prompt.onWithdraw?()
        prompt.answer(false)
    }

    private func finish(_ prompt: OwnerConfirmPrompt) {
        if open === prompt { open = nil }
    }

    private func send(_ conn: NWConnection, _ reply: OwnerConfirmReply) {
        guard var data = try? JSONEncoder().encode(reply) else { return conn.cancel() }
        data.append(UInt8(ascii: "\n"))
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}
