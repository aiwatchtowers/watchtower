import ChatWire
import Foundation
import WatchtowerChatText

/// A message's parts as the row draws them (unified chat spec D14, §5.3): the engine's parts (or, from a Mac one
/// version behind, the ones `ChatWire` builds from the flat fields), with each `text` part split by
/// `WatchtowerChatText` into its Markdown runs, its `artifact` blocks and its trailing `question` card. The text is the
/// fallback of both, so they are never sent; a server-sent `artifact` or `question` part is dropped, so one thing is
/// never drawn twice. Pure.
public enum ChatMessageParts {
    public static func parts(for message: ChatFeed.Message) -> [ChatPart] {
        let final = message.status != ChatMessageStatus.pending
        var out: [ChatPart] = []
        for part in message.resolvedParts {
            switch part.kind {
            case ChatPartKind.artifact, ChatPartKind.question:
                continue
            case ChatPartKind.text:
                out += split(part, final: final)
            default:
                out.append(part)
            }
        }
        return out
    }

    /// The text part's derived parts, in reading order: Markdown and artifacts as they appear, the card last.
    static func split(_ part: ChatPart, final: Bool) -> [ChatPart] {
        guard let payload = try? part.decodePayload(ChatTextPayload.self) else { return [part] }
        let (rest, card) = ChatQuestionParser.parse(payload.text, final: final)
        var out: [ChatPart] = []
        for segment in ArtifactParser.parse(rest, final: final).segments {
            switch segment {
            case .markdown(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                out.append(textPart(text, cut: false))
            case .artifact(let draft):
                out.append(artifactPart(draft))
            }
        }
        if payload.textCut, let last = out.indices.last(where: { out[$0].kind == ChatPartKind.text }) {
            let text = (try? out[last].decodePayload(ChatTextPayload.self))?.text ?? ""
            out[last] = textPart(text, cut: true)
        }
        if let card {
            out.append(questionPart(card, readable: ChatQuestionParser.readableText(payload.text)))
        }
        return out
    }

    static func textPart(_ text: String, cut: Bool) -> ChatPart {
        ChatPart(
            kind: ChatPartKind.text,
            payload: .object(["text": .string(text), "text_cut": .bool(cut)]),
            fallback: ChatPartFallback(text: text)
        )
    }

    static func artifactPart(_ draft: ArtifactDraft) -> ChatPart {
        ChatPart(
            kind: ChatPartKind.artifact,
            payload: .object([
                "key": .string(draft.key),
                "kind": .string(draft.kind),
                "title": .string(draft.title),
                "content": .string(draft.content),
                "complete": .bool(draft.isComplete),
                "meta": .object(draft.meta.mapValues(ChatJSONValue.string))
            ]),
            fallback: ChatPartFallback(text: draft.title.isEmpty ? draft.content : draft.title)
        )
    }

    static func questionPart(_ card: ChatQuestionCard, readable: String) -> ChatPart {
        let questions: [ChatJSONValue] = card.questions.map { question in
            .object([
                "id": .string(question.id),
                "question": .string(question.question),
                "multi": .bool(question.multi),
                "options": .array(question.options.map { option in
                    .object([
                        "label": .string(option.label),
                        "description": .string(option.description),
                        "recommended": .bool(option.recommended)
                    ])
                })
            ])
        }
        return ChatPart(
            kind: ChatPartKind.question,
            payload: .object(["questions": .array(questions)]),
            fallback: ChatPartFallback(text: readable)
        )
    }

    /// The derived artifact part back as a draft.
    static func draft(_ part: ChatPart) -> ArtifactDraft? {
        guard case .object(let object)? = part.payload, case .string(let key)? = object["key"] else { return nil }
        func string(_ name: String) -> String {
            if case .string(let value)? = object[name] { return value }
            return ""
        }
        var meta: [String: String] = [:]
        if case .object(let raw)? = object["meta"] {
            for (name, value) in raw {
                if case .string(let text) = value { meta[name] = text }
            }
        }
        let complete: Bool = if case .bool(let value)? = object["complete"] { value } else { true }
        return ArtifactDraft(key: key, kind: string("kind"), title: string("title"), meta: meta,
                             content: string("content"), isComplete: complete)
    }

    /// The derived question part back as a card (the same JSON the parser reads).
    static func card(_ part: ChatPart) -> ChatQuestionCard? {
        guard let payload = part.payload, let data = try? JSONEncoder().encode(payload) else { return nil }
        return ChatQuestionParser.decodeCard(data)
    }
}
