import SwiftUI
import WatchtowerSync

/// Settings → Diagnostics (relay client Phase 4 Task 15, mockup S37–S40, S48): the action timings of the last seven
/// days per transport, then the Battery section, moved here unchanged. Texts and tones come from
/// `LatencyDiagnosticsModel`.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    let settings: SettingsViewModel
    @State private var reader: LatencyDiagnosticsReader?
    /// A reader to show instead of the environment's (the screenshot tour's frames).
    private let readerOverride: LatencyDiagnosticsReader?

    init(settings: SettingsViewModel, reader: LatencyDiagnosticsReader? = nil) {
        self.settings = settings
        readerOverride = reader
    }

    private var current: LatencyDiagnosticsReader? { readerOverride ?? reader }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let current {
                    timings(LatencyDiagnosticsModel(state: current.state), reader: current)
                }
                if let battery = settings.battery {
                    BatterySection(report: battery)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.wide)
        }
        .navigationTitle(SettingsView.diagnosticsTitle)
        .task {
            if readerOverride == nil, reader == nil {
                reader = LatencyDiagnosticsReader { env.latencySources() }
            }
            await readerOverride?.load()
            await reader?.load()
        }
        // The counters change on every fetch; re-read them while the page is on screen.
        .task {
            while !Task.isCancelled {
                settings.refreshBattery()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private func timings(_ model: LatencyDiagnosticsModel, reader: LatencyDiagnosticsReader) -> some View {
        switch model.state {
        case let .rows(rows):
            SettingsCard(title: LatencyDiagnosticsModel.header, footer: LatencyDiagnosticsModel.footer) {
                ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
                    if index > 0 { CardRowDivider() }
                    timingRows(row)
                }
            }
        case .loading:
            HStack(spacing: Spacing.regular) {
                ProgressView()
                Text(LatencyDiagnosticsModel.loadingText)
            }
            .font(TypeScale.rowTitle)
            .foregroundStyle(PhoneTone.secondary.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.wide)
        case .empty:
            message(LatencyDiagnosticsModel.emptyText, tone: .secondary)
        case .needsMacUpdate:
            message(LatencyDiagnosticsModel.needsMacUpdateText, tone: .secondary)
        case .failed:
            VStack(spacing: Spacing.medium) {
                message(LatencyDiagnosticsModel.failedText, tone: .red)
                Button(LatencyDiagnosticsModel.retryTitle) { Task { await reader.retry() } }
                    .font(TypeScale.rowTitle)
                    .frame(minHeight: PhoneMetrics.minTouch)
                    .foregroundStyle(PhoneTone.accent.color)
            }
        }
    }

    private func timingRows(_ row: LatencyDiagnosticsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Text(row.title).font(TypeScale.rowTitle)
                Spacer(minLength: Spacing.medium)
                Text(row.count).font(.subheadline).foregroundStyle(PhoneTone.secondary.color)
            }
            Text(row.result).font(TypeScale.meta).foregroundStyle(PhoneTone.secondary.color)
            Text(row.answer).font(TypeScale.meta).foregroundStyle(PhoneTone.secondary.color)
        }
        .padding(.vertical, Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func message(_ text: String, tone: PhoneTone) -> some View {
        Text(text)
            .font(TypeScale.rowTitle)
            .multilineTextAlignment(.center)
            .foregroundStyle(tone.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.wide)
    }
}
