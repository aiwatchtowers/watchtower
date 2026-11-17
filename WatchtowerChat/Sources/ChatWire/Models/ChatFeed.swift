import Foundation

/// The `chat_feed` slice, record `chat_feed-<conversation id>` (iPhone chat
/// spec §4.6): one conversation the phone watches (`chat_feed_request`
/// open, 5 minutes, repeated every 60 s) or prefetched (2 minutes). It
/// holds the active branch's last 60 messages, the latest version of each
/// artifact and the actions of those turns, within 600 000 bytes: over the
/// cap the oldest messages go first (`hasMore`, "Load earlier messages"),
/// then artifact contents (`contentCut`, "Open on your Mac").
public struct ChatFeed: Decodable, Hashable, Sendable {
    public struct Routing: Hashable, Sendable, Codable {
        /// "auto" or "pinned".
        public let mode: String
        public let provider: String?
        public let model: String?

        public init(mode: String, provider: String? = nil, model: String? = nil) {
            self.mode = mode
            self.provider = provider
            self.model = model
        }
    }

    /// The turn running now, on the Mac ("desktop") or the hub ("hub").
    public struct Lease: Hashable, Sendable, Decodable {
        public let owner: String
        public let turnID: String
        /// The hub turn waits for a free session ("Waiting for a free slot").
        public let waitingSlot: Bool

        public init(owner: String, turnID: String, waitingSlot: Bool = false) {
            self.owner = owner
            self.turnID = turnID
            self.waitingSlot = waitingSlot
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try c.decode(String.self, forKey: .owner)
            turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
            waitingSlot = try c.decodeIfPresent(Bool.self, forKey: .waitingSlot) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case owner
            case turnID = "turnId"
            case waitingSlot
        }
    }

    public struct Conversation: Hashable, Sendable, Decodable, Identifiable {
        public let id: Int64
        public let title: String
        public let project: ChatList.Project?
        public let routing: Routing
        public let actualProvider: String
        public let actualModel: String
        /// Why the chat runs where it runs (`quota_exhausted`, `required_capability_missing`, …); "" from an older
        /// daemon (no fallback, recovered or unsupported state then).
        public let routingReason: String
        /// The first Live Slack message's id (display only on the phone).
        public let liveSlackSince: Int64?
        public let lease: Lease?

        public init(
            id: Int64,
            title: String,
            project: ChatList.Project? = nil,
            routing: Routing = Routing(mode: "auto"),
            actualProvider: String = "",
            actualModel: String = "",
            routingReason: String = "",
            liveSlackSince: Int64? = nil,
            lease: Lease? = nil
        ) {
            self.id = id
            self.title = title
            self.project = project
            self.routing = routing
            self.actualProvider = actualProvider
            self.actualModel = actualModel
            self.routingReason = routingReason
            self.liveSlackSince = liveSlackSince
            self.lease = lease
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            project = try c.decodeIfPresent(ChatList.Project.self, forKey: .project)
            routing = try c.decodeIfPresent(Routing.self, forKey: .routing) ?? Routing(mode: "auto")
            actualProvider = try c.decodeIfPresent(String.self, forKey: .actualProvider) ?? ""
            actualModel = try c.decodeIfPresent(String.self, forKey: .actualModel) ?? ""
            routingReason = try c.decodeIfPresent(String.self, forKey: .routingReason) ?? ""
            liveSlackSince = try c.decodeIfPresent(Int64.self, forKey: .liveSlackSince)
            lease = try c.decodeIfPresent(Lease.self, forKey: .lease)
        }

        enum CodingKeys: String, CodingKey {
            case id, title, project, routing, actualProvider, actualModel, routingReason, liveSlackSince, lease
        }
    }

    public struct Attachment: Hashable, Sendable, Codable, Identifiable {
        public let id: Int64
        public let name: String
        public let mime: String
        public let size: Int64

        public init(id: Int64, name: String, mime: String, size: Int64) {
            self.id = id
            self.name = name
            self.mime = mime
            self.size = size
        }
    }

    public struct Source: Hashable, Sendable, Decodable {
        public let kind: String
        public let title: String
        public let url: String?
        public let ref: String
        public let group: String?
        public let snippet: String?
        public let date: String?

        public init(
            kind: String,
            title: String,
            url: String? = nil,
            ref: String = "",
            group: String? = nil,
            snippet: String? = nil,
            date: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.url = url
            self.ref = ref
            self.group = group
            self.snippet = snippet
            self.date = date
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url)
            ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
            group = try c.decodeIfPresent(String.self, forKey: .group)
            snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
            date = try c.decodeIfPresent(String.self, forKey: .date)
        }

        enum CodingKeys: String, CodingKey {
            case kind, title, url, ref, group, snippet, date
        }
    }

    /// One tool call of a turn.
    public struct Step: Hashable, Sendable, Decodable {
        /// The wire's `ok`: absent while the call runs, then true or false.
        public enum Outcome: Hashable, Sendable {
            case running, succeeded, failed
        }

        public let name: String
        public let outcome: Outcome
        public let summary: String
        public let sources: [Source]
        /// When the call started and ended — set by the Mac's embedded chats, whose steps carry their times (the
        /// "Worked for 12s" header); the engine's wire sends none.
        public let startedAt: Date?
        public let endedAt: Date?
        /// The call's arguments, and whether it waits for the owner's approval — also only from the Mac's embedded
        /// chats, whose step lines name the call from its arguments (`ChatUIStyle.stepLine`).
        public let argsJSON: String?
        public let isWaiting: Bool

        public init(
            name: String,
            outcome: Outcome = .running,
            summary: String = "",
            sources: [Source] = [],
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            argsJSON: String? = nil,
            isWaiting: Bool = false
        ) {
            self.name = name
            self.outcome = outcome
            self.summary = summary
            self.sources = sources
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.argsJSON = argsJSON
            self.isWaiting = isWaiting
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            switch try c.decodeIfPresent(Bool.self, forKey: .ok) {
            case nil: outcome = .running
            case true?: outcome = .succeeded
            case false?: outcome = .failed
            }
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
            argsJSON = try c.decodeIfPresent(String.self, forKey: .argsJSON)
            isWaiting = try c.decodeIfPresent(Bool.self, forKey: .isWaiting) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case name, ok, summary, sources, startedAt, endedAt
            case argsJSON = "argsJson"
            case isWaiting = "waiting"
        }
    }

    /// A message's place among its branch siblings, 1-based ("2/3").
    public struct Siblings: Hashable, Sendable, Decodable {
        public let index: Int
        public let count: Int
        /// The siblings' message ids in order, sent only when there are two or more: ‹ and › select the one before
        /// or after (`chat_branch_select`).
        public let ids: [Int64]

        public init(index: Int = 1, count: Int = 1, ids: [Int64] = []) {
            self.index = index
            self.count = count
            self.ids = ids
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 1
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
            ids = try c.decodeIfPresent([Int64].self, forKey: .ids) ?? []
        }

        /// The sibling `step` places away (-1 = ‹, +1 = ›); nil at either end or without the ids.
        public func neighbour(_ step: Int) -> Int64? {
            let target = index - 1 + step
            guard ids.count == count, ids.indices.contains(target) else { return nil }
            return ids[target]
        }

        enum CodingKeys: String, CodingKey {
            case index, count, ids
        }
    }

    /// One message of the active branch (also `ChatPage`'s).
    public struct Message: Hashable, Sendable, Decodable, Identifiable {
        public let id: Int64
        /// "user" or "assistant".
        public let role: String
        /// Cap 40 000 characters; `textCut` marks a cut.
        public let text: String
        public let textCut: Bool
        /// "complete", "partial" or "error".
        public let status: String
        public let errorCode: String?
        public let errorMessage: String?
        public let createdAt: Date
        public let siblings: Siblings
        public let attachments: [Attachment]
        public let steps: [Step]
        /// The typed pieces with their fallbacks (unified chat spec §5.3); nil when a Mac one version behind sent
        /// none, then `resolvedParts` builds them from the flat fields above (D22).
        public let parts: [ChatPart]?

        public init(
            id: Int64,
            role: String,
            text: String,
            textCut: Bool = false,
            status: String = "complete",
            errorCode: String? = nil,
            errorMessage: String? = nil,
            createdAt: Date,
            siblings: Siblings = Siblings(),
            attachments: [Attachment] = [],
            steps: [Step] = [],
            parts: [ChatPart]? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.textCut = textCut
            self.status = status
            self.errorCode = errorCode
            self.errorMessage = errorMessage
            self.createdAt = createdAt
            self.siblings = siblings
            self.attachments = attachments
            self.steps = steps
            self.parts = parts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            textCut = try c.decodeIfPresent(Bool.self, forKey: .textCut) ?? false
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "complete"
            errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
            errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            siblings = try c.decodeIfPresent(Siblings.self, forKey: .siblings) ?? Siblings()
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
            parts = try c.decodeIfPresent([ChatPart].self, forKey: .parts)
        }

        enum CodingKeys: String, CodingKey {
            case id, role, text, textCut, status, errorCode, errorMessage, createdAt, siblings, attachments, steps, parts
        }
    }

    /// The latest version of one artifact key; `content` is nil when the
    /// feed cap cut it (`contentCut`: open it on the Mac).
    public struct Artifact: Hashable, Sendable, Decodable {
        public let key: String
        public let kind: String
        public let title: String
        public let version: Int
        public let content: String?
        public let contentCut: Bool

        public init(key: String, kind: String, title: String, version: Int, content: String?, contentCut: Bool = false) {
            self.key = key
            self.kind = kind
            self.title = title
            self.version = version
            self.content = content
            self.contentCut = contentCut
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            content = try c.decodeIfPresent(String.self, forKey: .content)
            contentCut = try c.decodeIfPresent(Bool.self, forKey: .contentCut) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case key, kind, title, version, content, contentCut
        }
    }

    /// An agent action of a turn shown: a pending one is answered with
    /// `chat_action_answer` and `argsSHA256` (the args shown).
    public struct Action: Hashable, Sendable, Decodable, Identifiable {
        public let id: Int64
        public let tool: String
        public let title: String
        /// Indented args, cap 4000 characters.
        public let argsDisplay: String
        public let argsSHA256: String
        public let status: String
        public let reason: String?
        /// The approval card's fields (`ChatApprovalPayload`), absent from an engine one version behind.
        public let external: Bool
        public let error: String
        public let result: [String: String]
        public let turnID: String
        public let argsComplete: Bool

        public init(
            id: Int64,
            tool: String,
            title: String,
            argsDisplay: String,
            argsSHA256: String,
            status: String,
            reason: String? = nil,
            external: Bool = false,
            error: String = "",
            result: [String: String] = [:],
            turnID: String = "",
            argsComplete: Bool = false
        ) {
            self.id = id
            self.tool = tool
            self.title = title
            self.argsDisplay = argsDisplay
            self.argsSHA256 = argsSHA256
            self.status = status
            self.reason = reason
            self.external = external
            self.error = error
            self.result = result
            self.turnID = turnID
            self.argsComplete = argsComplete
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            tool = try c.decode(String.self, forKey: .tool)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            argsDisplay = try c.decodeIfPresent(String.self, forKey: .argsDisplay) ?? ""
            argsSHA256 = try c.decodeIfPresent(String.self, forKey: .argsSHA256) ?? ""
            status = try c.decode(String.self, forKey: .status)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            result = try c.decodeIfPresent([String: String].self, forKey: .result) ?? [:]
            turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
            argsComplete = try c.decodeIfPresent(Bool.self, forKey: .argsComplete) ?? false
        }

        // convertFromSnakeCase maps "args_sha256" -> "argsSha256", "turn_id" -> "turnId".
        enum CodingKeys: String, CodingKey {
            case id, tool, title, argsDisplay
            case argsSHA256 = "argsSha256"
            case status, reason, external, error, result, argsComplete
            case turnID = "turnId"
        }
    }

    public let conversation: Conversation
    /// Oldest first.
    public let messages: [Message]
    /// Older messages exist: `chat_page` loads them.
    public let hasMore: Bool
    public let artifacts: [Artifact]
    public let actions: [Action]

    public init(
        conversation: Conversation,
        messages: [Message],
        hasMore: Bool = false,
        artifacts: [Artifact] = [],
        actions: [Action] = []
    ) {
        self.conversation = conversation
        self.messages = messages
        self.hasMore = hasMore
        self.artifacts = artifacts
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(Conversation.self, forKey: .conversation)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        artifacts = try c.decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case conversation, messages, hasMore, artifacts, actions
    }
}
