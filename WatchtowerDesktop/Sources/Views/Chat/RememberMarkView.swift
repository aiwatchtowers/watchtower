import DesignKit
import SwiftUI
import WatchtowerCore

/// The note under an owner message that told the chat to remember something.
/// Draws nothing for a message the center knows nothing about (an ordinary
/// message, a chat without instructions).
struct RememberMarkView: View {
    let messageID: Int64
    let text: String
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        if let center = appState?.embeddedChats.rememberCenter, RememberCommand.parse(text) != nil {
            MarkLine(center: center, messageID: messageID) { appState?.openInstructionsSettings() }
                .task(id: messageID) { center.loadMarks(messageIDs: [messageID]) }
        }
    }

    private struct MarkLine: View {
        let center: RememberCenter
        let messageID: Int64
        let openSettings: () -> Void

        var body: some View {
            if let mark = center.mark(for: messageID) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: icon(mark)).foregroundStyle(tint(mark))
                    Text(label(mark)).foregroundStyle(.secondary)
                    if case .remembered = mark {
                        Button("Undo") { Task { await center.undo(messageID: messageID) } }
                            .buttonStyle(.kitQuiet)
                    }
                    if offersSettings(mark) {
                        Button("Open in Settings", action: openSettings).buttonStyle(.kitQuiet)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .contain)
            }
        }

        private func label(_ mark: RememberMark) -> String {
            switch mark {
            case .remembered: "Remembered for all chats"
            case .alreadyPresent: "Already in your instructions"
            case .full: "Instructions are full — 1000 characters"
            case .empty: "Nothing to remember after “remember:”"
            case .undone: "Removed from your instructions"
            case .notFound: "That line is no longer in your instructions"
            case .failed(let message): "Couldn't remember this: \(message)"
            }
        }

        private func icon(_ mark: RememberMark) -> String {
            switch mark {
            case .remembered, .alreadyPresent, .undone: "checkmark.circle"
            case .full, .empty, .notFound, .failed: "exclamationmark.circle"
            }
        }

        private func tint(_ mark: RememberMark) -> Color {
            switch mark {
            case .remembered: .green
            case .alreadyPresent, .undone: .secondary
            case .full, .empty, .notFound, .failed: .orange
            }
        }

        private func offersSettings(_ mark: RememberMark) -> Bool {
            switch mark {
            case .remembered, .full, .notFound: true
            default: false
            }
        }
    }
}
