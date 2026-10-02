import Foundation

/// Prompt rules the Discuss chats still build in Swift (the main chat's
/// prompt moved to Go, `internal/chat`). `knowledgeLinkRule` is a deliberate
/// dual path with Go's `LinkingRules` — change both together. Every tool name
/// in this file and in the Discuss surfaces' `=== TOOLS` blocks must be a
/// registered Go read tool: `internal/tools/prompt_mentions_test.go` fails
/// otherwise.
package enum ChatPromptRules {
    /// Written against a real failure: tools the model cannot use get
    /// silently denied in headless mode, so an unbriefed model wastes a turn
    /// on them and then asks the owner to "approve tool permissions".
    package static let noLiveSourcesRule = """
        You have NO shell, NO filesystem access, NO internet, and NO live access to Slack, Jira, \
        or Calendar — the local Watchtower database already mirrors them, and the tools listed above \
        are the ONLY way in. Never say you will check an external system, and never ask the user to \
        approve tool permissions: everything you can use is already connected; everything else is \
        unavailable by design.
        """

    package static let knowledgeLinkRule =
        "search_knowledge hits: prefer the hit's \"link\" (a permalink) when present. To link a specific " +
        "Slack message instead, take anchor.channel_id without its \"N:\" account prefix (\"1:C123\" → C123) " +
        "and, as the message ts, anchor.thread_ts for a thread hit, otherwise the hit's chunk_anchor. " +
        "A Confluence hit links via its \"link\" (the page or attachment URL); when its chunk_anchor is a URL, " +
        "that is a deep link to the matching heading or comment."
}
