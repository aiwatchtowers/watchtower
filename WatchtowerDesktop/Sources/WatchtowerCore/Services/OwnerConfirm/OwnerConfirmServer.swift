import Foundation

/// One request from the CLI — Go `ownerconfirm.Request`, one JSON line.
package struct OwnerConfirmRequest: Codable, Equatable, Sendable {
    package let v: Int
    package let verb: String
    package let detail: String?
    package let args: [String]

    package init(v: Int = 1, verb: String, detail: String? = nil, args: [String]) {
        self.v = v
        self.verb = verb
        self.detail = detail
        self.args = args
    }

    /// The command as the window shows it, in full: `watchtower` and the
    /// args, each arg that is not plain `[A-Za-z0-9._/=:@%+-]` single-quoted
    /// the shell's way (so word boundaries are unambiguous), control and
    /// format characters (bidi overrides, zero-width marks, line breaks)
    /// replaced so it reads as it runs.
    package var commandLine: String {
        Self.displayable((["watchtower"] + args.map(Self.shellQuoted)).joined(separator: " "))
    }

    package static func shellQuoted(_ arg: String) -> String {
        let plain = !arg.isEmpty && arg.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._/=:@%+-".unicodeScalars.contains(scalar))
        }
        if plain { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The detail in full, line breaks kept, other control and format
    /// characters replaced.
    package var displayDetail: String? {
        guard let detail, !detail.isEmpty else { return nil }
        return Self.displayable(detail, keepingLineBreaks: true)
    }

    package static func displayable(_ text: String, keepingLineBreaks: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if keepingLineBreaks, scalar == "\n" || scalar == "\t" {
                out.append(scalar)
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                out.append("\u{FFFD}")
            default:
                out.append(scalar)
            }
        }
        return String(out)
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

/// Serves `<workspace>/owner-confirm.sock` (AGENT-07, board #568, owner
/// decision ask #357; Go `internal/ownerconfirm`): a CLI without an agent
/// marker asks before an owner-only gesture, after checking this process's
/// code signature. A command this Desktop started — the same argv from the
/// same pid (`OwnerConfirmGrants`) — is confirmed at once; any other request
/// opens one confirmation window (`present`) and is answered with the
/// owner's click. One window at a time, at most `maxConnections` open
/// connections, a request line must arrive within `readTimeout`. There is no
/// CLI, MCP or file path to answer — only `OwnerConfirmPrompt.answer`, which
/// the window's buttons call.
@MainActor
package final class OwnerConfirmServer {
    /// How long a window may wait for the owner — past the CLI's own wait
    /// (Go `ownerconfirm.Wait`, 100 s), which ends the request first.
    package nonisolated static let promptTimeout: Duration = .seconds(110)
    /// Longest request line read.
    package nonisolated static let maxRequestBytes = 64 * 1024
    /// Open connections at once; more are closed unread.
    package nonisolated static let maxConnections = 8
    /// Seconds a connection has to send its request line.
    package nonisolated static let readTimeout: TimeInterval = 5
    /// How long a request that matches no grant waits for the Desktop's own
    /// just-started child to be registered before it gets a window.
    package nonisolated static let grantGrace: Duration = .milliseconds(300)
    /// `sun_path` holds 104 bytes on macOS, the terminating NUL included.
    package nonisolated static let maxPathBytes = 103
    package nonisolated static let fileName = "owner-confirm.sock"
    /// After a window ends without Confirm (Deny, timeout, hang-up), no new
    /// window opens for this long, whoever asks: a loop of fresh CLI
    /// processes cannot keep reopening windows and holding the one slot. The
    /// Desktop's own launches are confirmed by their grant before any window
    /// and are not held back.
    package nonisolated static let deniedCooldown: Duration = .seconds(3)
    package nonisolated static let cooldownReason = "denied a moment ago — wait a few seconds before asking again"

    package enum ServerError: Error, Equatable {
        case pathTooLong
        case anotherServer
        case socket(Int32)
    }

    /// The socket next to the workspace database (Go `ownerconfirm.SocketPath`).
    package static func socketPath(databasePath: String) -> String {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    private let path: String
    private let grants: OwnerConfirmGrants
    private let present: (OwnerConfirmPrompt) -> Void
    private let timeout: Duration
    private let cooldown: Duration
    private var cooldownUntil: ContinuousClock.Instant?
    private let io = OwnerConfirmIO()
    private var open: (prompt: OwnerConfirmPrompt, box: OwnerConfirmReplyBox)?

    package init(
        path: String,
        grants: OwnerConfirmGrants = .shared,
        timeout: Duration = promptTimeout,
        cooldown: Duration = deniedCooldown,
        present: @escaping (OwnerConfirmPrompt) -> Void
    ) {
        self.path = path
        self.grants = grants
        self.timeout = timeout
        self.cooldown = cooldown
        self.present = present
    }

    /// Binds the socket (mode 0600). A stale socket file is replaced; one a
    /// live process serves is left alone (`anotherServer`).
    package func start() throws {
        guard path.utf8.count <= Self.maxPathBytes else { throw ServerError.pathTooLong }
        if FileManager.default.fileExists(atPath: path) {
            if OwnerConfirmIO.answers(path) { throw ServerError.anotherServer }
            unlink(path)
        }
        try io.listen(
            path: path,
            pastCap: { [grants] pid in grants.hasLive(pid: pid) },
            serve: { [weak self] fd in self?.serve(fd) }
        )
    }

    /// Closes the socket and removes its file; an open window is withdrawn.
    package func stop() {
        io.stop()
        unlink(path)
        if let open { withdraw(open.box) }
    }

    /// One connection, on the IO queue: read the line, ask the main actor,
    /// watch for a hang-up while the owner decides, write the answer.
    nonisolated private func serve(_ fd: Int32) {
        guard let line = OwnerConfirmIO.readLine(fd, limit: Self.maxRequestBytes, within: Self.readTimeout) else {
            return
        }
        let pid = OwnerConfirmIO.peerPID(fd)
        let box = OwnerConfirmReplyBox()
        guard let request = try? JSONDecoder().decode(OwnerConfirmRequest.self, from: line) else {
            return OwnerConfirmIO.write(fd, OwnerConfirmReply(decision: OwnerConfirmReply.denied,
                                                              reason: "the request was not readable"))
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return box.set(OwnerConfirmReply(decision: OwnerConfirmReply.denied)) }
                self.route(request, pid: pid, box: box)
            }
        }
        var withdrawn = false
        while true {
            if let reply = box.wait(seconds: 0.2) {
                return OwnerConfirmIO.write(fd, reply)
            }
            if !withdrawn, OwnerConfirmIO.hungUp(fd) {
                withdrawn = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.withdraw(box) }
                }
            }
        }
    }

    private func route(_ request: OwnerConfirmRequest, pid: Int32?, box: OwnerConfirmReplyBox) {
        Task { [weak self, grants] in
            // The child may ask before ProcessCLIRunner registered its pid.
            let deadline = ContinuousClock.now + Self.grantGrace
            repeat {
                if let pid, grants.consume(request.args, pid: pid) {
                    return box.set(OwnerConfirmReply(decision: OwnerConfirmReply.confirmed))
                }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline && !box.isSet
            self?.openPrompt(request, box: box)
        }
    }

    private func openPrompt(_ request: OwnerConfirmRequest, box: OwnerConfirmReplyBox) {
        guard !box.isSet else { return } // hung up meanwhile
        if let until = cooldownUntil, ContinuousClock.now < until {
            return box.set(OwnerConfirmReply(decision: OwnerConfirmReply.denied, reason: Self.cooldownReason))
        }
        guard open == nil else {
            return box.set(OwnerConfirmReply(decision: OwnerConfirmReply.denied,
                                             reason: "another confirmation is already open"))
        }
        let prompt = OwnerConfirmPrompt(request: request)
        open = (prompt, box)
        let deadline = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.withdraw(box)
        }
        prompt.reply = { [weak self] confirmed in
            deadline.cancel()
            box.set(OwnerConfirmReply(decision: confirmed ? OwnerConfirmReply.confirmed : OwnerConfirmReply.denied))
            guard let self else { return }
            if open?.box === box { open = nil }
            if !confirmed { cooldownUntil = ContinuousClock.now + cooldown }
        }
        present(prompt)
    }

    /// The request ends without a click: its window closes and it is denied.
    private func withdraw(_ box: OwnerConfirmReplyBox) {
        if let open, open.box === box {
            open.prompt.onWithdraw?()
            open.prompt.answer(false)
        } else {
            box.set(OwnerConfirmReply(decision: OwnerConfirmReply.denied))
        }
    }
}

/// One request's answer, handed from the main actor to its connection.
final class OwnerConfirmReplyBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var reply: OwnerConfirmReply?

    var isSet: Bool {
        condition.lock()
        defer { condition.unlock() }
        return reply != nil
    }

    /// The first answer wins.
    func set(_ value: OwnerConfirmReply) {
        condition.lock()
        if reply == nil { reply = value }
        condition.broadcast()
        condition.unlock()
    }

    func wait(seconds: TimeInterval) -> OwnerConfirmReply? {
        condition.lock()
        defer { condition.unlock() }
        if reply == nil { _ = condition.wait(until: Date().addingTimeInterval(seconds)) }
        return reply
    }
}
