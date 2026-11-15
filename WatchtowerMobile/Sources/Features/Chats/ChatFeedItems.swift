import Foundation
import WatchtowerChatText
import WatchtowerKit

/// One row of the conversation feed (mockups 2a–2i), diffed by its id: a message keeps its row while its record is
/// replaced, however its text changed (spec §6.3).
enum ChatFeedItem: Identifiable, Equatable {
    case earlier(ChatConversationModel.Earlier)
    case owner(Owner)
    case answer(Answer)
    case actions([ChatApprovalCardModel])

    var id: String {
        switch self {
        case .earlier: "earlier"
        case let .owner(owner): owner.messageID.map { "m\($0)" } ?? "pending"
        case let .answer(answer): "m\(answer.message.id)"
        case .actions: "actions"
        }
    }

    struct Pill: Equatable, Identifiable {
        let id: String
        let name: String
        let isImage: Bool
    }

    /// The owner's message; `messageID` nil is the send still on its way.
    struct Owner: Equatable {
        let messageID: Int64?
        let text: String
        let attachments: [Pill]
        let isPending: Bool
        /// Long-press → Edit (a message the hub stored, while no turn runs).
        let canEdit: Bool
    }

    enum Segment: Equatable, Identifiable {
        case markdown(index: Int, text: String)
        case artifact(ArtifactCard)

        var id: String {
            switch self {
            case let .markdown(index, _): "t\(index)"
            case let .artifact(card): "a\(card.key)"
            }
        }
    }

    /// An artifact's card (mockup 2d): tap opens the sheet (3b).
    struct ArtifactCard: Equatable {
        let key: String
        let kind: String
        let title: String
        let version: Int

        var kindLabel: String { "\(ChatFeedItems.kindName(kind)) · v\(version)" }

        var symbol: String {
            switch kind {
            case "email": "envelope"
            case "event": "calendar"
            case "slack": "number"
            case "table": "tablecells"
            case "code": "chevron.left.forwardslash.chevron.right"
            case "html": "globe"
            default: "doc.text"
            }
        }
    }

    /// The collapsed tool steps (mockups 2a, 2b): one line, tap lists each step with its summary.
    struct Steps: Equatable {
        enum Mark: Equatable { case running, done, failed }

        let mark: Mark
        let line: String
        let steps: [ChatFeed.Step]
    }

    /// "The answer stopped" (mockup 2d): Retry only for a retryable code.
    struct ErrorCard: Equatable {
        static let title = "The answer stopped"
        static let retry = "Retry"

        let line: String
        let retryable: Bool
    }

    struct Answer: Equatable {
        let message: ChatFeed.Message
        let steps: Steps?
        let segments: [Segment]
        let sources: [ChatFeed.Source]
        let error: ErrorCard?
        /// The last answer: ‹ i/n ›, Regenerate and Copy sit under it.
        let isLast: Bool
        /// Text still arriving: the cursor shows, a partial artifact fence is hidden.
        let isStreaming: Bool
        /// The Mac app writes this turn (the grey cursor of mockup 2f).
        let isElsewhere: Bool
    }
}

/// Builds the feed's rows from the messages on screen; pure.
enum ChatFeedItems {
    static let regenerate = "Regenerate"
    static let copy = "Copy"
    static let edit = "Edit"
    static let askAboutThis = "Ask about this"
    static let loadEarlier = "Load earlier messages"

    struct Inputs {
        var messages: [ChatFeed.Message]
        var lease: ChatFeed.Lease?
        var earlier: ChatConversationModel.Earlier?
        var pending: ChatSendCoordinator.PendingTurn?
        var approvals: [ChatApprovalCardModel] = []
        /// Each artifact's latest version (the feed's artifacts).
        var versions: [String: Int] = [:]
    }

    static func build(_ inputs: Inputs) -> [ChatFeedItem] {
        var items: [ChatFeedItem] = []
        if let earlier = inputs.earlier { items.append(.earlier(earlier)) }
        let lastAnswer = inputs.messages.last { $0.role == "assistant" }?.id
        let shown = Set(inputs.messages.map(\.id))
        for message in inputs.messages {
            if message.role == "user" {
                items.append(.owner(ChatFeedItem.Owner(
                    messageID: message.id, text: message.text,
                    attachments: message.attachments.map { .init(id: "\($0.id)", name: $0.name, isImage: $0.mime.hasPrefix("image/")) },
                    isPending: false, canEdit: inputs.lease == nil
                )))
            } else {
                let streaming = inputs.lease != nil && message.id == lastAnswer && message.status != "complete"
                items.append(.answer(answer(
                    message, isLast: message.id == lastAnswer, streaming: streaming, lease: inputs.lease, versions: inputs.versions
                )))
            }
        }
        if let pending = inputs.pending, pending.mode != .regenerate, !(pending.userMessageID.map(shown.contains) ?? false) {
            items.append(.owner(ChatFeedItem.Owner(
                messageID: nil, text: pending.text,
                attachments: pending.attachments.enumerated().map { .init(id: "p\($0.offset)", name: $0.element, isImage: false) },
                isPending: !pending.isApplied, canEdit: false
            )))
        }
        if !inputs.approvals.isEmpty { items.append(.actions(inputs.approvals)) }
        return items
    }

    static func answer(
        _ message: ChatFeed.Message, isLast: Bool, streaming: Bool, lease: ChatFeed.Lease?, versions: [String: Int] = [:]
    ) -> ChatFeedItem.Answer {
        let parsed = ArtifactParser.parse(message.text, final: !streaming)
        var segments: [ChatFeedItem.Segment] = []
        for (index, segment) in parsed.segments.enumerated() {
            switch segment {
            case let .markdown(text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(index: index, text: text)) }
            case let .artifact(draft):
                // A fence still being written stays hidden until it closes (the Mac's rule).
                guard draft.isComplete || !streaming else { continue }
                segments.append(.artifact(ChatFeedItem.ArtifactCard(
                    key: draft.key, kind: draft.kind, title: draft.title, version: versions[draft.key] ?? 1
                )))
            }
        }
        let stopped = message.status == "error" || (message.status == "partial" && message.errorCode != nil && !streaming)
        return ChatFeedItem.Answer(
            message: message,
            steps: steps(message.steps),
            segments: segments,
            sources: sources(message.steps),
            error: stopped ? ChatFeedItem.ErrorCard(
                line: ChatErrorCopy.line(code: message.errorCode, detail: message.errorMessage),
                retryable: ChatErrorCopy.isRetryable(message.errorCode)
            ) : nil,
            isLast: isLast,
            isStreaming: streaming,
            isElsewhere: streaming && lease?.owner == "desktop"
        )
    }

    /// "✓ Searched Slack, Jira · 3 steps" once done; the running step's tool while one runs.
    static func steps(_ steps: [ChatFeed.Step]) -> ChatFeedItem.Steps? {
        guard !steps.isEmpty else { return nil }
        if let running = steps.last(where: { $0.outcome == .running }) {
            return .init(mark: .running, line: "Working · \(running.name)", steps: steps)
        }
        let kinds = orderedUnique(steps.flatMap(\.sources).map { kindName($0.kind) })
        let summary = steps.first { !$0.summary.isEmpty }?.summary
        let used = summary ?? (steps.count == 1 ? "Used \(steps[0].name)" : "Used tools")
        let what = kinds.isEmpty ? used : "Searched " + kinds.joined(separator: ", ")
        let line = steps.count == 1 ? what : "\(what) · \(steps.count) steps"
        return .init(mark: steps.contains { $0.outcome == .failed } ? .failed : .done, line: line, steps: steps)
    }

    /// The sources of every step, each once (by ref, else its link and title).
    static func sources(_ steps: [ChatFeed.Step]) -> [ChatFeed.Source] {
        var seen = Set<String>()
        return steps.flatMap(\.sources).filter { source in
            seen.insert(source.ref.isEmpty ? (source.url ?? "") + "|" + source.title : source.ref).inserted
        }
    }

    static func sourcesLabel(_ count: Int) -> String { "Sources · \(count)" }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "slack": "Slack"
        case "jira": "Jira"
        case "linear": "Linear"
        case "email": "Email"
        case "meeting": "Meetings"
        case "document": "Document"
        case "confluence": "Confluence"
        case "web": "Web"
        case "event": "Event"
        case "table": "Table"
        case "code": "Code"
        case "html": "Page"
        default: kind.capitalized
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// The error card's text and Retry, the Mac's table (`ChatErrorPresentation`): the session's own message when it
/// sent one, else the code's phrase.
enum ChatErrorCopy {
    static let detailLimit = 600

    static func message(for code: String?) -> String {
        switch code {
        case "auth": "The AI provider isn't signed in."
        case "quota_exhausted": "Limit reached after work started"
        case "rate_limit": "The provider is rate-limiting requests. Try again in a moment."
        case "provider_unavailable": "The AI provider couldn't be started."
        case "session_lost": "The previous session couldn't be resumed."
        case "attachment_unsupported": "An attachment isn't supported by this provider."
        case "workdir_unsafe": "Watchtower's chat folder isn't private. Delete it, then send your message again."
        default: "Something went wrong while answering."
        }
    }

    static func line(code: String?, detail: String?) -> String {
        guard let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return message(for: code) }
        return text.count > detailLimit ? String(text.prefix(detailLimit)) + "…" : text
    }

    static func isRetryable(_ code: String?) -> Bool {
        code != "quota_exhausted" && code != "auth" && code != "attachment_unsupported" && code != "workdir_unsafe"
    }
}
