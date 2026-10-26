import DesignKit
import SwiftUI
import WatchtowerCore

/// The note under an owner message that saved a decision or a fact
/// (`KnowledgePrefix`). Draws nothing for a message without the prefix or
/// before the database opens.
struct ChatKnowledgeMarkView: View {
    let conversationID: Int64
    let messageID: Int64
    let text: String
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        if let center = appState?.embeddedChats.knowledgeCenter, let parsed = KnowledgePrefix.parse(text) {
            if let mark = center.mark(for: messageID) {
                ChatKnowledgeMarkLine(
                    mark: mark, prefixKind: parsed.kind,
                    undo: {
                        Task {
                            await center.undo(messageID: messageID)
                            if case .changed(let id)? = center.mark(for: messageID) { openInInbox(id) }
                        }
                    },
                    openInInbox: openInInbox
                )
            } else {
                Color.clear.frame(width: 0, height: 0)
                    .task(id: messageID) { await center.loadMark(conversationID: conversationID, messageID: messageID) }
            }
        }
    }

    private func openInInbox(_ ideaID: Int64) {
        appState?.navigateToIdea(Int(ideaID))
    }
}

/// The mark's line itself, on plain data (tests and design shots).
struct ChatKnowledgeMarkLine: View {
    let mark: ChatKnowledgeMark
    /// The prefix's kind (`decision` or `note`), for the empty mark's words.
    let prefixKind: String
    let undo: () -> Void
    let openInInbox: (Int64) -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(label).foregroundStyle(.secondary)
            if case .saved = mark {
                Button("Undo", action: undo).buttonStyle(.kitQuiet)
            }
            if let ideaID = openableID {
                Button("Open in Inbox") { openInInbox(ideaID) }.buttonStyle(.kitQuiet)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    var label: String {
        switch mark {
        case .saved(let kind, _): kind == "note" ? "Saved as a fact" : "Saved as a decision"
        case .empty:
            "Nothing to save — write the \(prefixKind == "note" ? "fact" : "decision") after the colon"
        case .undone: "Undone — nothing saved"
        case .changed: "Changed since — opened in Inbox"
        case .failed(let message): "Couldn't save this: \(message)"
        }
    }

    private var openableID: Int64? {
        switch mark {
        case .saved(_, let id), .changed(let id): id
        case .empty, .undone, .failed: nil
        }
    }

    private var icon: String {
        switch mark {
        case .saved, .undone, .changed: "checkmark.circle"
        case .empty, .failed: "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch mark {
        case .saved: Tone.success
        case .undone, .changed: .secondary
        case .empty, .failed: Tone.warning
        }
    }
}
