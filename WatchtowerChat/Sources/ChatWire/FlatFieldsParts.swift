import Foundation

extension ChatFeed.Message {
    /// The message's parts: the ones the engine sent, else (a Mac one version behind sends none, D22; kept one
    /// release) the parts its flat fields carry, built the way Go `chatengine.BuildParts` builds them — the text,
    /// the attachments, and for an answer its steps, sources, published links and error. The approvals stay in the feed's `actions`.
    public var resolvedParts: [ChatPart] {
        parts ?? flatFieldParts
    }

    private var flatFieldParts: [ChatPart] {
        var out: [ChatPart] = []
        if !text.isEmpty {
            out.append(.flat(ChatPartKind.text, TextPayload(text: text, textCut: textCut), text))
        }
        for attachment in attachments {
            let line = "Attachment: \(attachment.name) (\(attachment.mime), \(Self.byteSize(attachment.size)))"
            out.append(.flat(ChatPartKind.attachment, attachment, line))
        }
        guard role == "assistant" else { return out }
        if !steps.isEmpty {
            out.append(stepsPart)
            if let sources = sourcesPart { out.append(sources) }
        }
        out += publishedLinkParts
        if status == "error" || errorCode != nil {
            out.append(errorPart)
        }
        return out
    }

    private var stepsPart: ChatPart {
        let payload = steps.map {
            StepPayload(name: $0.name, outcome: $0.outcome, summary: $0.summary, startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
        let lines = steps.map { step in
            let label = step.summary.isEmpty ? step.name : step.summary
            switch step.outcome {
            case .running: return "- \(label)"
            case .succeeded: return "- \(label) (done)"
            case .failed: return "- \(label) (failed)"
            }
        }
        return .flat(ChatPartKind.steps, ["steps": payload], "Steps:\n" + lines.joined(separator: "\n"))
    }

    /// Each source once (a published page is not a source); nil when there are none.
    private var sourcesPart: ChatPart? {
        var seen = Set<String>()
        var list: [ChatFeed.Source] = []
        for source in steps.flatMap(\.sources) where source.kind != Self.publishedKind {
            if seen.insert([source.kind, source.ref, source.url ?? ""].joined(separator: "\u{0}")).inserted {
                list.append(source)
            }
        }
        guard !list.isEmpty else { return nil }
        let lines = list.map { source in
            source.url.map { "- \(source.title) (\($0))" } ?? "- \(source.title)"
        }
        return .flat(ChatPartKind.sources, ["sources": list.map(SourcePayload.init)], "Sources:\n" + lines.joined(separator: "\n"))
    }

    /// One card per claude.ai page the turn published (Go `publishedLinkParts`): each URL once, only a page
    /// `publishedURLPermitted` passes.
    private var publishedLinkParts: [ChatPart] {
        var seen = Set<String>()
        var out: [ChatPart] = []
        for source in steps.flatMap(\.sources) where source.kind == Self.publishedKind {
            guard let url = source.url, Self.publishedURLPermitted(url), seen.insert(url).inserted else { continue }
            let trimmed = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? url : trimmed
            out.append(.flat(ChatPartKind.publishedLink, PublishedLinkPayload(title: title, url: url),
                             "Published on claude.ai: " + title,
                             actions: [ChatPartFallback.Action(label: "Open", action: "open_url", url: url)]))
        }
        return out
    }

    /// Go `chat.SourceKindPublished`.
    static let publishedKind = "claude_ai_published"

    /// Go `publishedURLPermitted` (and `PublishedLink.permits`): https, host exactly claude.ai, no user, password or
    /// port, a path past "/". Fail closed.
    static func publishedURLPermitted(_ raw: String) -> Bool {
        guard let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              parts.percentEncodedHost?.lowercased() == "claude.ai",
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return false }
        return parts.percentEncodedPath.count > 1
    }

    /// The error's code and message; the words for a code are ChatUI's (WatchtowerChatText), so the fallback is
    /// generic.
    private var errorPart: ChatPart {
        var text = "Something went wrong while answering."
        if let errorMessage, !errorMessage.isEmpty { text += "\n" + errorMessage }
        return .flat(ChatPartKind.error, ErrorPayload(code: errorCode ?? "", message: errorMessage), text)
    }

    /// Go's `byteSize`.
    static func byteSize(_ size: Int64) -> String {
        switch size {
        case (1 << 20)...: String(format: "%.1f MB", Double(size) / Double(1 << 20))
        case (1 << 10)...: String(format: "%.0f KB", Double(size) / Double(1 << 10))
        default: "\(size) B"
        }
    }
}

extension ChatPart {
    /// A part built on the client, its payload passed through the wire's coders so it reads like a decoded one.
    fileprivate static func flat(
        _ kind: String, _ payload: some Encodable, _ fallback: String, actions: [ChatPartFallback.Action] = []
    ) -> ChatPart {
        let value = try? ChatWireCoder.makeDecoder().decode(
            ChatJSONValue.self, from: ChatWireCoder.makeEncoder().encode(payload)
        )
        return ChatPart(kind: kind, payload: value, fallback: ChatPartFallback(text: fallback, actions: actions))
    }
}

private struct TextPayload: Encodable {
    let text: String
    let textCut: Bool
}

/// A step as Go writes it: `ok` absent while the call runs.
private struct PublishedLinkPayload: Encodable {
    let title: String
    let url: String
}

private struct StepPayload: Encodable {
    let name: String
    let outcome: ChatFeed.Step.Outcome
    let summary: String
    /// Only from a client that has them (the Mac's embedded chats); Go sends none.
    let startedAt: Date?
    let endedAt: Date?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if outcome != .running {
            try c.encode(outcome == .succeeded, forKey: .ok)
        }
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
    }

    enum CodingKeys: String, CodingKey {
        case name, ok, summary, startedAt, endedAt
    }
}

private struct SourcePayload: Encodable {
    let kind: String
    let title: String
    let url: String?
    let ref: String

    init(_ source: ChatFeed.Source) {
        kind = source.kind
        title = source.title
        url = source.url
        ref = source.ref
    }
}

private struct ErrorPayload: Encodable {
    let code: String
    let message: String?
}
