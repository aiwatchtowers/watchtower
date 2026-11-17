import ChatWire
import Foundation
import WatchtowerChatText

// The payloads of the part kinds (Go `chatengine/parts.go`, pinned by `internal/chatengine/testdata/parts.json`), read
// with `ChatPart.decodePayload`. A payload that does not decode renders the part's fallback.

struct ChatTextPayload: Decodable, Equatable {
    let text: String
    let textCut: Bool

    init(text: String, textCut: Bool = false) {
        self.text = text
        self.textCut = textCut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        textCut = try c.decodeIfPresent(Bool.self, forKey: .textCut) ?? false
    }

    enum CodingKeys: String, CodingKey { case text, textCut }
}

struct ChatStepsPayload: Decodable, Equatable {
    struct Step: Decodable, Equatable {
        let name: String
        /// `ok` on the wire: absent while the tool runs, then true or false.
        let outcome: ChatFeed.Step.Outcome
        let summary: String
        /// Set only for steps that carry their times (the Mac's embedded chats).
        let startedAt: Date?
        let endedAt: Date?
        let argsJSON: String?
        let isWaiting: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            outcome = switch try c.decodeIfPresent(Bool.self, forKey: .ok) {
            case nil: .running
            case true?: .succeeded
            case false?: .failed
            }
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
            argsJSON = try c.decodeIfPresent(String.self, forKey: .argsJSON)
            isWaiting = try c.decodeIfPresent(Bool.self, forKey: .isWaiting) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case name, ok, summary, startedAt, endedAt
            case argsJSON = "argsJson"
            case isWaiting = "waiting"
        }
    }

    let steps: [Step]
}

struct ChatSourcesPayload: Decodable, Equatable {
    let sources: [ChatFeed.Source]
}

struct ChatErrorPayload: Decodable, Equatable {
    let code: String?
    let message: String?
}

struct ChatRememberPayload: Decodable, Equatable {
    let rule: String
}

struct ChatKnowledgePayload: Decodable, Equatable {
    let kind: String
}

struct ChatPublishedLinkPayload: Decodable, Equatable {
    let title: String
    let url: String
}

struct ChatRoutingPayload: Decodable, Equatable {
    let mode: String
    let provider: String?
    let model: String?
    let actualProvider: String?
    let actualModel: String?
}

/// An artifact as the viewer shows it: the latest stored version when there is one, else the draft in the text.
public struct ChatArtifactContent: Equatable, Sendable, Identifiable {
    public let key: String
    public let kind: String
    public let title: String
    public let version: Int
    public let meta: [String: String]
    public let content: String
    public let contentCut: Bool
    /// The block's closing fence has arrived (a streaming reply holds a half-written one back).
    public let isComplete: Bool

    public var id: String { key }

    /// The artifact as the shared text helpers read it (the action table, the viewer's fields).
    public var draft: ArtifactDraft {
        ArtifactDraft(key: key, kind: kind, title: title, meta: meta, content: content, isComplete: isComplete)
    }

    public init(
        key: String,
        kind: String,
        title: String,
        version: Int = 1,
        meta: [String: String] = [:],
        content: String,
        contentCut: Bool = false,
        isComplete: Bool = true
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.version = version
        self.meta = meta
        self.content = content
        self.contentCut = contentCut
        self.isComplete = isComplete
    }

    /// The draft from the text, over the stored version of the same key (the stored content wins: the feed caps a
    /// message's text, not the artifact row).
    public init(draft: ArtifactDraft, stored: ChatFeed.Artifact?) {
        self.init(
            key: draft.key, kind: stored?.kind ?? draft.kind, title: stored?.title ?? draft.title,
            version: stored?.version ?? 1, meta: draft.meta, content: stored?.content ?? draft.content,
            contentCut: stored?.contentCut ?? false, isComplete: draft.isComplete
        )
    }
}
