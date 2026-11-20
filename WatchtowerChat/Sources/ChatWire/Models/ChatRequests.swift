import Foundation

// The request values of the chat.sock operations (unified chat spec §5.2), as Go `internal/chatengine/ops*.go`
// reads them. Keys are snake_case through `ChatWireCoder`; a nil optional is an absent key.

/// `chat_turn` on chat.sock. `clientKey` makes a resend idempotent: the engine answers a repeated key with the
/// first result (spec §14), so a send whose echo was lost is neither lost nor doubled.
public struct ChatTurnRequest: Sendable, Equatable, Codable {
    public let conversationID: Int64
    public let mode: ChatTurnMode
    /// The answer to regenerate or retry, the owner message to edit, the reply to continue after.
    public let messageID: Int64?
    public let text: String
    /// Ids from the `attach` results, in the order they are shown.
    public let attachmentIDs: [Int64]
    /// nil keeps the conversation's routing.
    public let routing: ChatRouting?
    public let compose: ChatCompose?
    /// The screen the owner asked from (in-app help); never stored.
    public let screenContext: String?
    /// The artifact comments this turn sends to the assistant.
    public let artifactCommentIDs: [Int64]
    public let clientKey: String
    /// A new chat's project, for a client that creates the chat with its first turn (`conversationID` 0,
    /// `ChatClient.createsConversationOnTurn`). Never on chat.sock.
    public var projectID: Int64?
    /// What the composer held when it sent: kept with a send that may outlive the app, so a refused one comes back as
    /// typed. Never on the wire. Set only by the composer's own send: a client that stages files (the phone's relay
    /// client) sends and then clears them only with a turn carrying a draft, so a card answer or an artifact comment
    /// (no draft) leaves the pills staged — a new producer that sets it takes the staged files too.
    public var draft: ChatTurnDraft?

    public init(
        conversationID: Int64,
        mode: ChatTurnMode,
        messageID: Int64? = nil,
        text: String,
        attachmentIDs: [Int64] = [],
        routing: ChatRouting? = nil,
        compose: ChatCompose? = nil,
        screenContext: String? = nil,
        artifactCommentIDs: [Int64] = [],
        clientKey: String,
        projectID: Int64? = nil,
        draft: ChatTurnDraft? = nil
    ) {
        self.conversationID = conversationID
        self.mode = mode
        self.messageID = messageID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.routing = routing
        self.compose = compose
        self.screenContext = screenContext
        self.artifactCommentIDs = artifactCommentIDs
        self.clientKey = clientKey
        self.projectID = projectID
        self.draft = draft
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case mode
        case messageID = "messageId"
        case text
        case attachmentIDs = "attachmentIds"
        case routing, compose, screenContext
        case artifactCommentIDs = "artifactCommentIds"
        case clientKey
    }
}

/// The composer's draft behind a sent turn: the typed text and the quoted passages, before they were composed.
public struct ChatTurnDraft: Sendable, Hashable {
    public let text: String
    public let quotes: [String]

    public init(text: String, quotes: [String] = []) {
        self.text = text
        self.quotes = quotes
    }
}

/// What the composer adds around the typed text: a `/` skill, the `@` mentions and the quote batch (Go
/// `chatstore.Compose`, which composes the stored owner text).
public struct ChatCompose: Sendable, Hashable, Codable {
    public struct Mention: Sendable, Hashable, Codable {
        /// person, channel, jira, linear, target or track.
        public let kind: String
        public let id: String
        public let label: String

        public init(kind: String, id: String, label: String) {
            self.kind = kind
            self.id = id
            self.label = label
        }
    }

    public struct Quote: Sendable, Hashable, Codable {
        /// The answer the passage was taken from.
        public let messageID: Int64
        public let text: String
        public let comment: String?

        public init(messageID: Int64, text: String, comment: String? = nil) {
            self.messageID = messageID
            self.text = text
            self.comment = comment
        }

        enum CodingKeys: String, CodingKey {
            case messageID = "messageId"
            case text, comment
        }
    }

    public let skill: String?
    public let mentions: [Mention]
    public let quotes: [Quote]

    public init(skill: String? = nil, mentions: [Mention] = [], quotes: [Quote] = []) {
        self.skill = skill
        self.mentions = mentions
        self.quotes = quotes
    }
}

/// `project_manage`: every write of a chat project.
public struct ChatProjectRequest: Sendable, Hashable, Codable {
    public let op: ChatProjectOp
    public let projectID: Int64?
    public let name: String?
    public let instructions: String?
    public let sources: [ChatProjectSource]?
    public let sourceID: Int64?
    public let fileID: Int64?
    public let path: String?

    public init(
        op: ChatProjectOp,
        projectID: Int64? = nil,
        name: String? = nil,
        instructions: String? = nil,
        sources: [ChatProjectSource]? = nil,
        sourceID: Int64? = nil,
        fileID: Int64? = nil,
        path: String? = nil
    ) {
        self.op = op
        self.projectID = projectID
        self.name = name
        self.instructions = instructions
        self.sources = sources
        self.sourceID = sourceID
        self.fileID = fileID
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case op
        case projectID = "projectId"
        case name, instructions, sources
        case sourceID = "sourceId"
        case fileID = "fileId"
        case path
    }
}

/// What a `project_manage` does. rawValues are wire format.
public enum ChatProjectOp: String, Sendable, Hashable, Codable {
    /// `name` (nil = "New project") → the new project's id.
    case create
    /// `projectID`; `name` (rename) and/or `instructions`.
    case update
    case archive
    /// The project's chats survive detached; its files go.
    case delete
    /// `projectID`, `sources` (one already pinned is skipped).
    case sourceAdd = "source_add"
    /// `sourceID`.
    case sourceRemove = "source_remove"
    /// `projectID`, `path` (a file the Mac app holds; Mac only) → the file's id.
    case fileAdd = "file_add"
    /// `fileID`.
    case fileRemove = "file_remove"
}

/// One source pinned to a chat project.
public struct ChatProjectSource: Sendable, Hashable, Codable {
    /// jira_project, slack_channel, confluence_space, target, track or person.
    public let kind: String
    public let ref: String
    public let label: String

    public init(kind: String, ref: String, label: String) {
        self.kind = kind
        self.ref = ref
        self.label = label
    }
}

/// `artifact_manage`: every write of the artifact panel.
public struct ChatArtifactRequest: Sendable, Hashable, Codable {
    public let op: ChatArtifactOp
    public let conversationID: Int64?
    public let key: String?
    public let version: Int?
    public let commentID: Int64?
    public let comment: ChatArtifactComment?
    public let moved: [Int64]?
    public let lost: [Int64]?
    public let content: String?

    public init(
        op: ChatArtifactOp,
        conversationID: Int64? = nil,
        key: String? = nil,
        version: Int? = nil,
        commentID: Int64? = nil,
        comment: ChatArtifactComment? = nil,
        moved: [Int64]? = nil,
        lost: [Int64]? = nil,
        content: String? = nil
    ) {
        self.op = op
        self.conversationID = conversationID
        self.key = key
        self.version = version
        self.commentID = commentID
        self.comment = comment
        self.moved = moved
        self.lost = lost
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case op
        case conversationID = "conversationId"
        case key, version
        case commentID = "commentId"
        case comment, moved, lost, content
    }
}

/// What an `artifact_manage` does. rawValues are wire format.
public enum ChatArtifactOp: String, Sendable, Hashable, Codable {
    /// `key`, `version` → Keep (or update) in Knowledge.
    case keep
    /// `key` → Remove from Knowledge.
    case unkeep
    /// `key`, `version`, `comment` → the comment's id.
    case commentAdd = "comment_add"
    /// `commentID`: an unsent comment only.
    case commentDelete = "comment_delete"
    /// `commentID`: a sent or outdated comment only.
    case commentResolve = "comment_resolve"
    /// `key`, `version`, `moved`, `lost`: the panel's re-anchor plan.
    case commentReanchor = "comment_reanchor"
    /// `key`, `version` (the base), `content` → the new version.
    case edit
}

/// A new comment on a passage of an artifact.
public struct ChatArtifactComment: Sendable, Hashable, Codable {
    public let body: String
    public let anchorQuote: String
    public let anchorPrefix: String
    public let anchorSuffix: String
    public let anchorHeading: String

    public init(body: String, anchorQuote: String, anchorPrefix: String = "", anchorSuffix: String = "", anchorHeading: String = "") {
        self.body = body
        self.anchorQuote = anchorQuote
        self.anchorPrefix = anchorPrefix
        self.anchorSuffix = anchorSuffix
        self.anchorHeading = anchorHeading
    }
}

/// Where an attachment's bytes come from.
public enum ChatAttachSource: Sendable, Equatable {
    /// A file the Mac app holds (chat.sock `attach`; Mac only).
    case path(String)
    /// The phone's sealed upload through the hub (`chat_attachment`).
    case sealedUpload(ChatSealedUpload)
}

/// A file the phone prepared for upload (`ChatAttachmentLimits` checked it).
public struct ChatSealedUpload: Sendable, Hashable {
    public let uploadID: String
    public let name: String
    public let mime: String
    public let size: Int64
    /// The prepared bytes on disk.
    public let file: URL

    public init(uploadID: String, name: String, mime: String, size: Int64, file: URL) {
        self.uploadID = uploadID
        self.name = name
        self.mime = mime
        self.size = size
        self.file = file
    }
}
