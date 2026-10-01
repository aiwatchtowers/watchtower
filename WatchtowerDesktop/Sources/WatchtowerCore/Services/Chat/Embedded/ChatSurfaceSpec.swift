import Foundation

/// A starter prompt on a chat's empty state.
package struct ChatStarterPrompt: Identifiable, Equatable, Sendable {
    package let title: String
    package let text: String
    /// "Summarize PROJ-…" needs the owner's issue key: it fills the composer instead.
    package let sendsImmediately: Bool
    package var id: String { title }

    package init(title: String, text: String, sendsImmediately: Bool) {
        self.title = title
        self.text = text
        self.sendsImmediately = sendsImmediately
    }

    /// The main chat's four work prompts (spec §3.6 of the chat redesign).
    package static let all = [
        Self(title: "What mattered yesterday?", text: "What mattered yesterday?", sendsImmediately: true),
        Self(title: "Prep me for today's meetings", text: "Prep me for today's meetings", sendsImmediately: true),
        Self(title: "What's waiting on me?", text: "What's waiting on me?", sendsImmediately: true),
        Self(title: "Summarize PROJ-…", text: "Summarize ", sendsImmediately: false)
    ]
}

/// Which embedded chat an engine speaks for: the `chat_conversations`
/// context plus the conversation (nil for a memory-only chat).
package struct EmbeddedChatKey: Hashable, Sendable, CustomStringConvertible {
    package let contextType: String
    package let contextID: String
    package let conversationID: Int64?

    package init(contextType: String, contextID: String, conversationID: Int64?) {
        self.contextType = contextType
        self.contextID = contextID
        self.conversationID = conversationID
    }

    package var description: String {
        "\(contextType).\(contextID).\(conversationID.map(String.init) ?? "memory")"
    }
}

/// What a turn's prompt is built from.
package struct ChatTurnInput: Sendable {
    package let text: String
    /// The conversation already has a provider session: the CLI `--resume`s
    /// it and drops the system prompt, so surfaces re-inject their context.
    package let isResumed: Bool
    /// The owner message before this turn's (nil on the first one and on
    /// follow-up turns) — the target chat's outcomes floor.
    package let previousOwnerMessageAt: Date?
    package let turnID: String

    package init(text: String, isResumed: Bool, previousOwnerMessageAt: Date?, turnID: String) {
        self.text = text
        self.isResumed = isResumed
        self.previousOwnerMessageAt = previousOwnerMessageAt
        self.turnID = turnID
    }
}

package struct ChatPostTurnInput: Sendable {
    package let reply: String
    package let turnID: String
    /// The assistant row the reply is stored in.
    package let messageID: Int64

    package init(reply: String, turnID: String, messageID: Int64) {
        self.reply = reply
        self.turnID = turnID
        self.messageID = messageID
    }
}

/// What a surface made of a completed reply.
package struct ChatPostTurnResult: Equatable, Sendable {
    /// The text stored and shown for the reply (directives stripped, or a
    /// placeholder for a reply that was only directives).
    package var displayText: String
    /// Shown as `system` rows after the reply, in order.
    package var notices: [String]
    /// The surface could not use the reply (e.g. an unreadable directive);
    /// shown under that message. Nothing is applied silently.
    package var failure: String?

    package init(displayText: String, notices: [String] = [], failure: String? = nil) {
        self.displayText = displayText
        self.notices = notices
        self.failure = failure
    }

    package static func identity(_ input: ChatPostTurnInput) -> Self {
        Self(displayText: input.reply)
    }
}

/// One embedded chat, as a value: how its prompts are built, what it may do
/// and what happens after a reply. No state — every closure runs per turn.
package struct ChatSurfaceSpec {
    package enum Persistence: Equatable, Sendable {
        /// `chat_messages` rows of an existing conversation.
        case database(conversationID: Int64)
        /// Rows live only as long as the engine (onboarding, setup assistants).
        case memory
    }

    /// The per-surface capability contract (review-rules "The assistant &
    /// chat contracts"): a draft-only surface never sends a tool mode
    /// (AGENT-04). Chosen explicitly by every surface — there is no default.
    package enum ToolAccess: Equatable, Sendable {
        case draftOnly
        case actions(surface: String)

        package func toolMode(key: EmbeddedChatKey, turnID: String) -> ChatToolMode? {
            guard case .actions(let surface) = self, let conversationID = key.conversationID else { return nil }
            return ChatToolMode(surface: surface, conversationID: conversationID, turnID: turnID,
                                contextType: key.contextType, contextID: key.contextID)
        }
    }

    package let key: EmbeddedChatKey
    package let persistence: Persistence
    package let toolAccess: ToolAccess
    /// Sent only while the conversation has no provider session yet.
    package let systemPrompt: @MainActor () -> String
    package let turnPrompt: @MainActor (ChatTurnInput) -> String
    /// Runs once, only for a turn that streamed to its end (never a stopped
    /// or failed one). A result with no text to show still fails the turn.
    package let postTurn: @MainActor (ChatPostTurnInput) -> ChatPostTurnResult
    /// Runs before an owner turn is accepted (composer, starter prompt or
    /// `send`); false refuses it and the text stays in the composer — the
    /// target chat re-reads its task here and refuses once it is deleted.
    package let willSend: @MainActor (String) -> Bool
    /// Asked before a turn the owner did not type starts (queued follow-ups,
    /// Retry); false drops the follow-ups and refuses the retry — the target
    /// chat stops once its task is deleted.
    package let mayContinue: @MainActor () -> Bool
    package let emptyHint: String
    package let starterPrompts: [ChatStarterPrompt]

    package init(
        key: EmbeddedChatKey,
        persistence: Persistence,
        toolAccess: ToolAccess,
        systemPrompt: @escaping @MainActor () -> String,
        turnPrompt: @escaping @MainActor (ChatTurnInput) -> String = { $0.text },
        postTurn: @escaping @MainActor (ChatPostTurnInput) -> ChatPostTurnResult = ChatPostTurnResult.identity,
        willSend: @escaping @MainActor (String) -> Bool = { _ in true },
        mayContinue: @escaping @MainActor () -> Bool = { true },
        emptyHint: String,
        starterPrompts: [ChatStarterPrompt] = []
    ) {
        self.key = key
        self.persistence = persistence
        self.toolAccess = toolAccess
        self.systemPrompt = systemPrompt
        self.turnPrompt = turnPrompt
        self.postTurn = postTurn
        self.willSend = willSend
        self.mayContinue = mayContinue
        self.emptyHint = emptyHint
        self.starterPrompts = starterPrompts
    }
}
