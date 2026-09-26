import XCTest
@testable import WatchtowerDesktop

final class MicActivityTests: XCTestCase {

    func testAccumulatorEmitsRMSPerBin() {
        // sampleRate 40 → 4 samples per 0.1 s bin.
        var acc = MicActivityAccumulator(sampleRate: 40)
        for _ in 0..<4 { acc.add(mic: 0.5, sys: 0.0) }
        for _ in 0..<4 { acc.add(mic: 0.0, sys: 0.25) }
        let lines = acc.flushLines()
        XCTAssertEqual(lines, ["0.500000 0.000000", "0.000000 0.250000"])
        XCTAssertEqual(acc.flushLines(), [], "flushed bins are not re-emitted")
    }

    func testAccumulatorKeepsPartialBinBuffered() {
        var acc = MicActivityAccumulator(sampleRate: 40)
        for _ in 0..<3 { acc.add(mic: 1.0, sys: 1.0) } // 3 of 4 samples
        XCTAssertEqual(acc.flushLines(), [])
    }

    func testLoadParsesSidecarAndIndexesByTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec_test.caf")
        try "0.100000 0.000000\n0.000000 0.300000\ngarbage line\n"
            .write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)

        let activity = try XCTUnwrap(MicActivity.load(for: audio))
        XCTAssertEqual(activity.bins.count, 2) // garbage line skipped
        XCTAssertEqual(activity.bin(at: 0.05), MicActivity.Bin(mic: 0.1, sys: 0.0))
        XCTAssertEqual(activity.bin(at: 0.15), MicActivity.Bin(mic: 0.0, sys: 0.3))
        XCTAssertNil(activity.bin(at: 0.25), "past the recorded end")
        XCTAssertNil(activity.bin(at: -1))
    }

    func testLoadMissingOrEmptySidecarReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec_test.caf")
        XCTAssertNil(MicActivity.load(for: audio)) // missing
        try "".write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)
        XCTAssertNil(MicActivity.load(for: audio)) // empty → degenerate, still nil
    }

    func testSidecarURLKeepsRecPrefix() {
        // The Go daemon's orphan sweep only manages rec_* files.
        let url = MicActivity.url(for: URL(fileURLWithPath: "/tmp/rec_20260715_120000.caf"))
        XCTAssertEqual(url.lastPathComponent, "rec_20260715_120000.activity")
    }
}
