import SwiftUI
import WatchtowerCore

/// The editor chat on the left, the live **Draft** panel on the right (spec
/// §12.2, mockup 2). The chat's `save_automation` card sits under the reply
/// that proposed it; Approve on it is the save (spec §11).
struct AutomationEditorChatView: View {
    let chat: AutomationEditorChat
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            EmbeddedChatView(
                engine: chat.engine,
                placeholder: "Change something — e.g. 'also at 14:00', 'only from my team'",
                dictationTargetID: "chat.automationEditor.\(chat.conversationID)",
                accessory: { item in proposals(for: item) },
                footer: { footer }
            )
            .frame(minWidth: 380, maxWidth: .infinity)
            .background(Color(.controlBackgroundColor).opacity(0.4))
            Divider()
            AutomationDraftPanel(
                model: chat.draft,
                canAct: chat.toolsAvailable && !chat.engine.isBusy,
                actionHelp: chat.toolsAvailable ? nil : AutomationEditorChatSurface.unavailableHelp,
                savedNote: chat.savedNote,
                onCancel: onCancel,
                onDryRunAgain: { chat.dryRunAgain() },
                onSave: { chat.askToSave() }
            )
            .frame(minWidth: 420, maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func proposals(for item: ChatThreadItem) -> some View {
        if item.message.isAssistant, !item.message.turnID.isEmpty {
            ForEach(chat.actionFeed.cards(forTurn: item.message.turnID)) { card($0) }
        }
    }

    /// Proposals of a turn that never stored a reply, and the feed's error.
    @ViewBuilder
    private var footer: some View {
        let orphans = AgentActionFeed.unattached(
            rows: chat.actionFeed.rows,
            messageTurnIDs: Set(chat.engine.messages.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty || chat.actionFeed.lastError != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(orphans) { card($0) }
                if let error = chat.actionFeed.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func card(_ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chat.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chat.actionFeed.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await chat.actionFeed.reject(action.id) } },
            onRetry: { Task { await chat.actionFeed.retry(action.id) } },
            gestureError: chat.actionFeed.rowErrors[action.id]
        )
    }
}

/// Holds one `AutomationEditorChat` while it is on screen: made on appear,
/// closed on disappear. The engine lives in `AppState.embeddedChatCenter`,
/// so closing never stops a turn and reopening shows it again.
struct AutomationEditorChatLoader<Content: View>: View {
    let make: () throws -> AutomationEditorChat?
    @ViewBuilder let content: (AutomationEditorChat) -> Content

    @State private var chat: AutomationEditorChat?
    @State private var failure: String?

    var body: some View {
        Group {
            if let chat {
                content(chat)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: open)
        .onDisappear {
            chat?.close()
            chat = nil
        }
    }

    private func open() {
        guard chat == nil else { return }
        do {
            guard let made = try make() else {
                failure = "This chat can't open: the automation or the database is not available."
                return
            }
            chat = made
        } catch {
            failure = "This chat can't open: \(error.localizedDescription)"
        }
    }
}

/// "Change in words" for one automation, as a sheet.
struct AutomationChangeInWordsSheet: View {
    let name: String
    let make: () throws -> AutomationEditorChat?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Change “\(name)” in words").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            AutomationEditorChatLoader(make: make) { chat in
                AutomationEditorChatView(chat: chat, onCancel: onClose)
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
    }
}
