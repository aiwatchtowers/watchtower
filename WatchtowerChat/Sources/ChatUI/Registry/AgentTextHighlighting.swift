import Foundation
import WatchtowerChatText

/// A feed's opt-in to colouring the agent's text as an IDE colours code (spec 2026-11-24-workchat-polish §2, spec
/// 2026-11-26-chat-text-highlights "Opt-in"): refs, hashes, commands, dates and times, `PR #N` / `ask #N` phrases and,
/// with a resolver, file paths. `ChatFeedContext.agentTextHighlighting` nil keeps the agent's text plain; the empty
/// value colours without paths or clicks.
public struct AgentTextHighlighting {
    /// Whether a path candidate of the message (by id) is a file of the session's folders; nil colours no path. It may
    /// answer later (an async lookup): the screen re-renders when it lands.
    public var resolvesPath: ((_ path: String, _ messageID: Int64) -> Bool)?
    /// A click on a span that opens (`Kind.opens`); nil keeps every span colour-only.
    public var openHighlight: ((_ span: AgentTextHighlights.Span, _ messageID: Int64) -> Void)?

    public init(resolvesPath: ((String, Int64) -> Bool)? = nil,
                openHighlight: ((AgentTextHighlights.Span, Int64) -> Void)? = nil) {
        self.resolvesPath = resolvesPath
        self.openHighlight = openHighlight
    }
}
