import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Settings → Mobile → Diagnostics and its entry row (go hub plan 4 Task 9,
/// mockup `docs/design/mockups/go-hub/index.html` §22–§23, coverage rows
/// 26–43), on fixture timings. The model is shown one read; its own reads park.
@MainActor
enum MobileDiagnosticsShotFixtures {
    enum Frame: String, CaseIterable {
        case entry, rows, empty, loading, error, busy, narrow
        case overGoal, overGoalNarrow, overflowOne, overflowMany, overflowNarrow
        case allLines, emptyOverflow, busyOverGoal

        var name: String {
            "mobileDiagnostics" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }

        var size: NSSize {
            switch self {
            case .entry: NSSize(width: 640, height: 400)
            case .narrow, .overGoalNarrow, .overflowNarrow: NSSize(width: 480, height: 560)
            case .loading, .error: NSSize(width: 640, height: 120)
            case .empty: NSSize(width: 640, height: 160)
            case .emptyOverflow: NSSize(width: 640, height: 220)
            case .rows, .busy: NSSize(width: 640, height: 330)
            case .overGoal, .overflowOne, .overflowMany, .busyOverGoal: NSSize(width: 640, height: 390)
            case .allLines: NSSize(width: 640, height: 420)
            }
        }
    }

    static func screen(_ frame: Frame) -> AnyView {
        guard frame != .entry else { return entry() }
        let model = MobileDiagnosticsModel(cli: ParkedDiagnosticsCLI())
        switch frame {
        case .loading, .entry:
            break
        case .error:
            model.presentFailure()
        case .empty:
            model.present(diagnostics(rows: []))
        case .emptyOverflow:
            model.present(diagnostics(rows: [], overflow: 1))
        case .rows, .narrow:
            model.present(diagnostics(rows: underGoal))
        case .busy:
            model.present(diagnostics(rows: underGoal))
            model.isRefreshing = true
        case .overGoal, .overGoalNarrow:
            model.present(diagnostics(rows: overGoal))
        case .overflowOne:
            model.present(diagnostics(rows: underGoal, overflow: 1))
        case .overflowMany, .overflowNarrow:
            model.present(diagnostics(rows: underGoal, overflow: 4))
        case .allLines:
            model.present(diagnostics(rows: overGoal, overflow: 4))
        case .busyOverGoal:
            model.present(diagnostics(rows: overGoal))
            model.isRefreshing = true
        }
        return AnyView(MobileDiagnosticsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    /// Settings → Mobile on a running hub over Relay, with its Diagnostics row.
    private static func entry() -> AnyView {
        let defaults = UserDefaults(suiteName: "WatchtowerDesktopShots.mobileDiagnostics") ?? .standard
        let model = MobileSettingsModel(cli: ParkedDiagnosticsCLI(), defaults: defaults)
        model.present(
            status: MobileHubCLI.Status(state: "running", transport: "relay", recordings: "on", name: "Work Mac"),
            phones: [], jobs: nil
        )
        return AnyView(MobileSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    private typealias Row = MobileHubCLI.Diagnostics.Row

    private static func diagnostics(rows: [Row], overflow: Int = 0) -> MobileHubCLI.Diagnostics {
        MobileHubCLI.Diagnostics(windowDays: 7, rows: rows, pushOverflowExpired: overflow)
    }

    private static let iCloud = [
        Row(step: "read_applied", transport: "cloudkit", p50Ms: 2100, p90Ms: 9800, samples: 7),
        Row(step: "applied_saved", transport: "cloudkit", p50Ms: 2400, p90Ms: 4000, samples: 7),
        Row(step: "read_saved", transport: "cloudkit", p50Ms: 4500, p90Ms: 4500, samples: 1)
    ]

    /// The mockup's rows: Relay under the goal.
    private static let underGoal = [
        Row(step: "read_applied", transport: "relay", p50Ms: 38, p90Ms: 120, samples: 42),
        Row(step: "applied_saved", transport: "relay", p50Ms: 190, p90Ms: 410, samples: 42),
        Row(step: "read_saved", transport: "relay", p50Ms: 230, p90Ms: 480, samples: 42)
    ] + iCloud

    /// Relay's per-action total over the goal.
    private static let overGoal = [
        Row(step: "read_applied", transport: "relay", p50Ms: 310, p90Ms: 520, samples: 42),
        Row(step: "applied_saved", transport: "relay", p50Ms: 330, p90Ms: 610, samples: 42),
        Row(step: "read_saved", transport: "relay", p50Ms: 640, p90Ms: 1100, samples: 42)
    ] + iCloud
}

/// A CLI whose every call waits until it is cancelled: the shot keeps the
/// read it was shown.
private struct ParkedDiagnosticsCLI: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
