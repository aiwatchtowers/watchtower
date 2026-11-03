import SwiftUI
import WatchtowerCore

/// Settings → Mobile → Diagnostics (go hub plan 4 Task 9, mockup §23): the
/// header with the refresh spinner, the caption, the lines above the rows,
/// then the rows. Every line comes from `MobileDiagnosticsModel`.
struct MobileDiagnosticsView: View {
    typealias Copy = MobileDiagnosticsModel
    let model: MobileDiagnosticsModel
    /// Back to Settings → Mobile; nil draws no back button (the design shots).
    var onBack: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                if let onBack {
                    Button(action: onBack) {
                        Label(MobileSettingsModel.sectionTitle, systemImage: "chevron.left")
                    }
                    .buttonStyle(.kitQuiet)
                }
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    HStack(spacing: Spacing.regular) {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        Text(Copy.entryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    content
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            MobileDiagnosticsCard {
                ProgressView().controlSize(.small)
            }
        case .error(let message):
            MobileDiagnosticsCard {
                HStack(spacing: Spacing.medium) {
                    Text(message).foregroundStyle(Tone.error)
                    Spacer(minLength: Spacing.medium)
                    Button(Copy.retryTitle) { Task { await model.retry() } }
                        .buttonStyle(.kitPrimary)
                        .controlSize(.small)
                }
            }
        case .empty:
            captionAndLines
            MobileDiagnosticsCard {
                Text(Copy.emptyText)
            }
        case .rows(let rows):
            captionAndLines
            MobileDiagnosticsCard {
                ForEach(rows) { MobileDiagnosticsRow(row: $0) }
            }
        }
    }

    @ViewBuilder
    private var captionAndLines: some View {
        Text(Copy.caption)
            .font(.caption)
            .foregroundStyle(.secondary)
        if model.overGoalLine != nil || model.overflowLine != nil {
            MobileDiagnosticsCard {
                if let line = model.overGoalLine { Text(line).foregroundStyle(Tone.warning) }
                if let line = model.overflowLine { Text(line).foregroundStyle(Tone.warning) }
            }
        }
    }
}

extension EnvironmentValues {
    /// Opens Settings → Mobile → Diagnostics; nil where nothing presents it.
    @Entry var openMobileDiagnostics: (@MainActor () -> Void)?
}

/// Shows Diagnostics in place of Settings → Mobile while it is open, and
/// reads the timings each time it opens. The model is kept, so a second
/// opening shows the last read under the refresh spinner.
struct MobileDiagnosticsPresenter: ViewModifier {
    let makeModel: @MainActor () -> MobileDiagnosticsModel
    @State private var model: MobileDiagnosticsModel?
    @State private var isOpen = false

    func body(content: Content) -> some View {
        if isOpen, let model {
            MobileDiagnosticsView(model: model) { isOpen = false }
                .task { await model.load() }
        } else {
            content.environment(\.openMobileDiagnostics) {
                if model == nil { model = makeModel() }
                isOpen = true
            }
        }
    }
}

/// The Diagnostics row of Settings → Mobile (mockup §22): its title and a
/// chevron; the whole row opens the screen.
struct MobileDiagnosticsEntryRow: View {
    let open: () -> Void

    var body: some View {
        SettingRow(title: MobileDiagnosticsModel.entryTitle) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }
}

/// One group on the settings card fill, as `SettingsSection` draws it.
private struct MobileDiagnosticsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) { content }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
    }
}

/// One step on one transport: the label, the transport pill, p50, p90 and
/// the sample count; narrow, the numbers move below the label.
private struct MobileDiagnosticsRow: View {
    let row: MobileDiagnosticsModel.Row

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) {
                Text(row.stepLabel).lineLimit(1)
                Spacer(minLength: Spacing.medium)
                figures
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(row.stepLabel)
                HStack(spacing: Spacing.regular) { figures }
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        Chip(text: row.transportLabel, color: MobileTransportTone.color(row.transport))
        Group {
            Text(row.p50).frame(minWidth: ListLayout.numberColumn, alignment: .trailing)
            Text(row.p90).frame(minWidth: ListLayout.numberColumn, alignment: .trailing)
            Text(row.samples).frame(minWidth: ListLayout.numberColumn, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
