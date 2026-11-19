import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Settings → Mobile → Diagnostics over `watchtower hub diagnostics --days 7
/// --json` (go hub plan 4 Task 9, mockup §22–§23, coverage rows 26–43).
@MainActor
final class MobileDiagnosticsModelTests: XCTestCase {
    typealias Model = MobileDiagnosticsModel
    private var cli: ScriptedHubCLI!

    override func setUp() async throws {
        cli = ScriptedHubCLI()
    }

    private static func row(_ step: String, _ transport: String, p50: Int, p90: Int, samples: Int) -> String {
        #"{"step":"\#(step)","transport":"\#(transport)","p50_ms":\#(p50),"p90_ms":\#(p90),"samples":\#(samples)}"#
    }

    private static func json(rows: [String], overflow: Int = 0) -> String {
        #"{"window_days":7,"rows":[\#(rows.joined(separator: ","))],"push_overflow_expired":\#(overflow)}"#
    }

    /// The mockup's rows, in the CLI's order (step, then transport).
    private static let mockupRows = [
        row("applied_saved", "cloudkit", p50: 2400, p90: 4000, samples: 7),
        row("applied_saved", "relay", p50: 190, p90: 410, samples: 42),
        row("read_applied", "cloudkit", p50: 2100, p90: 9800, samples: 7),
        row("read_applied", "relay", p50: 38, p90: 120, samples: 42),
        row("read_saved", "cloudkit", p50: 4500, p90: 4500, samples: 1),
        row("read_saved", "relay", p50: 230, p90: 480, samples: 42)
    ]

    private func loaded(_ json: String) async -> Model {
        cli.answer(MobileHubCLI.diagnosticsArgs, json)
        let model = Model(cli: cli)
        await model.load()
        return model
    }

    private func rows(_ model: Model) -> [Model.Row] {
        guard case .rows(let rows) = model.state else { return [] }
        return rows
    }

    // MARK: - Rows

    func testRowsFromPinnedJSON() async {
        let model = await loaded(Self.json(rows: Self.mockupRows))
        XCTAssertEqual(cli.invocations, [["hub", "diagnostics", "--days", "7", "--json"]])
        XCTAssertEqual(cli.timeout(for: MobileHubCLI.diagnosticsArgs), MobileHubCLI.readTimeout)
        let shown = rows(model).map { [$0.stepLabel, $0.transportLabel, $0.p50, $0.p90, $0.samples] }
        XCTAssertEqual(shown, [
            ["Phone action read → applied", "Relay", "p50 38 ms", "p90 120 ms", "42 samples"],
            ["Applied → slice saved", "Relay", "p50 190 ms", "p90 410 ms", "42 samples"],
            ["Phone action read → slice saved", "Relay", "p50 230 ms", "p90 480 ms", "42 samples"],
            ["Phone action read → applied", "iCloud", "p50 2.1 s", "p90 9.8 s", "7 samples"],
            ["Applied → slice saved", "iCloud", "p50 2.4 s", "p90 4.0 s", "7 samples"],
            ["Phone action read → slice saved", "iCloud", "p50 4.5 s", "p90 4.5 s", "1 sample"]
        ])
        XCTAssertEqual(rows(model).map(\.transport), ["relay", "relay", "relay", "cloudkit", "cloudkit", "cloudkit"])
        XCTAssertEqual(Set(rows(model).map(\.id)).count, 6)
        XCTAssertNil(model.overGoalLine)
        XCTAssertNil(model.overflowLine)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(Model.caption, "Content-free timings kept on this Mac only.")
        XCTAssertEqual(Model.entryTitle, "Diagnostics")
    }

    func testAStepOrTransportItDoesNotKnowIsLeftOut() async {
        let model = await loaded(Self.json(rows: [
            Self.row("read_applied", "relay", p50: 38, p90: 120, samples: 2),
            Self.row("something_new", "relay", p50: 1, p90: 1, samples: 1),
            Self.row("read_applied", "carrier_pigeon", p50: 1, p90: 1, samples: 1)
        ]))
        XCTAssertEqual(rows(model).map(\.stepLabel), ["Phone action read → applied"])
    }

    func testDurationFormatting() {
        XCTAssertEqual(Model.duration(ms: 0), "0 ms")
        XCTAssertEqual(Model.duration(ms: 38), "38 ms")
        XCTAssertEqual(Model.duration(ms: 999), "999 ms")
        XCTAssertEqual(Model.duration(ms: 1000), "1.0 s")
        XCTAssertEqual(Model.duration(ms: 1100), "1.1 s")
        XCTAssertEqual(Model.duration(ms: 2149), "2.1 s")
        XCTAssertEqual(Model.duration(ms: 9800), "9.8 s")
        XCTAssertEqual(Model.duration(ms: 61_000), "61.0 s")
        XCTAssertEqual(Model.samplesText(1), "1 sample")
        XCTAssertEqual(Model.samplesText(2), "2 samples")
        XCTAssertEqual(Model.samplesText(42), "42 samples")
    }

    func testEmptyWhenNoRows() async {
        let model = await loaded(Self.json(rows: []))
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(Model.emptyText, "No timings yet. They appear after the first action from a phone.")
        XCTAssertNil(model.overGoalLine)
        XCTAssertNil(model.overflowLine)
    }

    func testLoadingUntilTheFirstRead() {
        XCTAssertEqual(Model(cli: cli).state, .loading)
    }

    func testErrorThenRetryLoads() async {
        cli.fail(MobileHubCLI.diagnosticsArgs, stderr: "Error: database is locked")
        let model = Model(cli: cli)
        await model.load()
        XCTAssertEqual(model.state, .error("Couldn't read the timings."))
        XCTAssertEqual(Model.errorText, "Couldn't read the timings.")
        XCTAssertEqual(Model.retryTitle, "Retry")
        XCTAssertEqual(Model.doneTitle, "Done")
        XCTAssertNil(model.overGoalLine)
        XCTAssertNil(model.overflowLine)

        cli.answer(MobileHubCLI.diagnosticsArgs, Self.json(rows: Self.mockupRows))
        await model.load()
        XCTAssertEqual(rows(model).count, 6)
        XCTAssertEqual(cli.invocations.count, 2)
    }

    func testNoBinaryIsTheError() async {
        let model = Model(cli: nil)
        await model.load()
        XCTAssertEqual(model.state, .error(Model.errorText))
    }

    func testRefreshKeepsTheRowsAndShowsBusy() async {
        let model = await loaded(Self.json(rows: Self.mockupRows))
        let probe = RefreshProbe()
        cli.onRun = { _ in
            await MainActor.run {
                probe.refreshing = model.isRefreshing
                probe.rows = { if case .rows = model.state { true } else { false } }()
            }
        }
        await model.load()
        XCTAssertTrue(probe.refreshing)
        XCTAssertTrue(probe.rows)
        XCTAssertFalse(model.isRefreshing)
    }

    func testAFailedRefreshShowsTheError() async {
        let model = await loaded(Self.json(rows: Self.mockupRows, overflow: 2))
        cli.fail(MobileHubCLI.diagnosticsArgs, stderr: "Error: boom")
        await model.load()
        XCTAssertEqual(model.state, .error(Model.errorText))
        XCTAssertNil(model.overflowLine)
        XCTAssertFalse(model.isRefreshing)
    }

    // MARK: - Over the goal

    func testOverGoalLineOnlyOnRelay() async {
        XCTAssertEqual(Model.overGoalText, "This Mac's part alone is over the 500 ms goal.")
        let cases: [(transport: String, p50: Int, line: Bool)] = [
            ("relay", 640, true), ("relay", 500, true), ("relay", 499, false),
            ("cloudkit", 4500, false), ("cloudkit", 500, false)
        ]
        for item in cases {
            let model = await loaded(Self.json(rows: [Self.row("read_saved", item.transport, p50: item.p50, p90: 9000, samples: 3)]))
            XCTAssertEqual(model.overGoalLine, item.line ? Model.overGoalText : nil, "\(item)")
        }
    }

    func testOverGoalUsesTheTotalNotASumOfMedians() async {
        let model = await loaded(Self.json(rows: [
            Self.row("read_applied", "relay", p50: 300, p90: 900, samples: 9),
            Self.row("applied_saved", "relay", p50: 300, p90: 900, samples: 9),
            Self.row("read_saved", "relay", p50: 450, p90: 900, samples: 9)
        ]))
        XCTAssertNil(model.overGoalLine)
        let steps = await loaded(Self.json(rows: [
            Self.row("read_applied", "relay", p50: 900, p90: 900, samples: 9),
            Self.row("applied_saved", "relay", p50: 900, p90: 900, samples: 9)
        ]))
        XCTAssertNil(steps.overGoalLine, "no read_saved row, no line")
    }

    // MARK: - Overflow

    func testOverflowLineSingularPlural() async {
        XCTAssertEqual(Model.overflowText(1), "1 alert was dropped because too many were waiting.")
        XCTAssertEqual(Model.overflowText(4), "4 alerts were dropped because too many were waiting.")
        for (count, line) in [(0, nil), (1, Model.overflowText(1)), (4, Model.overflowText(4))] {
            let model = await loaded(Self.json(rows: Self.mockupRows, overflow: count))
            XCTAssertEqual(model.overflowLine, line)
            let empty = await loaded(Self.json(rows: [], overflow: count))
            XCTAssertEqual(empty.overflowLine, line)
        }
    }

    // MARK: - Every combination (coverage rows 27–43)

    enum Kind: CaseIterable { case loading, empty, rows, error }

    struct Combo {
        let kind: Kind
        let refreshing: Bool
        let overGoal: Bool
        let overflow: Int

        /// Over goal only with rows; nothing else with loading or error;
        /// busy only over a read it shows.
        var isValid: Bool {
            let shows = kind == .rows || kind == .empty
            if overGoal && kind != .rows { return false }
            return shows || (!refreshing && overflow == 0)
        }
    }

    func testEveryCoOccurringCombinationShowsEachLine() async throws {
        let all = Kind.allCases.flatMap { kind in
            [false, true].flatMap { refreshing in
                [false, true].flatMap { overGoal in
                    [0, 1, 4].map { Combo(kind: kind, refreshing: refreshing, overGoal: overGoal, overflow: $0) }
                }
            }
        }
        let combos = all.filter(\.isValid)
        // loading 1 + error 1 + empty 2×3 + rows 2×2×3.
        XCTAssertEqual(combos.count, 20)
        for combo in combos {
            try assertShows(combo)
        }
    }

    private func assertShows(_ combo: Combo) throws {
        let overGoalRow = Self.row("read_saved", "relay", p50: 640, p90: 1100, samples: 42)
        let underGoalRow = Self.row("read_saved", "relay", p50: 230, p90: 480, samples: 42)
        let model = Model(cli: cli)
        switch combo.kind {
        case .loading: break
        case .error: model.presentFailure()
        case .empty: model.present(try Self.decode(Self.json(rows: [], overflow: combo.overflow)))
        case .rows:
            let row = combo.overGoal ? overGoalRow : underGoalRow
            model.present(try Self.decode(Self.json(rows: [row], overflow: combo.overflow)))
        }
        model.isRefreshing = combo.refreshing
        let label = "\(combo)"
        switch combo.kind {
        case .loading: XCTAssertEqual(model.state, .loading, label)
        case .error: XCTAssertEqual(model.state, .error("Couldn't read the timings."), label)
        case .empty: XCTAssertEqual(model.state, .empty, label)
        case .rows:
            XCTAssertEqual(rows(model).map(\.stepLabel), ["Phone action read → slice saved"], label)
            XCTAssertEqual(rows(model).first?.p50, combo.overGoal ? "p50 640 ms" : "p50 230 ms", label)
        }
        XCTAssertEqual(model.isRefreshing, combo.refreshing, label)
        XCTAssertEqual(model.overGoalLine, combo.overGoal ? "This Mac's part alone is over the 500 ms goal." : nil, label)
        let overflowLine: String? = switch combo.overflow {
        case 1: "1 alert was dropped because too many were waiting."
        case 4: "4 alerts were dropped because too many were waiting."
        default: nil
        }
        XCTAssertEqual(model.overflowLine, overflowLine, label)
    }

    private static func decode(_ json: String) throws -> MobileHubCLI.Diagnostics {
        try MobileHubCLI.decodeDiagnostics(Data(json.utf8))
    }

    // MARK: - Strings and the sidecar

    func testEveryUIStringLivesInTheModel() throws {
        XCTAssertEqual(try swiftStringLiterals(in: "Sources/Views/Settings/MobileDiagnosticsView.swift"), [])
    }

    func testNeverOpensTheSidecar() throws {
        for file in ["Sources/ViewModels/MobileDiagnosticsModel.swift", "Sources/Views/Settings/MobileDiagnosticsView.swift"] {
            for literal in try swiftStringLiterals(in: file, keepSymbols: true) {
                XCTAssertFalse(literal.contains("hubstate.db"), "\(file): \(literal)")
                XCTAssertFalse(literal.contains("MobileHub"), "\(file): \(literal)")
            }
        }
    }
}

private final class RefreshProbe: @unchecked Sendable {
    var refreshing = false
    var rows = false
}
