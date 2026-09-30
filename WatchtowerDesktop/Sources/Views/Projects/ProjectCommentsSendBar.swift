import SwiftUI
import WatchtowerCore

/// Under an open project document: "Send N comments to Claude" pastes one
/// prompt line into the project's running Claude Code session (or copies it
/// when the session has no bracketed paste); with none
/// running it explains the brief and offers the terminal.
struct ProjectCommentsSendBar: View {
    static let copiedNote = "Prompt copied — press ⌘V in the terminal"
    static let noSessionNote =
        "No Claude Code session is running for this project. The next session you start gets these comments in its brief."

    let count: Int
    /// The last click's result; nil = not clicked yet.
    let delivery: ProjectTerminalCenter.PromptDelivery?
    let onSend: () -> Void
    let onOpenTerminal: () -> Void

    var body: some View {
        if count > 0 { // swiftlint:disable:this empty_count
            HStack(spacing: 8) {
                switch delivery {
                case .sent:
                    Label("Pasted into Claude — press Return to send", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                case .copied:
                    Label(Self.copiedNote, systemImage: "doc.on.clipboard")
                        .font(.caption).foregroundStyle(.secondary)
                case .noSession:
                    Text(Self.noSessionNote).font(.caption).foregroundStyle(.secondary)
                    Button("Open terminal", action: onOpenTerminal)
                case nil:
                    EmptyView()
                }
                Spacer()
                Button(CommentBatchComposer.sendButtonTitle(count: count) + " to Claude", action: onSend)
                    .help("Ask Claude Code to address every open comment on this document")
            }
            .padding(8)
        }
    }
}
