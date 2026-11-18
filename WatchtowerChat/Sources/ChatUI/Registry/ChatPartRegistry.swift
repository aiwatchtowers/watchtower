import ChatWire
import SwiftUI

/// One view per part kind (unified chat spec §6.1, G5). A kind this table does not know — a part from a newer engine —
/// renders its fallback (`FallbackPartView`), and so does a known kind whose payload is missing or does not decode.
/// CHAT-06: every kind of `internal/chatengine/testdata/parts.json`, the client-derived `artifact` and `question`
/// included, is registered here (`ChatUITests.testChat06EveryFixtureKindIsRegistered`). The Mac's `SocketChatClient`
/// sends `registered` as its hello's `part_kinds` (ruling F12).
public struct ChatPartRegistry {
    private typealias Render = (ChatPart, ChatPartContext) -> AnyView?

    private static let table: [String: (type: Any.Type, render: Render)] = [
        ChatPartKind.text: (TextPartView.self, { part, context in
            (try? part.decodePayload(ChatTextPayload.self)).map { AnyView(TextPartView(payload: $0, context: context)) }
        }),
        ChatPartKind.steps: (StepsPartView.self, { part, context in
            (try? part.decodePayload(ChatStepsPayload.self)).map { AnyView(StepsPartView(payload: $0, context: context)) }
        }),
        ChatPartKind.sources: (SourcesPartView.self, { part, context in
            (try? part.decodePayload(ChatSourcesPayload.self)).map { AnyView(SourcesPartView(payload: $0, context: context)) }
        }),
        ChatPartKind.artifact: (ArtifactPartView.self, { part, context in
            ChatMessageParts.draft(part).map { AnyView(ArtifactPartView(draft: $0, context: context)) }
        }),
        ChatPartKind.approval: (ApprovalPartView.self, { part, context in
            (try? part.decodePayload(ChatApprovalPayload.self)).map { AnyView(ApprovalPartView(payload: $0, context: context)) }
        }),
        ChatPartKind.question: (QuestionPartView.self, { part, context in
            ChatMessageParts.card(part).map { card in
                AnyView(QuestionPartView(
                    card: card,
                    answerText: context.answerText,
                    onAnswer: context.isAnswerable ? context.actions.sendFixedText : nil
                ))
            }
        }),
        ChatPartKind.error: (ErrorPartView.self, { part, context in
            (try? part.decodePayload(ChatErrorPayload.self)).map { AnyView(ErrorPartView(payload: $0, context: context)) }
        }),
        ChatPartKind.rememberMark: (RememberMarkPartView.self, { part, _ in
            (try? part.decodePayload(ChatRememberPayload.self)).map { AnyView(RememberMarkPartView(payload: $0)) }
        }),
        ChatPartKind.knowledgeMark: (KnowledgeMarkPartView.self, { part, _ in
            (try? part.decodePayload(ChatKnowledgePayload.self)).map { AnyView(KnowledgeMarkPartView(payload: $0)) }
        }),
        ChatPartKind.publishedLink: (PublishedLinkPartView.self, { part, context in
            (try? part.decodePayload(ChatPublishedLinkPayload.self))
                .flatMap { PublishedLinkPartView(payload: $0, context: context) }
                .map { AnyView($0) }
        }),
        ChatPartKind.attachment: (AttachmentPartView.self, { part, _ in
            (try? part.decodePayload(ChatFeed.Attachment.self)).map { AnyView(AttachmentPartView(attachment: $0)) }
        }),
        ChatPartKind.routingNote: (RoutingNotePartView.self, { part, _ in
            (try? part.decodePayload(ChatRoutingPayload.self)).map { AnyView(RoutingNotePartView(payload: $0)) }
        })
    ]

    /// The kinds this package draws.
    public static let registered: Set<String> = Set(table.keys)

    /// The part's view; its fallback when the kind is unknown or its payload unreadable.
    public static func view(for part: ChatPart, context: ChatPartContext) -> AnyView {
        table[part.kind]?.render(part, context) ?? AnyView(FallbackPartView(fallback: part.fallback, actions: context.actions))
    }

    /// The view type `view(for:context:)` draws for `part` (tests).
    public static func viewType(for part: ChatPart, context: ChatPartContext) -> Any.Type {
        guard let entry = table[part.kind], entry.render(part, context) != nil else { return FallbackPartView.self }
        return entry.type
    }
}
