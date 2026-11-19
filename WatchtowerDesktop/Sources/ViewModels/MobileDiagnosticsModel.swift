import Foundation
import WatchtowerCore

/// Settings → Mobile → Diagnostics (go hub plan 4 Task 9, mockup §22–§23):
/// the hub's content-free timings over `watchtower hub diagnostics --days 7
/// --json` — p50, p90 and the sample count per step and transport — the
/// line when this Mac's part alone misses the 500 ms goal on Relay, and the
/// alerts dropped because too many were waiting. The hub's database is never
/// opened here.
@MainActor
@Observable
final class MobileDiagnosticsModel {
    enum State: Equatable {
        case loading, empty
        case rows([Row])
        case error(String)
    }

    struct Row: Equatable, Identifiable {
        var id: String { transport + "/" + stepLabel }
        /// The CLI's transport (`relay`, `cloudkit`), for the pill colour.
        let transport: String
        let stepLabel: String
        /// "Relay" | "iCloud".
        let transportLabel: String
        /// "p50 38 ms".
        let p50: String
        /// "p90 120 ms".
        let p90: String
        /// "<N> samples" | "1 sample".
        let samples: String
    }

    nonisolated static let entryTitle = "Diagnostics"
    nonisolated static let caption = "Content-free timings kept on this Mac only."
    nonisolated static let emptyText = "No timings yet. They appear after the first action from a phone."
    nonisolated static let errorText = "Couldn't read the timings."
    nonisolated static let retryTitle = "Retry"
    /// Closes the Diagnostics sheet.
    nonisolated static let doneTitle = "Done"
    nonisolated static let overGoalText = "This Mac's part alone is over the 500 ms goal."
    /// The goal for this Mac's part of one phone action, from read to slice saved.
    nonisolated static let goalMs = 500

    /// The steps in the order shown, with their labels.
    nonisolated static let steps: [(step: String, label: String)] = [
        ("read_applied", "Phone action read → applied"),
        ("applied_saved", "Applied → slice saved"),
        ("read_saved", "Phone action read → slice saved")
    ]
    /// The transports in the order shown.
    nonisolated static let transports = ["relay", "cloudkit"]

    private(set) var state: State = .loading
    /// A read in flight over the rows it replaces; settable for the design shots.
    var isRefreshing = false
    private(set) var overGoalLine: String?
    private(set) var overflowLine: String?

    @ObservationIgnored private let cli: MobileHubCLI
    @ObservationIgnored private var loading = false

    init(cli: (any CLIRunnerProtocol)?) {
        self.cli = MobileHubCLI(runner: cli)
    }

    /// Reads the timings; one read at a time. The first read and Retry show
    /// `.loading`, a later one keeps what is shown and sets `isRefreshing`.
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        switch state {
        case .rows, .empty: isRefreshing = true
        case .error: state = .loading
        case .loading: break
        }
        defer { isRefreshing = false }
        do {
            let diagnostics = try await cli.diagnostics()
            present(diagnostics)
        } catch {
            // The sheet went away mid-read: what it shows stays.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            presentFailure()
        }
    }

    /// Shows one read of the timings.
    func present(_ diagnostics: MobileHubCLI.Diagnostics) {
        let rows = Self.rows(diagnostics.rows)
        state = rows.isEmpty ? .empty : .rows(rows)
        // The per-action total on Relay, never a sum of the steps' medians.
        let total = diagnostics.rows.first { $0.step == "read_saved" && $0.transport == "relay" }
        overGoalLine = (total?.p50Ms ?? 0) >= Self.goalMs ? Self.overGoalText : nil
        overflowLine = diagnostics.pushOverflowExpired > 0 ? Self.overflowText(diagnostics.pushOverflowExpired) : nil
    }

    /// Shows a read that failed: the error with Retry and nothing else.
    func presentFailure() {
        state = .error(Self.errorText)
        overGoalLine = nil
        overflowLine = nil
    }

    // MARK: - Copy

    /// Relay first, then iCloud; each in step order. A step or transport this
    /// build does not know (a newer CLI) is left out.
    nonisolated static func rows(_ rows: [MobileHubCLI.Diagnostics.Row]) -> [Row] {
        transports.flatMap { transport in
            steps.compactMap { step, label in
                rows.first { $0.step == step && $0.transport == transport }.map { row in
                    Row(
                        transport: transport, stepLabel: label,
                        transportLabel: MobileSettingsModel.transportLabel(transport),
                        p50: "p50 " + duration(ms: row.p50Ms), p90: "p90 " + duration(ms: row.p90Ms),
                        samples: samplesText(row.samples)
                    )
                }
            }
        }
    }

    /// Under a second in milliseconds ("38 ms"), else seconds with one decimal ("2.1 s").
    nonisolated static func duration(ms: Int) -> String {
        guard ms >= 1000 else { return "\(ms) ms" }
        let tenths = ms / 100
        return "\(tenths / 10).\(tenths % 10) s"
    }

    nonisolated static func samplesText(_ count: Int) -> String {
        count == 1 ? "1 sample" : "\(count) samples"
    }

    nonisolated static func overflowText(_ count: Int) -> String {
        count == 1
            ? "1 alert was dropped because too many were waiting."
            : "\(count) alerts were dropped because too many were waiting."
    }
}
