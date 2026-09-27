import Foundation
import GRDB

/// One `chat_messages` row (goose migration 00076 owns the table). New
/// columns decode with `decodeIfPresent` so a Discuss chat reading an old
/// fixture shape still loads.
package struct ChatMessageRecord: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64
    package let parentID: Int64?
    package let role: String
    package let text: String
    package let createdAt: Double
    package let turnID: String
    package let status: String
    package let provider: String?
    package let model: String?
    package let tokensIn: Int?
    package let tokensOut: Int?
    package let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case id, role, text, status, provider, model
        case conversationID = "conversation_id"
        case parentID = "parent_id"
        case createdAt = "created_at"
        case turnID = "turn_id"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case errorCode = "error_code"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        conversationID = try c.decode(Int64.self, forKey: .conversationID)
        parentID = try c.decodeIfPresent(Int64.self, forKey: .parentID)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "complete"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn)
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
    }

    package var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
    package var isUser: Bool { role == "user" }
    package var isAssistant: Bool { role == "assistant" }
}

/// A step's lifecycle. `running` on a finished message means the turn died
/// mid-tool; views render it as stopped, never as a live spinner.
package enum StepState: Equatable, Sendable {
    case running
    case succeeded
    case failed
}

/// One source chip (spec §3.4) — the `tool_end.sources[]` wire item.
package struct ChatSource: Codable, Hashable, Sendable {
    package let kind: String
    package let title: String
    package let url: String?
    package let ref: String

    package init(kind: String, title: String, url: String?, ref: String) {
        self.kind = kind
        self.title = title
        self.url = url
        self.ref = ref
    }

    package var dedupeKey: String {
        if let url, !url.isEmpty { url } else { "\(kind):\(ref)" }
    }

    package static func dedupe(_ sources: [Self]) -> [Self] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Display-only column: an undecodable value renders as "no chips",
    /// which is the honest rendering of a column we cannot read.
    package static func decodeList(_ json: String) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: Data(json.utf8))) ?? []
    }

    package static func encodeList(_ sources: [Self]) -> String {
        guard let data = try? JSONEncoder().encode(sources), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// One `chat_turn_steps` row.
package struct ChatTurnStep: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let messageID: Int64
    package let seq: Int
    package let toolID: String
    package let name: String
    package let argsJSON: String
    package let okFlag: Int?
    package let summary: String
    package let sourcesJSON: String
    package let startedAt: Double
    package let endedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, seq, name, summary
        case messageID = "message_id"
        case toolID = "tool_id"
        case argsJSON = "args_json"
        case okFlag = "ok"
        case sourcesJSON = "sources_json"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    package var state: StepState {
        switch okFlag {
        case .some(1): .succeeded
        case .some: .failed
        case .none: .running
        }
    }

    package var sources: [ChatSource] { ChatSource.decodeList(sourcesJSON) }

    package var display: ChatStepDisplay {
        ChatStepDisplay(
            id: toolID, name: name, argsJSON: argsJSON, state: state, summary: summary, sources: sources,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// What the steps block renders — built from a persisted row or a live step.
package struct ChatStepDisplay: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let argsJSON: String
    package var state: StepState
    package var summary: String
    package var sources: [ChatSource]
    package let startedAt: Date
    package var endedAt: Date?

    package init(
        id: String,
        name: String,
        argsJSON: String,
        state: StepState,
        summary: String,
        sources: [ChatSource],
        startedAt: Date,
        endedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
        self.state = state
        self.summary = summary
        self.sources = sources
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One visible message of the active branch, with what its row needs.
package struct ChatThreadItem: Identifiable, Equatable, Sendable {
    package let message: ChatMessageRecord
    package let steps: [ChatTurnStep]
    /// 1-based position among siblings; `‹ i/n ›` shows when count > 1.
    package let siblingIndex: Int
    package let siblingCount: Int
    /// Files sent with this message (owner rows only in practice). Fetched
    /// batched alongside `steps` — see `ChatTreeQueries.thread`.
    package let attachments: [ChatAttachment]

    package init(
        message: ChatMessageRecord,
        steps: [ChatTurnStep],
        siblingIndex: Int,
        siblingCount: Int,
        attachments: [ChatAttachment] = []
    ) {
        self.message = message
        self.steps = steps
        self.siblingIndex = siblingIndex
        self.siblingCount = siblingCount
        self.attachments = attachments
    }

    package var id: Int64 { message.id }
    package var stepDisplays: [ChatStepDisplay] { steps.map(\.display) }
    package var sources: [ChatSource] { ChatSource.dedupe(steps.flatMap(\.sources)) }
}

/// Which `chat_files/` subtree a stored file belongs to (spec §7.1).
package enum ChatAttachmentOwner: Equatable, Hashable, Sendable {
    case conversation(Int64)
    case project(Int64)

    var directoryName: String {
        switch self {
        case .conversation(let id): return "conversations/\(id)"
        case .project(let id): return "projects/\(id)"
        }
    }
}

/// One `chat_attachments` row (goose migration 00076).
package struct ChatAttachment: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64?
    package let projectID: Int64?
    package let messageID: Int64?
    package let name: String
    package let mime: String
    package let size: Int64
    package let path: String
    package let sha256: String
    package let createdAt: Double

    package enum CodingKeys: String, CodingKey {
        case id, name, mime, size, path, sha256
        case conversationID = "conversation_id"
        case projectID = "project_id"
        case messageID = "message_id"
        case createdAt = "created_at"
    }

    package init(
        id: Int64,
        conversationID: Int64?,
        projectID: Int64?,
        messageID: Int64?,
        name: String,
        mime: String,
        size: Int64,
        path: String,
        sha256: String,
        createdAt: Double
    ) {
        self.id = id
        self.conversationID = conversationID
        self.projectID = projectID
        self.messageID = messageID
        self.name = name
        self.mime = mime
        self.size = size
        self.path = path
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

/// One `chat_artifacts` row (goose migration 00076) — one version of an
/// artifact block, keyed by `(conversation_id, artifact_key, version)`.
package struct ChatArtifact: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64
    package let messageID: Int64
    package let artifactKey: String
    package let version: Int
    package let kind: String
    package let title: String
    package let content: String
    package let metaJSON: String?
    package let edited: Bool
    package let createdAt: Double

    package enum CodingKeys: String, CodingKey {
        case id, version, kind, title, content, edited
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case artifactKey = "artifact_key"
        case metaJSON = "meta_json"
        case createdAt = "created_at"
    }

    /// Meta attributes; an unreadable blob renders as no meta (display-only data).
    package var meta: [String: String] {
        guard let data = metaJSON?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    package var asDraft: ArtifactDraft {
        ArtifactDraft(key: artifactKey, kind: kind, title: title, meta: meta, content: content, isComplete: true)
    }
}

/// One `chat_projects` row (goose migration 00076).
package struct ChatProject: FetchableRecord, Decodable, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let name: String
    package let instructions: String
    package let createdAt: Double
    package let updatedAt: Double
    package let archivedAt: Double?

    package enum CodingKeys: String, CodingKey {
        case id, name, instructions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

/// One `chat_project_sources` row (goose migration 00076): an entity pinned to
/// a project as where the assistant looks first.
package struct ChatProjectSource: FetchableRecord, Decodable, Identifiable, Equatable, Hashable, Sendable {
    /// The `chat_project_sources.kind` CHECK values (migration 00076).
    package enum Kind: String, CaseIterable, Sendable {
        case jiraProject = "jira_project"
        case slackChannel = "slack_channel"
        case target
        case track
        case person
    }

    package let id: Int64
    package let projectID: Int64
    package let kind: String
    package let ref: String
    package let label: String

    package var sourceKind: Kind? { Kind(rawValue: kind) }

    package enum CodingKeys: String, CodingKey {
        case id, kind, ref, label
        case projectID = "project_id"
    }
}
