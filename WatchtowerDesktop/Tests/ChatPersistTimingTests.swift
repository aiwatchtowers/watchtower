import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The embedded chats' UX gate of the mobile Inbox spec §8 (ask #1361): an
/// embedded chat's first answer text arrives no more than 20 ms later on
/// `ai query --persist` than on the path it replaced. The main chat's half of
/// this gate went with #1170's `ai session --persist` path when main's chat
/// engine (#1822) took the main chat (ask #1469).
///
/// It runs the real CLI with `ai query`'s hidden `--test-stub-reply` (no
/// provider): set `WT_CHAT_TIMING_CLI` to a `watchtower` binary built from
/// this tree (`go build -o <dir>/watchtower .`). Without it, it skips (CI).
/// It measures relative cost from the process's own stdout timestamps and
/// never sleeps.
@MainActor
final class ChatPersistTimingTests: XCTestCase {
    private static let gate = 0.020

    /// The embedded chats' path (review I3), measured old against new in the
    /// same run, since both still exist as processes: the old path wrote the
    /// owner's rows in-process (GRDB) and then ran `ai query`; the new one
    /// runs `ai query --persist`, which writes them before the provider. The
    /// owner's message now shows at once (the engine's `pendingOwnerText`,
    /// set in the send itself — `EmbeddedChatEngineTests`), so the old path's
    /// write wait is gone; the first answer text must arrive no more than
    /// 20 ms later (median of 20 cold runs each, alternating).
    func testEmbeddedPathFirstTextNoWorseThanTwentyMilliseconds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let cli = env["WT_CHAT_TIMING_CLI"], FileManager.default.isExecutableFile(atPath: cli) else {
            throw XCTSkip("set WT_CHAT_TIMING_CLI to a watchtower binary built from this tree")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-timing-\(UUID().uuidString)")
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
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('', 'target', '1', 1, 1)
                """)
            return db.lastInsertedRowID
        }
        let base = ["--config", config.path, "ai", "query", "--prompt-stdin", "--events", "v2",
                    "--db-path", dbPath, "--test-stub-reply", "ok"]
        var old: [Double] = [], new: [Double] = [], oldOwner: [Double] = []
        for index in 0...20 {
            let turnID = "turn-\(index)"
            // Old: the owner's rows in-process, then the plain run.
            let oldStart = ContinuousClock.now
            _ = try await dbManager.dbPool.write { db in
                try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: convID, ownerText: "q", turnID: "old-\(turnID)",
                                                         provider: nil, now: Date().timeIntervalSince1970)
            }
            let ownerShown = ContinuousClock.now
            let oldText = try await Self.firstText(cli: cli, arguments: base, stdin: #"{"prompt":"q"}"#,
                                                   environment: environment)
            // New: the run writes them (`--persist`), the bubble showed at Send.
            let newStart = ContinuousClock.now
            let newText = try await Self.firstText(
                cli: cli, arguments: base + ["--persist", "--conversation", String(convID), "--turn", turnID],
                stdin: #"{"prompt":"q","owner_text":"q"}"#, environment: environment)
            guard index > 0 else { continue } // the first pair warms the file cache
            oldOwner.append(Self.seconds(ownerShown - oldStart))
            old.append(Self.seconds(oldText - oldStart))
            new.append(Self.seconds(newText - newStart))
        }
        let (oldMedian, newMedian) = (Self.median(old), Self.median(new))
        print(String(format: "ChatPersistTimingTests (embedded): first text old %.2f ms, new %.2f ms (%+.2f ms); "
                     + "owner shown old %.2f ms, new at Send",
                     oldMedian * 1000, newMedian * 1000, (newMedian - oldMedian) * 1000, Self.median(oldOwner) * 1000))
        XCTAssertLessThanOrEqual(newMedian - oldMedian, Self.gate,
                                 "an embedded chat's first text arrives \(Int((newMedian - oldMedian) * 1000)) ms later")
    }

    /// When the run's first `text` line came out of its stdout.
    private static func firstText(
        cli: String, arguments: [String], stdin: String, environment: [String: String]
    ) async throws -> ContinuousClock.Instant {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        var seen: ContinuousClock.Instant?
        for try await line in output.fileHandleForReading.bytes.lines where seen == nil {
            if line.contains(#""type":"text_delta""#) { seen = .now }
        }
        process.waitUntilExit()
        return try XCTUnwrap(seen, "the run printed no text event")
    }

    /// Runs the CLI once so it creates and migrates the database.
    private func migrate(cli: String, config: String, dbPath: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        // `ai query --persist` opens (and migrates) the database before it
        // finds no such conversation and stops.
        process.arguments = ["--config", config, "ai", "query", "--prompt-stdin", "--events", "v2", "--db-path", dbPath,
                             "--persist", "--conversation", "999999", "--turn", "warm", "--test-stub-reply", "ok"]
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"prompt":"q","owner_text":"q"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

}
