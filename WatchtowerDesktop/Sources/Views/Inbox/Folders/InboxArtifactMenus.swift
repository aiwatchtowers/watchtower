import SwiftUI
import WatchtowerCore

/// The entries as a `Menu`'s content: a button per press, a submenu per
/// entry with children, a checkmark on the current choice.
struct InboxMenuItems: View {
    let entries: [InboxMenuEntry]
    /// Writes are disabled; reads (Learned Rules, Run History…) stay.
    var readOnly = false
    let onCommand: (InboxMenuCommand) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            if entry.children.isEmpty {
                button(entry)
            } else {
                Menu(entry.title) {
                    Self(entries: entry.children, readOnly: readOnly, onCommand: onCommand)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ entry: InboxMenuEntry) -> some View {
        let title = String(repeating: "   ", count: entry.indent) + entry.title
        Button(role: entry.destructive ? .destructive : nil) {
            if let command = entry.command { onCommand(command) }
        } label: {
            if entry.checked {
                Label(title, systemImage: "checkmark")
            } else if let image = entry.systemImage {
                Label(title, systemImage: image)
            } else {
                Text(title)
            }
        }
        .disabled(readOnly && !(entry.command?.isRead ?? false))
    }
}

/// An artifact's ⋯ as the reading pane draws it: the entries, whether they
/// are off (a call on the automation runs, or it is not known yet), and the
/// last failed press's text (`InboxArtifactMenuModel.headerErrors`).
struct InboxArtifactMenuState {
    let entries: [InboxMenuEntry]
    var isDisabled = false
    var isWorking = false
    var error: String?
    var onCommand: (InboxMenuCommand) -> Void = { _ in }
}

/// The artifact ⋯ with its progress while a press runs.
struct InboxArtifactMenuButton: View {
    let menu: InboxArtifactMenuState

    var body: some View {
        HStack(spacing: Spacing.small) {
            if menu.isWorking { ProgressView().controlSize(.small) }
            InboxMoreMenu(entries: menu.entries, help: "More for this artifact", onCommand: menu.onCommand)
                .disabled(menu.isDisabled)
        }
        .controlSize(.small)
    }
}

/// A ⋯ button that opens `entries` (the artifact header, a folder row).
struct InboxMoreMenu: View {
    let entries: [InboxMenuEntry]
    var help = "More"
    var readOnly = false
    let onCommand: (InboxMenuCommand) -> Void

    var body: some View {
        Menu {
            InboxMenuItems(entries: entries, readOnly: readOnly, onCommand: onCommand)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The reading pane's artifact header: the title, its source line, **Done**
/// and the artifact ⋯; a failed ⋯ entry's text under it, never silent
/// (spec: "Artifact ⋯ entry failed"). Values only; Task 14 wires it.
struct InboxArtifactHeader: View {
    let title: String
    let source: String
    let menu: InboxArtifactMenuContent
    /// The CLI's text of the last failed ⋯ press, or the busy line.
    var error: String?
    /// A ⋯ press under way: the menu waits.
    var isWorking = false
    var onDone: () -> Void = {}
    var onCommand: (InboxMenuCommand) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                if isWorking { ProgressView().controlSize(.small) }
                Button("Done", action: onDone)
                    .buttonStyle(.kitSecondary)
                InboxMoreMenu(entries: menu.entries, onCommand: onCommand)
                    .disabled(isWorking)
            }
            .controlSize(.small)
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
