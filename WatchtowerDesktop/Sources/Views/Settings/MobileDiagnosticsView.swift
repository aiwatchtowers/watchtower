import SwiftUI
import WatchtowerCore

/// Settings → Mobile → Diagnostics (go hub plan 4 Task 9, mockup §23), the
/// sheet the Mobile tab's Diagnostics row opens: one section with the
/// refresh spinner in its header, the caption, the lines above the rows,
/// and Done. Every line comes from `MobileDiagnosticsModel`.
struct MobileDiagnosticsView: View {
    typealias Copy = MobileDiagnosticsModel
    let model: MobileDiagnosticsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.medium) {
            ScrollView {
                section.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Button(Copy.doneTitle) { dismiss() }
                .buttonStyle(.kitSecondary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.medium)
    }

    @ViewBuilder
    private var section: some View {
        switch model.state {
        case .loading:
            SettingsSection(title: Copy.entryTitle) {
                ProgressView().controlSize(.small)
            }
        case .error(let message):
            SettingsSection(title: Copy.entryTitle) {
                HStack(spacing: Spacing.medium) {
                    Text(message).foregroundStyle(Tone.error)
                    Spacer(minLength: Spacing.medium)
                    Button(Copy.retryTitle) { Task { await model.load() } }
                        .buttonStyle(.kitPrimary)
                        .controlSize(.small)
                }
            }
        case .empty:
            SettingsSection(title: Copy.entryTitle, caption: Copy.caption, isBusy: model.isRefreshing) {
                lines
                Text(Copy.emptyText)
            }
        case .rows(let rows):
            SettingsSection(title: Copy.entryTitle, caption: Copy.caption, isBusy: model.isRefreshing) {
                lines
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { MobileDiagnosticsRow(row: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var lines: some View {
        if let line = model.overGoalLine { Text(line).foregroundStyle(Tone.warning) }
        if let line = model.overflowLine { Text(line).foregroundStyle(Tone.warning) }
    }
}

/// The Diagnostics row of Settings → Mobile (mockup §22): its title and a
/// chevron; the whole row is the button that opens the sheet.
struct MobileDiagnosticsEntryRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            SettingRow(title: MobileDiagnosticsModel.entryTitle) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One step on one transport: the label, the transport pill, p50, p90 and
/// the sample count on one line; where that does not fit (narrow), the
/// figures move below the label.
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
        .kitRow(isSelected: false)
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
