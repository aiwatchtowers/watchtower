import SwiftUI
import WatchtowerCore

/// One "How it's going" tile: a metric (or two) with its trend.
struct CoachTileModel: Equatable {
    let title: String
    let value: String
    let trend: CoachTrend
    /// The metric is unknown: the value is "—".
    let unknown: Bool

    var trendText: String {
        switch trend {
        case let .better(label), let .worse(label): label
        case .same: "≈ about the same"
        case .noTrend: ""
        case .fewData: unknown ? "too little data" : "few data"
        }
    }

    var trendColor: Color {
        switch trend {
        case .better: Tone.success
        case .worse: Tone.warning
        case .same, .noTrend, .fewData: .secondary
        }
    }

    var isGreyed: Bool { trend == .fewData }
}

/// The four tiles and the caption below them, from `coach status`.
enum CoachTiles {
    static func make(_ status: CoachStatus) -> [CoachTileModel] {
        let m = status.metrics
        let hoursKnown = m.taskHours.known && m.taskHours.value != nil
        let costKnown = m.taskCostUSD.known && m.taskCostUSD.value != nil
        let perTask = [hoursKnown ? hours(m.taskHours.value) : nil, costKnown ? cost(m.taskCostUSD.value) : nil]
            .compactMap { $0 }
        let perTaskMetric = hoursKnown ? m.taskHours : m.taskCostUSD
        return [
            tile("Corrections per task", m.corrections, points: false) { number($0) },
            CoachTileModel(
                title: "Per task",
                value: perTask.isEmpty ? "—" : perTask.joined(separator: " · "),
                trend: CoachTrend.of(perTaskMetric, points: false),
                unknown: perTask.isEmpty
            ),
            tile("You in the loop", m.ownerLoop, points: true) { "\(Int(($0 * 100).rounded()))%" },
            tile("Review findings", m.specFindings, points: false) { number($0) }
        ]
    }

    static func caption(_ status: CoachStatus) -> String {
        let m = status.metrics
        let spec = value(m.specFindings)
        let review = value(m.reviewComments)
        return "Review findings: per spec's first round \(spec) · per code review's first round \(review)"
    }

    private static func value(_ metric: CoachMetric) -> String {
        guard metric.known, let v = metric.value else { return "—" }
        return number(v)
    }

    private static func tile(
        _ title: String, _ metric: CoachMetric, points: Bool, format: (Double) -> String
    ) -> CoachTileModel {
        let shown = metric.known ? metric.value.map(format) : nil
        return CoachTileModel(title: title, value: shown ?? "—",
                              trend: CoachTrend.of(metric, points: points), unknown: shown == nil)
    }

    static func number(_ v: Double) -> String { String(format: "%.1f", v) }

    static func hours(_ h: Double?) -> String? {
        guard let h else { return nil }
        let minutes = Int((h * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func cost(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        return usd >= 10 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }
}

/// "How it's going": the status snapshot as four tiles.
struct CoachMetricTilesView: View {
    let snapshot: SessionReportCenter.Snapshot<CoachStatus>?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "How it's going", systemImage: "gauge.medium")
            if let status = snapshot?.value {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.regular), count: 4),
                          spacing: Spacing.regular) {
                    ForEach(CoachTiles.make(status), id: \.title) { tile in
                        tileView(tile)
                    }
                }
                Text(CoachTiles.caption(status)).font(.caption).foregroundStyle(.secondary)
            } else if let error = snapshot?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func tileView(_ tile: CoachTileModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(tile.title).font(.caption).foregroundStyle(.secondary)
            Text(tile.value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tile.isGreyed || tile.unknown ? .secondary : .primary)
            Text(tile.trendText.isEmpty ? " " : tile.trendText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tile.trendColor)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
