import Foundation
import Observation
import WatchtowerSync

/// Settings → Diagnostics' action timings (relay client Phase 4 Task 15, mockup S37–S40, S48): the percentiles of
/// the samples the replica stores (Task 14), per transport. Every text lives here and is asserted in
/// `LatencyDiagnosticsModelTests`.
struct LatencyDiagnosticsModel: Equatable {
    enum State: Equatable { case loading, empty, needsMacUpdate, failed, rows([Row]) }

    struct Row: Equatable {
        let title: String
        let count: String
        let result: String
        let answer: String
    }

    static let header = "Action → result on screen · 7 days"
    static let footer = "Measured on this iPhone only. Nothing is sent anywhere."
    static let emptyText = "No timings yet. They appear after your first action."
    /// No sample and no hub on the ordered path: legacy actions are not timed.
    static let needsMacUpdateText = "Timings need an updated Watchtower on your Mac."
    static let failedText = "Couldn't read the timings."
    static let loadingText = "Reading timings…"
    static let retryTitle = "Retry"

    let state: State

    /// Relay first; a transport with no sample has no row.
    static func rows(_ samples: [LatencySample]) -> [Row] {
        [(TransportKind.relay, "Relay"), (.cloudKit, "iCloud")].compactMap { kind, title in
            let own = samples.filter { $0.transport == kind }
            guard !own.isEmpty else { return nil }
            let result = own.map(\.resultMs).sorted()
            let answer = own.map(\.answerMs).sorted()
            return Row(
                title: title,
                count: own.count == 1 ? "1 action" : "\(own.count) actions",
                result: line(result),
                answer: "Mac's answer: " + line(answer)
            )
        }
    }

    private static func line(_ sorted: [Int]) -> String {
        "p50 \(seconds(percentile(sorted, 50))) s · p90 \(seconds(percentile(sorted, 90))) s"
    }

    /// Under 1 s two decimals with a trailing zero trimmed (0.31, 0.7); 1 to under 10 s one decimal (6.8); from 10 s a
    /// whole number (22). Rounding carries into the next form (995 ms is 1.0).
    static func seconds(_ ms: Int) -> String {
        let ms = max(0, ms)
        let hundredths = (ms + 5) / 10
        if hundredths < 100 {
            let (tens, ones) = hundredths.quotientAndRemainder(dividingBy: 10)
            if hundredths == 0 { return "0" }
            return ones == 0 ? "0.\(tens)" : "0.\(tens)\(ones)"
        }
        let tenths = (ms + 50) / 100
        if tenths < 100 { return "\(tenths / 10).\(tenths % 10)" }
        return "\((ms + 500) / 1000)"
    }

    /// Nearest rank, as the hub: the value at rank ceil(p / 100 · n) of the ascending list.
    static func percentile(_ sorted: [Int], _ p: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = (p * sorted.count + 99) / 100
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// The page's colours: the rows are secondary, only the failure line is red. Never orange.
    var toneUses: [ToneUse] {
        switch state {
        case .rows: [ToneUse(element: "diagnostics rows", tone: .secondary, role: .info)]
        case .failed: [ToneUse(element: "diagnostics line", tone: .red, role: .info)]
        case .loading, .empty, .needsMacUpdate: [ToneUse(element: "diagnostics line", tone: .secondary, role: .info)]
        }
    }
}

/// One linked Mac's replica as the page reads it.
struct LatencyHubSource: Sendable {
    /// The samples that ended at or after the date.
    let samples: @Sendable (Date) throws -> [LatencySample]
    /// Whether the hub's actions run on the ordered path (the only path that is timed).
    let ordered: @Sendable () async throws -> Bool
}

/// Reads every hub's samples on a background task and merges them. One replica's failure fails the whole read:
/// partial numbers would read as true.
@MainActor @Observable
final class LatencyDiagnosticsReader {
    static let window: TimeInterval = ReplicaStore.latencyWindow

    private(set) var state = LatencyDiagnosticsModel.State.loading

    @ObservationIgnored private let sources: () -> [LatencyHubSource]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isFixed: Bool

    init(sources: @escaping () -> [LatencyHubSource], now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.now = now
        isFixed = false
    }

    /// A reader that shows a fixed state (the screenshot tour).
    init(fixed state: LatencyDiagnosticsModel.State) {
        self.state = state
        sources = { [] }
        now = Date.init
        isFixed = true
    }

    func load() async {
        guard !isFixed else { return }
        let hubs = sources()
        let since = now().addingTimeInterval(-Self.window)
        let result = await Task.detached { () -> LatencyDiagnosticsModel.State in
            do {
                var samples: [LatencySample] = []
                var anyOrdered = false
                for hub in hubs {
                    samples += try hub.samples(since)
                    if try await hub.ordered() { anyOrdered = true }
                }
                if !samples.isEmpty { return .rows(LatencyDiagnosticsModel.rows(samples)) }
                return !hubs.isEmpty && !anyOrdered ? .needsMacUpdate : .empty
            } catch {
                return .failed
            }
        }.value
        state = result
    }

    /// Retry: shows Loading, then reads again.
    func retry() async {
        guard !isFixed else { return }
        state = .loading
        await load()
    }
}
