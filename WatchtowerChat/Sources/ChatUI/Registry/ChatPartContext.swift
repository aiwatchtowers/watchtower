import ChatWire
import Foundation
import SwiftUI
import WatchtowerChatText

/// The owner's answer to an approval card.
public enum ChatApprovalDecision: Sendable, Equatable {
    case approve
    case reject
}

/// What a part view may do. Every effect goes back to the screen that owns the conversation; a part view never talks
/// to the engine itself. CHAT-05: nothing here sends content on its own — `sendFixedText` posts an owner text the owner
/// pressed (a fallback's `chat_turn`, a question card's answers), and links only open or copy.
public struct ChatPartActions {
    /// Sends `text` as the owner's next message (a fallback button, a question card's answers).
    public var sendFixedText: (String) -> Void
    public var openURL: (URL) -> Void
    public var copy: (String) -> Void
    /// Retry the reply with this id (an error card).
    public var retry: (Int64) -> Void
    /// Continue the stopped reply with this id.
    public var continueStopped: (Int64) -> Void
    /// Opens an artifact in the viewer: the Mac's inspector, the phone's sheet.
    public var openArtifact: (ChatArtifactContent) -> Void
    /// Opens the sources list of a reply.
    public var openSources: ([ChatSource]) -> Void
    /// Approve or reject an agent action: the Mac through `actions approve|reject` (D12), the phone through the hub.
    public var decide: (ChatApprovalPayload, ChatApprovalDecision) -> Void
    /// The Mac's own agent-action card (Slack editing, reconnect, the automation editor), shared with its Inbox. Nil
    /// on the phone and in tests: the shared approval card draws the action.
    public var approvalCard: ((ChatApprovalPayload) -> AnyView?)?
    /// The Mac's "Review actions" on a reply stopped by the subscription quota: shows the reply's actions; nil hides
    /// the button.
    public var reviewActions: ((Int64) -> Void)?

    public init(
        sendFixedText: @escaping (String) -> Void = { _ in },
        openURL: @escaping (URL) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        retry: @escaping (Int64) -> Void = { _ in },
        continueStopped: @escaping (Int64) -> Void = { _ in },
        openArtifact: @escaping (ChatArtifactContent) -> Void = { _ in },
        openSources: @escaping ([ChatSource]) -> Void = { _ in },
        decide: @escaping (ChatApprovalPayload, ChatApprovalDecision) -> Void = { _, _ in },
        approvalCard: ((ChatApprovalPayload) -> AnyView?)? = nil,
        reviewActions: ((Int64) -> Void)? = nil
    ) {
        self.sendFixedText = sendFixedText
        self.openURL = openURL
        self.copy = copy
        self.retry = retry
        self.continueStopped = continueStopped
        self.openArtifact = openArtifact
        self.openSources = openSources
        self.decide = decide
        self.approvalCard = approvalCard
        self.reviewActions = reviewActions
    }
}

/// Everything a part view knows besides its part: the message it belongs to, the conversation's stored artifacts,
/// whether its question card can still be answered and what answered it, and the actions it may take.
public struct ChatPartContext {
    public var message: ChatFeed.Message
    /// The provider that answered (the sign-in hint of an `auth` error).
    public var provider: String?
    /// The conversation's stored artifact versions (the feed's `artifacts`).
    public var artifacts: [ChatFeed.Artifact]
    /// The question card on this reply can be answered now (the latest reply, nothing answered it, no turn runs).
    public var isAnswerable: Bool
    /// The owner's message right after this reply: an answered card reads its selections from it.
    public var answerText: String?
    public var actions: ChatPartActions

    public init(
        message: ChatFeed.Message,
        provider: String? = nil,
        artifacts: [ChatFeed.Artifact] = [],
        isAnswerable: Bool = false,
        answerText: String? = nil,
        actions: ChatPartActions = ChatPartActions()
    ) {
        self.message = message
        self.provider = provider
        self.artifacts = artifacts
        self.isAnswerable = isAnswerable
        self.answerText = answerText
        self.actions = actions
    }

    /// The reply is written to the end (not `pending`): a half-written artifact or question is held back until then.
    public var isFinal: Bool { message.status != ChatMessageStatus.pending }
}

/// The reply statuses the engine writes (Go `chatstore`).
public enum ChatMessageStatus {
    public static let pending = "pending"
    public static let complete = "complete"
    public static let partial = "partial"
    public static let error = "error"
}
