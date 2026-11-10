import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

/// `workbench session start` as Go's Begin answers it (Go hub 3 Task 8): the
/// row written in the workbench folder — title, target and automation run
/// from the flags — and its id in the pinned JSON; `onStarted` then plays
/// the detached finish (e.g. `FakeGoSessionHost.launch`). Every other call
/// goes to `base` (empty when none). `refusal` fails a start before any row.
final class ScriptedSessionStartRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let pool: DatabasePool
    private let base: (any CLIRunnerProtocol)?
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var recordedStdin: [Data] = []
    private var ids: [Int64] = []
    var refusal: Error?
    var onStarted: (@Sendable (Int64) async -> Void)?

    init(pool: DatabasePool, base: (any CLIRunnerProtocol)? = nil) {
        self.pool = pool
        self.base = base
    }

    var invocations: [[String]] { lock.withLock { recorded } }
    var stdinInputs: [Data] { lock.withLock { recordedStdin } }
    var startedIDs: [Int64] { lock.withLock { ids } }

    func run(args: [String]) async throws -> Data {
        guard Self.isStart(args) else {
            lock.withLock { recorded.append(args) }
            return try await base?.run(args: args) ?? Data()
        }
        return try await start(args)
    }

    func run(args: [String], stdin: Data) async throws -> Data {
        guard Self.isStart(args) else {
            lock.withLock { recorded.append(args) }
            return try await base?.run(args: args, stdin: stdin) ?? Data()
        }
        lock.withLock { recordedStdin.append(stdin) }
        return try await start(args)
    }

    private static func isStart(_ args: [String]) -> Bool { args.starts(with: ["workbench", "session", "start"]) }

    private func start(_ args: [String]) async throws -> Data {
        lock.withLock { recorded.append(args) }
        if let refusal { throw refusal }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let workbench = Int64(value("--workbench") ?? "") ?? 0
        let agent = value("--agent") == "codex" ? TerminalSession.Kind.codex : .claude
        let row = try await pool.write { db -> TerminalSession in
            let folder = try String.fetchOne(db, sql: "SELECT folder_path FROM projects WHERE id = ?", arguments: [workbench]) ?? ""
            return try TerminalSessionQueries.create(db, .init(
                projectID: workbench, kind: agent, title: value("--title") ?? "s",
                targetID: value("--target").flatMap { Int64($0) }, folderPath: folder,
                claudeSessionID: agent == .claude ? UUID().uuidString.lowercased() : nil,
                automationRunID: value("--automation-run").flatMap { Int64($0) }
            ))
        }
        lock.withLock { ids.append(row.id) }
        await onStarted?(row.id)
        return Data("""
            {"session_id":\(row.id),"state":"starting","folder_path":"\(row.folderPath)","worktree_branch":""}
            """.utf8)
    }
}

/// A session host on a fake transport for a terminal center: Go's finish
/// "launches" a row by listing its run (`launch`), and the pane attaches.
@MainActor
final class FakeGoSessionHost {
    private(set) var transports: [FakeSessionHostTransport] = []
    private(set) var client: SessionHostClient!

    static func install(on center: TerminalCenter) async -> FakeGoSessionHost {
        let host = FakeGoSessionHost()
        host.client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak host] _ in
            let transport = FakeSessionHostTransport()
            host?.transports.append(transport)
            return transport
        })
        _ = await host.client.ensureRunning()
        center.sessionHost = host.client
        return host
    }

    var control: FakeSessionHostTransport { transports[0] }

    func launch(row: Int64, exited: Bool = false, code: Int? = nil) {
        control.listed.removeAll { $0.row == row }
        control.listed.append(SessionHostSessionInfo(row: row, run: "run-\(row)", pid: 4242,
                                                     startedAtMs: 1_760_000_000_000, exited: exited, code: code))
    }

    /// Detaches every attached pane, so no session connection outlives the test.
    func detachAll(_ center: TerminalCenter) {
        for id in center.liveIDs { (center.process(for: id) as? HostedTerminalSession)?.detachFromHost() }
    }
}
