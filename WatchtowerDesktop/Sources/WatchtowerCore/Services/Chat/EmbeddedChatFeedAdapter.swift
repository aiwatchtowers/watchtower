import ChatWire
import Foundation
import WatchtowerChatText

/// An embedded chat's rows as ChatUI's feed messages (unified chat spec §9.2): embedded chats keep their own engine
/// (`EmbeddedChatEngine`, `ai query --events v2`) and only their drawing moves onto ChatUI. The adapter builds no
/// parts: it maps the text, status, steps, sources, attachments and error field by field and leaves `parts` nil, so
/// `ChatFeed.Message.resolvedParts` builds them from those fields and ChatUI derives the artifacts and the question card
/// from the text with the shared parsers (D14, D22). The branch position is left out: an embedded chat shows its
/// active path and has no branch switcher.
package enum EmbeddedChatFeedAdapter {
    /// `rows` in order; the row `live` streams into shows the live turn's text and steps, `pending` while it runs.
    @MainActor
    package static func messages(rows: [ChatThreadItem], live: LiveTurn?) -> [ChatFeed.Message] {
        rows.map { item in
            if let live, live.messageID == item.id {
                return message(item, text: live.text, steps: live.steps,
                               status: live.isRunning ? pendingStatus : item.message.status)
            }
            return message(item, text: item.message.text, steps: item.stepDisplays, status: item.message.status)
        }
    }

    /// ChatUI's status of a reply still being written.
    package static let pendingStatus = "pending"

    private static func message(_ item: ChatThreadItem, text: String, steps: [ChatStepDisplay], status: String)
        -> ChatFeed.Message {
        let record = item.message
        return ChatFeed.Message(
            id: record.id,
            role: record.role,
            text: text,
            status: status,
            errorCode: record.errorCode,
            errorMessage: record.errorMessage,
            createdAt: record.createdDate,
            attachments: item.attachments.map { ChatFeed.Attachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size) },
            steps: steps.map(step)
        )
    }

    /// A step as the wire carries it: a waiting call is still running.
    package static func step(_ display: ChatStepDisplay) -> ChatFeed.Step {
        let outcome: ChatFeed.Step.Outcome = switch display.state {
        case .running, .waiting: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
        return ChatFeed.Step(name: display.name, outcome: outcome, summary: display.summary,
                             sources: display.sources.map(source))
    }

    package static func source(_ source: ChatSource) -> ChatFeed.Source {
        ChatFeed.Source(kind: source.kind, title: source.title, url: source.url, ref: source.ref, group: source.group,
                        snippet: source.snippet, date: source.date)
    }
}
