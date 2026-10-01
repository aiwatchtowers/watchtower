import SwiftUI
import WatchtowerCore

// MARK: - IdeaDiscussState

/// What a pane holds for its Discuss section: whether it is open, and the
/// idea's conversation once resolved (on the first expand). The chat itself
/// lives in `AppState.embeddedChatCenter`, so collapsing the section or
/// leaving the pane never stops a reply.
struct IdeaDiscussState {
    var isExpanded = false
    var conversationID: Int64?

    /// The idea's engine while the section is open.
    @MainActor
    func engine(
        idea: Idea,
        mentions: [IdeaMention],
        dbManager: DatabaseManager,
        center: EmbeddedChatCenter
    ) -> EmbeddedChatEngine? {
        guard isExpanded, let conversationID else { return nil }
        return center.engine(for: IdeaChatSurface.spec(idea: idea, mentions: mentions,
                                                       conversationID: conversationID, dbPool: dbManager.dbPool))
    }
}

// MARK: - IdeaDiscussSection

/// Collapsed-by-default "Discuss with assistant" chat at the bottom of the
/// idea (or decision) detail pane's SCROLL content: header + the chat's rows.
/// The composer is docked by the owning pane below the scroll
/// (`EmbeddedChatComposer`) — the input wraps a nested NSScrollView that
/// collapses inside a SwiftUI ScrollView, so it must live outside it. The
/// section stays inert while collapsed (one cheap message-count read).
struct IdeaDiscussSection: View {
    let idea: Idea
    let mentions: [IdeaMention]
    let dbManager: DatabaseManager
    let center: EmbeddedChatCenter
    @Binding var state: IdeaDiscussState

    @State private var persistedCount = 0
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            header
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let engine = state.engine(idea: idea, mentions: mentions, dbManager: dbManager, center: center) {
                LazyVStack(alignment: .leading, spacing: ChatDensity.compact.rowSpacing) {
                    EmbeddedChatRows(engine: engine)
                }
                .padding(.top, 6)
                .embeddedChatVisibility(engine.spec.key, in: center)
            }
        }
        .onAppear(perform: loadPersistedCount)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggleDiscuss() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Discuss with assistant")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if persistedCount > 0 && !state.isExpanded {
                    Text("\(persistedCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Collapsing only hides the chat — a reply in flight keeps streaming.
    private func toggleDiscuss() {
        if state.isExpanded {
            state.isExpanded = false
            loadPersistedCount()
            return
        }
        if state.conversationID == nil {
            do {
                state.conversationID = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)
                loadError = nil
            } catch {
                loadError = "Couldn't open the discussion: \(error.localizedDescription)"
                return
            }
        }
        state.isExpanded = true
    }

    private func loadPersistedCount() {
        let ideaID = idea.id
        do {
            persistedCount = try dbManager.dbPool.read { db in
                try IdeaChatSurface.persistedMessageCount(db, ideaID: ideaID)
            }
        } catch {
            // A badge only: the count stays as it was, the failure is logged.
            NSLog("IdeaDiscussSection: message count for idea %d failed: %@", ideaID, String(describing: error))
        }
    }
}
