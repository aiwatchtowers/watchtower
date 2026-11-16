import Foundation

// The typed `params` of the chat action kinds (iPhone chat spec §4.5). The keys are snake_case (`ChatWireCoder`), as
// the Go hub reads them (`internal/hub/actions/handlers/chat*.go`); `WatchtowerKit/Tests/Fixtures/chat/actions.json`
// pins both sides. A nil optional is an absent key. Chat actions carry no entity id. Their relay `ActionParams`
// conformance (the `actionKind`) is the phone's (`ChatWireKitConformances.swift`): ChatWire imports nothing of ours.

/// How the hub picks the model of a conversation or a turn: `auto`, or `pinned` with a provider and optional model.
public typealias ChatRouting = ChatFeed.Routing

/// The phone-side limits the hub also checks.
public enum ChatLimits {
    /// The most characters a turn's text may carry. The hub counts Unicode scalars (Go runes), not Swift
    /// `Character`s: an emoji sequence of several scalars is several characters here.
    public static let maxTextScalars = 32000

    /// The hub's count of `text`: Unicode scalars.
    public static func textLength(_ text: String) -> Int { text.unicodeScalars.count }

    /// Whether `text` is within the cap, counted like the hub.
    public static func textFits(_ text: String) -> Bool { textLength(text) <= maxTextScalars }
}

/// `chat_new`: a new conversation. `clientKey` makes a resend idempotent (the same key gives the same conversation).
public struct ChatNewParams: Codable, Hashable, Sendable {
    public let clientKey: String
    /// nil = no project.
    public let projectID: Int64?
    public let routing: ChatRouting?

    public init(clientKey: String, projectID: Int64? = nil, routing: ChatRouting? = nil) {
        self.clientKey = clientKey
        self.projectID = projectID
        self.routing = routing
    }

    enum CodingKeys: String, CodingKey {
        case clientKey
        case projectID = "projectId"
        case routing
    }
}

/// What a `chat_turn` does. rawValues are wire format.
public enum ChatTurnMode: String, Codable, Hashable, Sendable {
    case send
    case regenerate
    case edit
    /// A regenerate of a reply whose error a retry can help (chat.sock only).
    case retry
    /// Sends the text after the active branch's last reply (chat.sock only).
    case `continue`
}

/// `chat_turn`: starts a turn. `messageID` names the answer to regenerate or the owner message to edit.
public struct ChatTurnParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let mode: ChatTurnMode
    public let messageID: Int64?
    public let text: String
    /// Ids from the `chat_attachment` echoes, in the order they are shown.
    public let attachmentIDs: [Int64]
    public let routing: ChatRouting?

    public init(
        conversationID: Int64,
        mode: ChatTurnMode,
        messageID: Int64? = nil,
        text: String,
        attachmentIDs: [Int64] = [],
        routing: ChatRouting? = nil
    ) {
        self.conversationID = conversationID
        self.mode = mode
        self.messageID = messageID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.routing = routing
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case mode
        case messageID = "messageId"
        case text
        case attachmentIDs = "attachmentIds"
        case routing
    }
}

/// `chat_cancel`: stops the running turn.
public struct ChatCancelParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let turnID: String

    public init(conversationID: Int64, turnID: String) {
        self.conversationID = conversationID
        self.turnID = turnID
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case turnID = "turnId"
    }
}

/// Why the phone asks for a feed. rawValues are wire format.
public enum ChatFeedPurpose: String, Codable, Hashable, Sendable {
    /// The screen is open: the hub watches the feed for 5 min; repeat every 60 s while it stays open.
    case open
    /// Publish once, never counts as the phone looking (it keeps the push on).
    case prefetch
}

/// `chat_feed_request`. `conversationID` 0 asks for the list alone (the list's Retry).
public struct ChatFeedRequestParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let purpose: ChatFeedPurpose

    public init(conversationID: Int64, purpose: ChatFeedPurpose) {
        self.conversationID = conversationID
        self.purpose = purpose
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case purpose
    }
}

/// `chat_page`: one older page of a conversation ("Load earlier messages").
public struct ChatPageParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let beforeMessageID: Int64

    public init(conversationID: Int64, beforeMessageID: Int64) {
        self.conversationID = conversationID
        self.beforeMessageID = beforeMessageID
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case beforeMessageID = "beforeMessageId"
    }
}

/// `chat_search`: full-text search over the Mac's chats.
public struct ChatSearchParams: Codable, Hashable, Sendable {
    public let query: String

    public init(query: String) {
        self.query = query
    }
}

/// `chat_read`: marks the conversation read up to `messageID`.
public struct ChatReadParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let messageID: Int64

    public init(conversationID: Int64, messageID: Int64) {
        self.conversationID = conversationID
        self.messageID = messageID
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case messageID = "messageId"
    }
}

/// `chat_branch_select`: makes the branch through `messageID` the shown one.
public struct ChatBranchSelectParams: Codable, Hashable, Sendable {
    public let messageID: Int64

    public init(messageID: Int64) {
        self.messageID = messageID
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
    }
}

/// What `chat_manage` does. rawValues are wire format.
public enum ChatManageOp: String, Codable, Hashable, Sendable {
    case pin
    case unpin
    case rename
    case delete
    /// Moves the conversation into `projectID` (nil = out of its project; chat.sock only).
    case move
    /// Takes the chat off the list, its messages kept (the Mac's Archive; chat.sock only).
    case archive
}

/// `chat_manage`. `title` goes with `rename` only.
public struct ChatManageParams: Codable, Hashable, Sendable {
    public let conversationID: Int64
    public let op: ChatManageOp
    public let title: String?

    public init(conversationID: Int64, op: ChatManageOp, title: String? = nil) {
        self.conversationID = conversationID
        self.op = op
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case op, title
    }
}

/// The answer to an action the assistant proposed. rawValues are wire format.
public enum ChatActionDecision: String, Codable, Hashable, Sendable {
    case approve
    case reject
}

/// `chat_action_answer`; needs the permissions grant too. `argsSHA256` is the hash of the args the phone showed:
/// the hub refuses an approval whose args changed since (`changed`).
public struct ChatActionAnswerParams: Codable, Hashable, Sendable {
    public let actionID: Int64
    public let decision: ChatActionDecision
    public let argsSHA256: String

    public init(actionID: Int64, decision: ChatActionDecision, argsSHA256: String) {
        self.actionID = actionID
        self.decision = decision
        self.argsSHA256 = argsSHA256
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "actionId"
        case decision
        case argsSHA256 = "argsSha256"
    }
}

/// `chat_entity_search`: the composer's `@` picker. No `kinds` (an empty list) is the mention search; named kinds
/// search those, in order. The hits come back in the applied echo's result (`hits`, at most 20).
public struct ChatEntitySearchParams: Codable, Hashable, Sendable {
    public let query: String
    public let kinds: [String]

    public init(query: String, kinds: [String] = []) {
        self.query = query
        self.kinds = kinds
    }
}

/// `chat_skills_list`: the composer's `/` picker. The skills come back in the applied echo's result (`skills`).
public struct ChatSkillsListParams: Codable, Hashable, Sendable {
    public init() {}
}
