import XCTest
@testable import WatchtowerCore

final class PipeLinesTests: XCTestCase {
    /// Foundation's `FileHandle.bytes` serializes every reader in the process
    /// on one actor, so a reader parked in `read()` on a silent pipe froze all
    /// others — a warm idle chat session stalled another conversation's turn
    /// until the idle one exited. A silent pipe must never delay another.
    func testSilentPipeDoesNotStallAnotherReader() async throws {
        let silent = Pipe()
        let busy = Pipe()
        let silentLines = silent.fileHandleForReading.ndjsonLines
        let parked = Task { for await _ in silentLines {} }
        defer {
            parked.cancel()
            try? silent.fileHandleForWriting.close()
        }
        // Give the silent reader time to park before the busy one starts.
        try await Task.sleep(for: .milliseconds(200))

        let busyLines = busy.fileHandleForReading.ndjsonLines
        let received = Task { () -> [String] in
            var lines: [String] = []
            for await line in busyLines {
                lines.append(line)
                if lines.count == 2 { break }
            }
            return lines
        }
        busy.fileHandleForWriting.write(Data("one\ntw".utf8))
        busy.fileHandleForWriting.write(Data("o\u{85}\n".utf8))

        let lines = await value(of: received, within: .seconds(3))
        XCTAssertEqual(lines, ["one", "two\u{85}"])
    }

    /// EOF ends the stream and delivers an unterminated tail.
    func testEOFFinishesWithTail() async throws {
        let pipe = Pipe()
        let lines = pipe.fileHandleForReading.ndjsonLines
        pipe.fileHandleForWriting.write(Data("a\nb".utf8))
        try pipe.fileHandleForWriting.close()

        let all = Task { () -> [String] in
            var out: [String] = []
            for await line in lines { out.append(line) }
            return out
        }
        let result = await value(of: all, within: .seconds(3))
        XCTAssertEqual(result, ["a", "b"])
    }

    /// One `bytes` reader anywhere in the app is enough to stall every other
    /// one, so no source may iterate a handle's `bytes` (or `bytes.lines`).
    func testNoSourceReadsAFileHandleThroughBytes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk \(sources.path)")
        }
        // `for … in <handle>.bytes {` and `<handle>.bytes.lines`.
        let reader = try Regex(#"\.bytes(\.lines)?\s*\{|\.bytes\.lines"#)
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(text.firstMatch(of: reader), "\(url.lastPathComponent) reads a FileHandle via bytes; use ndjsonLines")
        }
        XCTAssertGreaterThan(scanned, 200, "the scan must actually walk the Swift sources")
    }

    /// The task's value, or — past `limit` — whatever it returns once
    /// cancelled (an `AsyncStream` loop ends on cancellation).
    private func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T {
        let watchdog = Task {
            try await Task.sleep(for: limit)
            task.cancel()
        }
        defer { watchdog.cancel() }
        return await task.value
    }
}
