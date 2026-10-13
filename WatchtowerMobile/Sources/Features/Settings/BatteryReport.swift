import Foundation
import SwiftUI
import WatchtowerSync

/// One line of Settings → Battery.
struct BatteryRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// What Settings → Battery shows (board #724): today's and yesterday's
/// counters, and the newest MetricKit daily report.
struct BatteryReport: Equatable {
    /// One row per counter, valued "today · yesterday".
    let counterRows: [BatteryRow]
    /// The newest MetricKit report's rows; empty before the first report.
    let metricRows: [BatteryRow]

    static let counterLabels: [(EnergyEvent, String)] = [
        (.silentPush, "Silent pushes"),
        (.fetchLoop, "Fetches: timed"),
        (.fetchPush, "Fetches: push"),
        (.fetchPull, "Fetches: pull to refresh"),
        (.fetchForeground, "Fetches: foreground"),
        (.fetchLaunch, "Fetches: launch"),
        (.fetchLink, "Fetches: linking"),
        (.engineFetch, "iCloud fetches requested"),
        (.engineFetchRun, "iCloud's own fetches"),
        (.zoneCheck, "Zone checks"),
        (.dataZonePoll, "Data polls"),
        (.relayZonePoll, "Relay polls"),
        (.sendBatch, "iCloud sends"),
        (.coldLaunchBackground, "Launches in background"),
        (.coldLaunchForeground, "Launches in foreground"),
        (.uploadAttempt, "Recording uploads")
    ]

    init(today: EnergyDayCounts, yesterday: EnergyDayCounts, latest: MetricDaySummary?) {
        counterRows = Self.counterLabels.map { event, label in
            BatteryRow(label: label, value: "\(today[event]) · \(yesterday[event])")
        }
        metricRows = latest.map(Self.metricRows) ?? []
    }

    init(diagnostics: BatteryDiagnostics) {
        self.init(
            today: diagnostics.counter.counts(daysAgo: 0),
            yesterday: diagnostics.counter.counts(daysAgo: 1),
            latest: diagnostics.metrics.latestDay
        )
    }

    private static func metricRows(_ day: MetricDaySummary) -> [BatteryRow] {
        let period = day.begin.formatted(date: .abbreviated, time: .omitted)
        return [
            BatteryRow(label: "Report", value: period),
            BatteryRow(label: "CPU", value: day.cpuSeconds.map { duration($0) } ?? "—"),
            BatteryRow(label: "Foreground time", value: day.foregroundSeconds.map { duration($0) } ?? "—"),
            BatteryRow(label: "Background time", value: day.backgroundSeconds.map { duration($0) } ?? "—"),
            BatteryRow(label: "Background audio", value: day.backgroundAudioSeconds.map { duration($0) } ?? "—"),
            BatteryRow(label: "Wi-Fi", value: traffic(down: day.wifiDownBytes, up: day.wifiUpBytes)),
            BatteryRow(label: "Cellular", value: traffic(down: day.cellularDownBytes, up: day.cellularUpBytes)),
            BatteryRow(label: "Launches", value: day.launches.map(String.init) ?? "—"),
            BatteryRow(label: "Background exits", value: day.backgroundExits.map(String.init) ?? "—"),
            BatteryRow(label: "Peak memory", value: day.peakMemoryBytes.map { megabytes($0) } ?? "—")
        ]
    }

    /// "42 s", "7 min", "2 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "12.3 MB" (decimal megabytes).
    static func megabytes(_ bytes: Double) -> String {
        String(format: "%.1f MB", bytes / 1_000_000)
    }

    /// "↓ 12.3 MB · ↑ 0.4 MB"; "—" when the report has no traffic data.
    static func traffic(down: Double?, up: Double?) -> String {
        guard let down, let up else { return "—" }
        return "↓ \(megabytes(down)) · ↑ \(megabytes(up))"
    }
}

/// Settings → Battery: the counters (today · yesterday) and the newest
/// MetricKit report.
struct BatterySection: View {
    let report: BatteryReport

    var body: some View {
        Section {
            ForEach(report.counterRows) { row in
                LabeledContent(row.label, value: row.value)
            }
            if report.metricRows.isEmpty {
                Text("No MetricKit report yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.metricRows) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
        } header: {
            Text("Battery")
        } footer: {
            Text("Counts are today · yesterday. iOS sends a MetricKit report about once a day, for the day before.")
        }
        .font(.footnote)
    }
}
