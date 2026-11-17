import ChatWire
import Foundation
import SwiftUI
import WatchtowerChatText

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
    /// What an approval card may do (`AgentActionCard`): the Mac's `actions approve|reject` (D12), the phone's hub.
    public var approvals: ChatApprovalServices
    /// The Mac's "Review actions" on a reply stopped by the subscription quota: shows the reply's actions; nil hides
    /// the button.
    public var reviewActions: ((Int64) -> Void)?
    /// Whether an error card of the reply with this id offers Retry; nil offers it wherever the error is retryable.
    /// An embedded chat retries only its last failed reply while nothing runs.
    public var canRetry: ((Int64) -> Bool)?
    /// Whether a cut reply offers Continue; off for a chat whose engine cannot continue one (embedded chats).
    public var offersContinue = true
    /// Whether a reply shows its sources pill; off for a chat with no sources list to open (embedded chats).
    public var showsSources = true

    public init(
        sendFixedText: @escaping (String) -> Void = { _ in },
        openURL: @escaping (URL) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        retry: @escaping (Int64) -> Void = { _ in },
        continueStopped: @escaping (Int64) -> Void = { _ in },
        openArtifact: @escaping (ChatArtifactContent) -> Void = { _ in },
        openSources: @escaping ([ChatSource]) -> Void = { _ in },
        reviewActions: ((Int64) -> Void)? = nil,
        approvals: ChatApprovalServices = ChatApprovalServices()
    ) {
        self.sendFixedText = sendFixedText
        self.openURL = openURL
        self.copy = copy
        self.retry = retry
        self.continueStopped = continueStopped
        self.openArtifact = openArtifact
        self.openSources = openSources
        self.approvals = approvals
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
    /// The turn running now: an approval card it waits on is outlined.
    public var runningTurnID: String?
    public var actions: ChatPartActions

    public init(
        message: ChatFeed.Message,
        provider: String? = nil,
        artifacts: [ChatFeed.Artifact] = [],
        isAnswerable: Bool = false,
        answerText: String? = nil,
        runningTurnID: String? = nil,
        actions: ChatPartActions = ChatPartActions()
    ) {
        self.message = message
        self.provider = provider
        self.artifacts = artifacts
        self.isAnswerable = isAnswerable
        self.answerText = answerText
        self.runningTurnID = runningTurnID
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
