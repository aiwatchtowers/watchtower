import SwiftUI
import WatchtowerCore

/// Under an open project document: "Send N comments to Claude" saves the
/// owner's draft comments, then pastes one prompt line into the project's
/// running Claude Code session (or copies it when the session has no
/// bracketed paste); with none running it explains the brief and offers the
/// terminal. N counts the drafts plus the open comments already saved.
struct WorkbenchCommentsSendBar: View {
    static let copiedNote = "Prompt copied — press ⌘V in the terminal"
    static let noSessionNote =
        "No Claude Code session is running for this project. The next session you start gets these comments in its brief."

    static func unsendableNote(_ drafts: Int) -> String {
        (drafts == 1 ? "1 draft" : "\(drafts) drafts") + " can't be sent — see Drafts."
    }

    static func draftsNote(_ drafts: Int) -> String {
        (drafts == 1 ? "1 draft" : "\(drafts) drafts") + " — Claude sees them only when you send."
    }

    let count: Int
    /// How many of `count` are unsent drafts.
    var drafts = 0
    /// Drafts Send leaves behind (passage gone, or empty).
    var unsendableDrafts = 0
    /// The drafts are being written: Send is disabled meanwhile.
    var sending = false
    /// The last click's result; nil = not clicked yet.
    let delivery: TerminalCenter.PromptDelivery?
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
                    if drafts > 0 {
                        Text(Self.draftsNote(drafts)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if unsendableDrafts > 0 {
                    Text(Self.unsendableNote(unsendableDrafts)).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button(CommentBatchComposer.sendButtonTitle(count: count) + " to Claude", action: onSend)
                    .disabled(sending)
                    .help("Save your drafts and ask Claude Code to address every open comment on this document")
            }
            .padding(8)
        }
    }
}
