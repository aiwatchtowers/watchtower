import SwiftUI
import WatchtowerCore

/// Where a saved recipe's artifacts will go: a folder the editor chat
/// suggested (created on save), or an existing one (+ New Artifact… from a
/// folder, or a suggestion that names one). Placement, not a confirmed
/// field: it never changes the approval hash.
enum InboxFolderPlacement: Equatable {
    case newFolder(title: String, parent: String)
    case existing(title: String)

    var text: String {
        switch self {
        case let .newFolder(title, parent): "New folder: \(title), in \(parent)"
        case let .existing(title): "Folder: \(title)"
        }
    }
}

/// The folder line the editor's pinned **Changed** row ends with (A's
/// `AutomationSaveConfirmation`, ask #486). Values only; Task 15 wires it.
struct InboxFolderPlacementLine: View {
    let placement: InboxFolderPlacement

    var body: some View {
        Text(placement.text)
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
