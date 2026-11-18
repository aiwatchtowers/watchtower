import SwiftUI
import WatchtowerCore
import DesignKit

/// Connections → Slack, the **Slack mode** section: the chip, the summary
/// and the Live block (screens spec §1). Every string and every choice of
/// action comes from `SlackModePresentation`; this view only lays it out.
struct SlackModeSection: View {
    let presentation: SlackModePresentation
    let checkAgain: () -> Void
    let tryAgain: () -> Void

    var body: some View {
        SettingsSection(title: presentation.title, isBusy: presentation.isBusy) {
            Chip(text: presentation.chip, color: presentation.chipTone.color, dot: true)
            Text(presentation.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            liveBlock
        }
    }

    private var liveBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                Text(presentation.liveTitle).font(.subheadline.weight(.semibold))
                Spacer(minLength: Spacing.medium)
                if presentation.showsCheckAgain {
                    Button(presentation.checkAgain, action: checkAgain)
                        .buttonStyle(.kitSecondary)
                        .disabled(!presentation.checkAgainEnabled)
                }
            }
            switch presentation.liveBlock {
            case .loading:
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(presentation.loadingLine).font(.caption).foregroundStyle(.secondary)
                }
            case .empty:
                if presentation.busyLine == nil {
                    Text(presentation.emptyLine).font(.caption).foregroundStyle(.secondary)
                }
            case .rows:
                ForEach(presentation.liveRows) { row in liveRow(row) }
            case .readFailed:
                EmptyView()
            }
            if let busy = presentation.busyLine, presentation.liveBlock != .loading {
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = presentation.problem {
                problemLine(problem)
            }
        }
        .padding(.top, Spacing.small)
    }

    private func liveRow(_ row: SlackModePresentation.LiveRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Circle()
                .fill(row.tone.color)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("\(row.provider): \(row.status)").font(.callout)
                if let reason = row.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.medium)
            if let age = row.age {
                Text(age).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func problemLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            if presentation.showsTryAgain {
                Button(presentation.tryAgain, action: tryAgain).buttonStyle(.kitSecondary)
            }
        }
    }
}

extension SlackModeTone {
    var color: Color {
        switch self {
        case .success: Tone.success
        case .warning: Tone.warning
        case .blue: Tone.status("blue")
        case .gray: Tone.status("gray")
        }
    }
}
