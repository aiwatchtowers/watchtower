import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The chat UX gate of the mobile Inbox spec §8 (ask #1361): a send's first
/// answer text arrives no more than 20 ms later (median of 30 turns) than on
/// the path it replaced — the Swift `persistTurnStart` and a plain `ai
/// session`. The baseline (`Core/Fixtures/chat_persist_timing_baseline.json`)
/// was recorded once on the old path with `WT_CHAT_TIMING_RECORD=1`; this run
/// measures the current path on the same machine kind and compares medians.
///
/// It runs the real CLI with its hidden `--test-stub-reply` (no provider): set
/// `WT_CHAT_TIMING_CLI` to a `watchtower` binary built from this tree
/// (`go build -o <dir>/watchtower .`). Without it, or without a baseline, it
/// skips (CI). It measures relative cost from the process's own stdout
/// timestamps and never sleeps.
@MainActor
final class ChatPersistTimingTests: XCTestCase {
    private static let turns = 30
    private static let gate = 0.020

    private static var baselineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/chat_persist_timing_baseline.json")
    }

    func testStubProviderMedianNoWorseThanTwentyMilliseconds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let cli = env["WT_CHAT_TIMING_CLI"], FileManager.default.isExecutableFile(atPath: cli) else {
            throw XCTSkip("set WT_CHAT_TIMING_CLI to a watchtower binary built from this tree")
        }
        let recording = env["WT_CHAT_TIMING_RECORD"] == "1"
        let baseline = try? JSONDecoder().decode(Baseline.self, from: Data(contentsOf: Self.baselineURL))
        if !recording, baseline == nil { throw XCTSkip("no recorded baseline") }

        let samples = try await measure(cli: cli)
        let median = Self.median(samples)
        if recording {
            let data = try JSONEncoder.sortedPretty.encode(Baseline(medianSeconds: median, samples: samples))
            try data.write(to: Self.baselineURL)
            return
        }
        let base = try XCTUnwrap(baseline)
        let slower = median - base.medianSeconds
        print(String(format: "ChatPersistTimingTests: median %.2f ms (baseline %.2f ms, %+.2f ms)",
                     median * 1000, base.medianSeconds * 1000, slower * 1000))
        XCTAssertLessThanOrEqual(slower, Self.gate,
                                 "the first answer text arrives \(Int(slower * 1000)) ms later than on the old path")
    }

    // MARK: - Measuring

    private func measure(cli: String) async throws -> [Double] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-timing-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.yaml")
        try Data("active_workspace: test-ws\nworkspaces:\n  test-ws:\n    slack_token: \"xoxp-test-token\"\n".utf8)
            .write(to: config)
        let dbPath = dir.appendingPathComponent("watchtower.db").path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TMPDIR"] = dir.path + "/"

        try migrate(cli: cli, config: config.path, dbPath: dbPath, environment: environment)
        let dbManager = try DatabaseManager(path: dbPath)
        let convID = try await dbManager.dbPool.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)")
            return db.lastInsertedRowID
        }
        let recorder = FirstTextRecorder()
        let extra = ["--config", config.path, "--test-stub-reply", "ok"]
        let pool = ChatSessionPool(dbPool: dbManager.dbPool, processFactory: { args in
            let inner = try FoundationChatSessionProcess(executable: cli, arguments: args + extra, environment: environment)
            return TimedProcess(inner: inner, recorder: recorder)
        }, closeGrace: .seconds(2))
        var counter = 0
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatPersistTimingTests.\(UUID().uuidString)"))
        let vm = ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, defaults: defaults,
                               attachmentsRoot: dir.appendingPathComponent("attachments")) {
            counter += 1
            return "turn-\(counter)"
        }
        vm.select(conversationID: convID)

        var samples: [Double] = []
        // Turn 0 warms the session (spawn, provider start) and is not counted.
        for index in 0...Self.turns {
            let turnID = "turn-\(index + 1)"
            let sentAt = ContinuousClock.now
            let sent = await vm.send(text: "question \(index)")
            XCTAssertTrue(sent, "turn \(index) was not sent")
            guard sent else { break }
            let firstText = await recorder.firstText(of: turnID)
            await waitForCondition { !vm.isBusy }
            if index > 0 { samples.append(Self.seconds(firstText - sentAt)) }
        }
        await pool.closeAll()
        return samples
    }

    /// Runs the CLI once so it creates and migrates the database.
    private func migrate(cli: String, config: String, dbPath: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--config", config, "ai", "session", "--conversation", "999999", "--db-path", dbPath]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private struct Baseline: Codable {
        let medianSeconds: Double
        let samples: [Double]
    }
}

/// When each turn's first text event left the process's stdout reader.
private final class FirstTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: ContinuousClock.Instant] = [:]
    private let signal = StateSignal()

    func record(_ turnID: String) {
        lock.lock()
        if seen[turnID] == nil { seen[turnID] = .now }
        lock.unlock()
        signal.changed()
    }

    func firstText(of turnID: String) async -> ContinuousClock.Instant {
        await signal.until { [self] in instant(turnID) != nil }
        return instant(turnID) ?? .now
    }

    private func instant(_ turnID: String) -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return seen[turnID]
    }
}

/// The real process, with each turn's first text delta timestamped as it is
/// read (off the main actor), before the client sees it.
private final class TimedProcess: ChatSessionProcess, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let inner: any ChatSessionProcess

    init(inner: any ChatSessionProcess, recorder: FirstTextRecorder) {
        self.inner = inner
        let (stream, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
        events = stream
        let source = inner.events
        Task.detached {
            for await event in source {
                if case let .textDelta(turnID, _) = event { recorder.record(turnID) }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func send(_ command: ChatCommand) throws { try inner.send(command) }
    func terminate() { inner.terminate() }
    func kill() { inner.kill() }
}

private extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
