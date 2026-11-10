import SwiftUI
import WatchtowerCore

/// The folder line the editor's pinned **Changed** row ends with (A's
/// `AutomationSaveConfirmation`, ask #486): where the save puts the
/// automation's cards (`InboxNewArtifactRoute.placementText`), "New folder:
/// Release, in Inbox" or "Folder: Release". Placement, not a confirmed
/// field: it never changes the approval hash.
struct InboxFolderPlacementLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The line under the editor footer when the save landed but the route did
/// not: "Saved. The folder was not created: <reason>" and **Try Again**,
/// which re-reads the menu first. The recipe stays saved.
struct InboxFolderSaveFailureLine: View {
    let reason: String
    var isRetrying = false
    var onTryAgain: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text("Saved. The folder was not created: \(reason)")
                .font(.caption)
                .foregroundStyle(Tone.error)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.regular)
            if isRetrying {
                ProgressView().controlSize(.small)
            }
            Button("Try Again", action: onTryAgain)
                .buttonStyle(.kitSecondary)
                .disabled(isRetrying)
        }
        .controlSize(.small)
    }
}
