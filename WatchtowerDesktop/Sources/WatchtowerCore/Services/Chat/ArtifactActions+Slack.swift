import Foundation
import WatchtowerChatText

/// The Mac's half of the artifact action table (`WatchtowerChatText.ArtifactActions`): the Slack link a `slack`
/// artifact opens, resolved against the owner's synced workspaces (`SlackLinkResolver`), which only Core knows.
extension ArtifactActions {
    /// Permalink (Slack hosts / `slack:` only) wins; else the stored channel id
    /// (+ `thread_ts`) through the per-account resolver, or the web
    /// archives/app_redirect links when no resolver is at hand. `#name` → nil.
    package static func slackTarget(meta: [String: String], links: SlackLinkResolver? = nil) -> URL? {
        if let raw = meta["permalink"], let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), isSlackURL(url) {
            return url
        }
        guard let channel = meta["channel"]?.trimmingCharacters(in: .whitespaces), !channel.isEmpty, !channel.hasPrefix("#") else {
            return nil
        }
        let ts = meta["thread_ts"].flatMap { $0.isEmpty ? nil : $0 }
        if let links { return links.channelURL(channel, messageTS: ts) }
        if let ts { return SlackDeepLink.archives(channelID: channel, messageTS: ts) }
        return SlackDeepLink.channelRedirect(channelID: channel)
    }

    /// The kind's buttons with the Slack target resolved here (the panel, the Inbox card).
    package static func kindActions(
        for draft: ArtifactDraft, gmailConnected: Bool, slackLinks: SlackLinkResolver?, timeZone: TimeZone = .current
    ) -> [ArtifactMenuItem] {
        kindActions(for: draft, gmailConnected: gmailConnected,
                    slackTarget: draft.kind == "slack" ? slackTarget(meta: draft.meta, links: slackLinks) : nil, timeZone: timeZone)
    }
}
