import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Settings → Diagnostics (relay client Phase 4 Task 15, mockup S37–S40, S48): the timings' numbers and copy.
@MainActor
final class LatencyDiagnosticsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Boom: Error {}

    /// 214 samples whose sorted results give p50 310 / p90 700 and answers 120 / 300 (nearest rank).
    private func mockupSamples(_ transport: TransportKind) -> [LatencySample] {
        (0..<214).map { index in
            let (answer, result) = index < 107 ? (120, 310) : index < 193 ? (300, 700) : (500, 900)
            return LatencySample(at: now, transport: transport, answerMs: answer, resultMs: result)
        }
    }

    private func source(
        _ samples: [LatencySample] = [], ordered: Bool = true, fails: Bool = false
    ) -> LatencyHubSource {
        LatencyHubSource(
            samples: { _ in if fails { throw Boom() } else { return samples } },
            ordered: { ordered }
        )
    }

    private func reader(_ sources: [LatencyHubSource]) -> LatencyDiagnosticsReader {
        LatencyDiagnosticsReader(sources: { sources }, now: { self.now })
    }

    func testRowsForRelayAndICloud() {
        let rows = LatencyDiagnosticsModel.rows(mockupSamples(.cloudKit) + mockupSamples(.relay))
        XCTAssertEqual(rows, [
            .init(title: "Relay", count: "214 actions", result: "p50 0.31 s · p90 0.7 s", answer: "Mac's answer: p50 0.12 s · p90 0.3 s"),
            .init(title: "iCloud", count: "214 actions", result: "p50 0.31 s · p90 0.7 s", answer: "Mac's answer: p50 0.12 s · p90 0.3 s")
        ])
    }

    func testNearestRankPercentiles() {
        let ten = Array(1...10)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile(ten, 50), 5)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile(ten, 90), 9)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile([7], 50), 7)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile([7], 90), 7)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile([1, 2], 50), 1)
        XCTAssertEqual(LatencyDiagnosticsModel.percentile([1, 2], 90), 2)
    }

    func testSecondsFormat() {
        let table: [(Int, String)] = [
            (0, "0"), (5, "0.01"), (120, "0.12"), (300, "0.3"), (310, "0.31"), (700, "0.7"), (994, "0.99"),
            (995, "1.0"), (999, "1.0"), (1000, "1.0"), (1049, "1.0"), (6800, "6.8"), (9949, "9.9"), (9950, "10"),
            (10_000, "10"), (22_400, "22"), (22_500, "23")
        ]
        for (ms, text) in table {
            XCTAssertEqual(LatencyDiagnosticsModel.seconds(ms), text, "\(ms) ms")
        }
    }

    func testOneActionIsSingular() {
        let rows = LatencyDiagnosticsModel.rows([LatencySample(at: now, transport: .relay, answerMs: 100, resultMs: 200)])
        XCTAssertEqual(rows.map(\.count), ["1 action"])
        XCTAssertEqual(rows.first?.result, "p50 0.2 s · p90 0.2 s")
    }

    func testATransportWithNoSamplesHasNoRow() {
        let rows = LatencyDiagnosticsModel.rows(mockupSamples(.cloudKit))
        XCTAssertEqual(rows.map(\.title), ["iCloud"])
        XCTAssertEqual(LatencyDiagnosticsModel.rows([]), [])
    }

    func testEmptyLoadingAndFailedCopy() {
        XCTAssertEqual(LatencyDiagnosticsModel.header, "Action → result on screen · 7 days")
        XCTAssertEqual(LatencyDiagnosticsModel.footer, "Measured on this iPhone only. Nothing is sent anywhere.")
        XCTAssertEqual(LatencyDiagnosticsModel.emptyText, "No timings yet. They appear after your first action.")
        XCTAssertEqual(LatencyDiagnosticsModel.needsMacUpdateText, "Timings need an updated Watchtower on your Mac.")
        XCTAssertEqual(LatencyDiagnosticsModel.failedText, "Couldn't read the timings.")
        XCTAssertEqual(LatencyDiagnosticsModel.loadingText, "Reading timings…")
        XCTAssertEqual(LatencyDiagnosticsModel.retryTitle, "Retry")
        XCTAssertEqual(reader([source()]).state, .loading, "before the first read")
    }

    func testNoOrderedHubSaysToUpdateTheMac() async {
        let legacy = reader([source(ordered: false), source(ordered: false)])
        await legacy.load()
        XCTAssertEqual(legacy.state, .needsMacUpdate)
        let mixed = reader([source(ordered: false), source(ordered: true)])
        await mixed.load()
        XCTAssertEqual(mixed.state, .empty, "one hub on the ordered path: timings will come")
        let timed = reader([source(mockupSamples(.cloudKit), ordered: false)])
        await timed.load()
        XCTAssertEqual(timed.state, .rows(LatencyDiagnosticsModel.rows(mockupSamples(.cloudKit))), "samples win")
    }

    func testOneFailedReplicaFailsTheRead() async {
        let model = reader([source(mockupSamples(.cloudKit)), source(fails: true)])
        await model.load()
        XCTAssertEqual(model.state, .failed)
    }

    func testRetryReadsAgain() async {
        let flaky = FlakySource()
        let model = reader([LatencyHubSource(samples: { _ in try flaky.read() }, ordered: { true })])
        await model.load()
        XCTAssertEqual(model.state, .failed)
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(flaky.calls, 2)
    }

    func testHubsAreMerged() async {
        let relay = mockupSamples(.relay)
        let cloud = Array(mockupSamples(.cloudKit).prefix(3))
        let model = reader([source(relay), source(cloud)])
        await model.load()
        XCTAssertEqual(model.state, .rows(LatencyDiagnosticsModel.rows(relay + cloud)))
        guard case let .rows(rows) = model.state else { return XCTFail("rows") }
        XCTAssertEqual(rows.map(\.count), ["214 actions", "3 actions"])
    }

    func testTheWindowIsSevenDays() async {
        let seen = SinceBox()
        let model = reader([LatencyHubSource(samples: { since in seen.since = since; return [] }, ordered: { true })])
        await model.load()
        XCTAssertEqual(seen.since, now.addingTimeInterval(-604_800))
    }

    func testTonesAreDeclared() {
        let rows = LatencyDiagnosticsModel(state: .rows(LatencyDiagnosticsModel.rows(mockupSamples(.relay))))
        XCTAssertTrue(rows.toneUses.contains { $0.element == "diagnostics rows" && $0.tone == .secondary })
        XCTAssertTrue(LatencyDiagnosticsModel(state: .failed).toneUses.contains { $0.element == "diagnostics line" && $0.tone == .red })
        for state: LatencyDiagnosticsModel.State in [.loading, .empty, .needsMacUpdate, .failed, rows.state] {
            let uses = LatencyDiagnosticsModel(state: state).toneUses
            XCTAssertFalse(uses.isEmpty, "\(state)")
            XCTAssertTrue(uses.allSatisfy { $0.tone != .orange && !$0.isWaitingOrAsk }, "\(state)")
        }
    }
}

private final class FlakySource: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func read() throws -> [LatencySample] {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if calls == 1 { throw NSError(domain: "test", code: 1) }
        return []
    }
}

private final class SinceBox: @unchecked Sendable {
    var since: Date?
}
