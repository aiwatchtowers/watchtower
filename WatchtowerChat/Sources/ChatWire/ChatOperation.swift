import Foundation

/// One chat operation (unified chat spec §5.2). On chat.sock it is `{"op": wireOp, "params": wireParams()}` (the
/// numbered protocol in Go `internal/chatengine/server.go`, the params as `chatengine/ops*.go` reads them); the
/// phone's client maps each case onto its relay action kind.
public enum ChatOperation: Sendable, Equatable {
    case new(projectID: Int64?, routing: ChatRouting)
    case turn(ChatTurnRequest)
    case cancel(conversationID: Int64, turnID: String)
    case page(conversationID: Int64, beforeMessageID: Int64)
    case search(query: String)
    case read(conversationID: Int64, messageID: Int64)
    case branchSelect(messageID: Int64)
    /// `title` goes with `rename`, `projectID` with `move` (nil = out of its project).
    case manage(conversationID: Int64, op: ChatManageOp, title: String?, projectID: Int64?)
    case project(ChatProjectRequest)
    case artifact(ChatArtifactRequest)
    case attach(conversationID: Int64, source: ChatAttachSource)
    /// Drops a composer attachment that was never sent.
    case attachDiscard(conversationID: Int64, attachmentID: Int64)
    /// The `@` picker: no kinds = the mention search; named kinds search those, in order.
    case entitySearch(query: String, kinds: [String])
    /// The `/` picker.
    case skillsList
    /// Mac only: stops the engine (`sync stop`).
    case shutdown
}

/// Why `wireParams()` cannot encode an operation.
public enum ChatWireError: Error, Equatable {
    /// The operation does not travel over chat.sock (a sealed upload goes through the hub).
    case notOnSocket
}

extension ChatOperation {
    /// The chat.sock operation name.
    public var wireOp: String {
        switch self {
        case .new: "chat_new"
        case .turn: "chat_turn"
        case .cancel: "chat_cancel"
        case .page: "chat_page"
        case .search: "chat_search"
        case .read: "chat_read"
        case .branchSelect: "chat_branch_select"
        case .manage: "chat_manage"
        case .project: "project_manage"
        case .artifact: "artifact_manage"
        case .attach: "attach"
        case .attachDiscard: "attach_discard"
        case .entitySearch: "entity_search"
        case .skillsList: "skills_list"
        case .shutdown: "chat_shutdown"
        }
    }

    /// The chat.sock params object (`ChatWireCoder`: snake_case keys, a nil optional is an absent key).
    public func wireParams() throws -> Data {
        let encoder = ChatWireCoder.makeEncoder()
        switch self {
        case let .new(projectID, routing):
            return try encoder.encode(NewParams(projectID: projectID, routing: routing))
        case let .turn(request):
            return try encoder.encode(request)
        case let .cancel(conversationID, turnID):
            return try encoder.encode(ChatCancelParams(conversationID: conversationID, turnID: turnID))
        case let .page(conversationID, beforeMessageID):
            return try encoder.encode(ChatPageParams(conversationID: conversationID, beforeMessageID: beforeMessageID))
        case let .search(query):
            return try encoder.encode(ChatSearchParams(query: query))
        case let .read(conversationID, messageID):
            return try encoder.encode(ChatReadParams(conversationID: conversationID, messageID: messageID))
        case let .branchSelect(messageID):
            return try encoder.encode(ChatBranchSelectParams(messageID: messageID))
        case let .manage(conversationID, op, title, projectID):
            return try encoder.encode(ManageParams(conversationID: conversationID, op: op, title: title, projectID: projectID))
        case let .project(request):
            return try encoder.encode(request)
        case let .artifact(request):
            return try encoder.encode(request)
        case let .attach(conversationID, .path(path)):
            return try encoder.encode(AttachParams(conversationID: conversationID, path: path))
        case .attach(_, .sealedUpload):
            throw ChatWireError.notOnSocket
        case let .attachDiscard(conversationID, attachmentID):
            return try encoder.encode(AttachDiscardParams(conversationID: conversationID, attachmentID: attachmentID))
        case let .entitySearch(query, kinds):
            return try encoder.encode(ChatEntitySearchParams(query: query, kinds: kinds))
        case .skillsList, .shutdown:
            return Data("{}".utf8)
        }
    }

    /// Reads the `result` of this operation's applied echo.
    public func decodeResult(_ data: Data) throws -> ChatEchoResult {
        let decoder = ChatWireCoder.makeDecoder()
        switch self {
        case .new:
            return .conversation(id: try decoder.decode(NewResult.self, from: data).conversationID)
        case .turn:
            return .turn(try decoder.decode(ChatTurnStarted.self, from: data))
        case .page:
            return .page(try decoder.decode(ChatPage.self, from: data))
        case .search:
            return .search(try decoder.decode(ChatSearch.self, from: data))
        case .project, .artifact:
            return .id(try decoder.decode(IDResult.self, from: data).id)
        case .attach:
            return .attachment(id: try decoder.decode(AttachResult.self, from: data).attachmentID)
        case .entitySearch:
            return .entities(try decoder.decode(HitsResult.self, from: data).hits ?? [])
        case .skillsList:
            return .skills(try decoder.decode(SkillsResult.self, from: data).skills ?? [])
        case .cancel, .read, .branchSelect, .manage, .attachDiscard, .shutdown:
            return .none
        }
    }
}

/// What an applied operation answered.
public enum ChatEchoResult: Sendable, Equatable {
    /// An acknowledgement with nothing in it.
    case none
    /// `chat_new`: the new conversation.
    case conversation(id: Int64)
    case turn(ChatTurnStarted)
    /// `chat_page`: the older messages.
    case page(ChatPage)
    case search(ChatSearch)
    /// `project_manage` and `artifact_manage`: the written row (a new project, file, comment or version).
    case id(Int64)
    case attachment(id: Int64)
    /// `entity_search`: at most 20 hits.
    case entities([ChatEntityHit])
    case skills([ChatSkill])
}

/// `chat_turn`'s result.
public struct ChatTurnStarted: Hashable, Sendable, Decodable {
    public let userMessageID: Int64
    public let assistantMessageID: Int64
    public let turnID: String

    public init(userMessageID: Int64, assistantMessageID: Int64, turnID: String) {
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.turnID = turnID
    }

    enum CodingKeys: String, CodingKey {
        case userMessageID = "userMessageId"
        case assistantMessageID = "assistantMessageId"
        case turnID = "turnId"
    }
}

/// One hit of the `@` picker.
public struct ChatEntityHit: Hashable, Sendable, Codable {
    /// person, channel, jira, linear, jira_project, confluence_space or target.
    public let kind: String
    public let id: String
    public let label: String
    public let detail: String

    public init(kind: String, id: String, label: String, detail: String = "") {
        self.kind = kind
        self.id = id
        self.label = label
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, label, detail
    }
}

/// One skill of the `/` picker.
public struct ChatSkill: Hashable, Sendable, Codable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

// MARK: - Wire shapes of the operations without a public params type

private struct NewParams: Encodable {
    let projectID: Int64?
    let routing: ChatRouting

    enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case routing
    }
}

private struct ManageParams: Encodable {
    let conversationID: Int64
    let op: ChatManageOp
    let title: String?
    let projectID: Int64?

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case op, title
        case projectID = "projectId"
    }
}

private struct AttachParams: Encodable {
    let conversationID: Int64
    let path: String

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case path
    }
}

private struct AttachDiscardParams: Encodable {
    let conversationID: Int64
    let attachmentID: Int64

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case attachmentID = "attachmentId"
    }
}

private struct NewResult: Decodable {
    let conversationID: Int64

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
    }
}

private struct IDResult: Decodable {
    let id: Int64
}

private struct AttachResult: Decodable {
    let attachmentID: Int64

    enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
    }
}

private struct HitsResult: Decodable {
    let hits: [ChatEntityHit]?
}

private struct SkillsResult: Decodable {
    let skills: [ChatSkill]?
}
