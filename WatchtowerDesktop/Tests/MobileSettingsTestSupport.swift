import Foundation
import WatchtowerCore
@testable import WatchtowerDesktop

/// A `watchtower` CLI that answers each argv with its scripted output or
/// error (an unscripted call answers `{}`), and records every call.
final class ScriptedHubCLI: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]: Result<Data, any Error>] = [:]
    private var recorded: [[String]] = []
    private var timeouts: [[String]: TimeInterval] = [:]
    private var recordedUntimed: [[String]] = []
    /// Runs inside every call, before it answers (a call that takes time).
    var onRun: (@Sendable ([String]) async -> Void)?

    var invocations: [[String]] { lock.withLock { recorded } }

    /// The calls other than the reads every load makes.
    var writes: [[String]] {
        invocations.filter {
            ![MobileHubCLI.statusArgs, MobileHubCLI.phonesArgs, MobileHubCLI.recordingJobsArgs].contains($0)
        }
    }

    func answer(_ args: [String], _ json: String) {
        lock.withLock { answers[args] = .success(Data(json.utf8)) }
    }

    func fail(_ args: [String], stderr: String) {
        lock.withLock { answers[args] = .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: stderr)) }
    }

    /// The call ends cancelled (the tab's task went away mid-read).
    func cancel(_ args: [String]) {
        lock.withLock { answers[args] = .failure(CancellationError()) }
    }

    /// The call ends as a timed-out run does (`nonZeroExit(code: -1, …)`).
    func failAsTimeout(_ args: [String]) {
        lock.withLock { answers[args] = .failure(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out")) }
    }

    /// The timeout the last call of args was given.
    func timeout(for args: [String]) -> TimeInterval? { lock.withLock { timeouts[args] } }

    /// Calls made without a timeout.
    var untimed: [[String]] { lock.withLock { recordedUntimed } }

    func run(args: [String], timeout: TimeInterval) async throws -> Data {
        lock.withLock { timeouts[args] = timeout }
        return try await answered(args)
    }

    func status(_ json: String) { answer(MobileHubCLI.statusArgs, json) }
    func phones(_ json: String) { answer(MobileHubCLI.phonesArgs, json) }

    func run(args: [String]) async throws -> Data {
        lock.withLock { recordedUntimed.append(args) }
        return try await answered(args)
    }

    private func answered(_ args: [String]) async throws -> Data {
        let answer = lock.withLock { () -> Result<Data, any Error>? in
            recorded.append(args)
            return answers[args]
        }
        if let onRun { await onRun(args) }
        return try (answer ?? .success(Data("{}".utf8))).get()
    }
}

/// Fixture JSON on `acme` / `example.com` data, never live data.
enum MobileHubFixture {
    static let running = #"{"state":"running","reason":"","transport":"cloudkit","recordings":"on","name":"Work Mac"}"#
    static let phoneA = phone(id: "AAAA0001", name: "Phone A", transport: "relay", scope: "shared")
    static let phoneB = phone(id: "BBBB0002", name: "Phone B", transport: "cloudkit", scope: "private")

    static func phone(
        id: String,
        name: String,
        transport: String,
        scope: String = "shared",
        linkedAt: String = "2026-10-12T09:00:00Z",
        typing: Bool = false,
        typingRequested: Bool = false,
        permissions: Bool = false,
        permissionsRequested: Bool = false,
        startAllowed: Bool = false,
        startGranted: Bool = false
    ) -> String {
        """
        {"device_id":"\(id)","name":"\(name)","scope":"\(scope)","linked_at":"\(linkedAt)",\
        "typing_allowed":\(typing),"typing_requested":\(typingRequested),\
        "permissions_allowed":\(permissions),"permissions_requested":\(permissionsRequested),\
        "start_sessions_allowed":\(startAllowed),"start_sessions_granted":\(startGranted),\
        "ordered":false,"last_applied_action_seq":0,"transport":"\(transport)"}
        """
    }

    static func list(_ phones: String...) -> String { "[" + phones.joined(separator: ",") + "]" }
}

/// The pairing stream as scripted lines: each session started is kept, its
/// lines are pushed by the test, what it was sent and whether it stopped
/// are recorded.
@MainActor
final class FakePairStreamer: HubPairStreaming {
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var sentLines: [String] = []
        private var wasStopped = false
        let continuation: AsyncStream<String>.Continuation
        let lines: AsyncStream<String>
        var failureText: String?

        init() {
            (lines, continuation) = AsyncStream.makeStream(of: String.self)
        }

        var sent: [String] { lock.withLock { sentLines } }
        var stopped: Bool { lock.withLock { wasStopped } }

        func push(_ line: String) { continuation.yield(line) }
        func end() { continuation.finish() }

        var session: HubPairSession {
            HubPairSession(
                lines: lines,
                send: { [self] line in lock.withLock { sentLines.append(line) } },
                failure: { [self] in failureText },
                stop: { [self] in
                    lock.withLock { wasStopped = true }
                    continuation.finish()
                }
            )
        }
    }

    private(set) var sessions: [Session] = []
    var startError: (any Error)?

    func startPairing() async throws -> HubPairSession {
        if let startError { throw startError }
        let next = Session()
        sessions.append(next)
        return next.session
    }
}

/// Scans `file` (under `WatchtowerDesktop/`) for string literals, comments
/// stripped; the literals right after `systemImage:` / `systemName:` (SF
/// Symbol names) are left out.
func swiftStringLiterals(in file: String, keepSymbols: Bool = false) throws -> [String] {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = tests.deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let text = String(line)
        guard let comment = text.range(of: "//") else { return text }
        return String(text[..<comment.lowerBound])
    }
    let code = lines.joined(separator: "\n")
    let pattern = try NSRegularExpression(pattern: #"(systemImage:\s*|systemName:\s*)?"((?:[^"\\]|\\.)*)""#)
    let range = NSRange(code.startIndex..., in: code)
    return pattern.matches(in: code, range: range).compactMap { match in
        let isSymbol = match.range(at: 1).location != NSNotFound
        guard keepSymbols || !isSymbol, let literal = Range(match.range(at: 2), in: code) else { return nil }
        return String(code[literal])
    }
}
