import SwiftUI
import WatchtowerCore

/// The in-app notice of the one-time v1-host restart (go hub spec §8
/// p. 4b step 0, mockup section 14): the pinned line with **Continue**, the
/// stop and resume progress with Continue off, or the failure with
/// **Retry**. Every string comes from `HostRestartStep.notice(for:)`;
/// values and a closure only, so the DesignShots draw it from a phase.
struct HostRestartNotice: View {
    let notice: HostRestartStep.Notice
    let onPress: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.compact) {
                    if notice.progress != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(notice.text)
                        .font(.callout)
                        .foregroundStyle(notice.isError ? Tone.error : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress = notice.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(notice.buttonTitle, action: onPress)
                .buttonStyle(.kitPrimary)
                .disabled(!notice.buttonEnabled)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(Fill.card)
    }
}

/// The other workspaces whose sessions wait in the restart list (mockup
/// section 15): each workspace's name over "N sessions wait to resume".
struct HostRestartWaitLines: View {
    let workspaces: [HostRestartStep.WaitingWorkspace]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(workspaces) { workspace in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(workspace.name)
                    Text(workspace.line)
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                }
            }
        }
    }
}
