import Foundation
import GRDB

/// Slack link builders, mirroring `internal/slack/permalink.go`'s
/// `GenerateDeeplink` (the `slack://channel` shapes with and without a
/// message). The `slack://` builders take RAW (un-namespaced) ids plus the
/// owning team — go through `SlackLinkResolver` rather than calling them with a
/// stored id. The web `archives`/`app_redirect` family needs no team, so it
/// takes the stored id and strips the namespace itself via `SlackAccountID`.
package enum SlackDeepLink {
    /// `slack://channel?team=…&id=…[&message=…]`. Nil without a team; an empty
    /// or nil `messageTS` yields the channel-only shape, as in Go.
    package static func channel(teamID: String, rawChannelID: String, messageTS: String? = nil) -> URL? {
        guard !teamID.isEmpty, !rawChannelID.isEmpty else { return nil }
        guard let messageTS, !messageTS.isEmpty else {
            return URL(string: "slack://channel?team=\(teamID)&id=\(rawChannelID)")
        }
        return URL(string: "slack://channel?team=\(teamID)&id=\(rawChannelID)&message=\(messageTS)")
    }

    /// `slack://user?[team=…&]id=…` — the team is omitted when unknown (Slack
    /// then opens the user in the current workspace).
    package static func user(teamID: String, rawUserID: String) -> URL? {
        guard !rawUserID.isEmpty else { return nil }
        guard !teamID.isEmpty else { return URL(string: "slack://user?id=\(rawUserID)") }
        return URL(string: "slack://user?team=\(teamID)&id=\(rawUserID)")
    }

    /// `https://slack.com/archives/<raw>/p<ts without dot>` — Slack's generic
    /// host, no workspace domain needed. A namespaced id would 404.
    package static func archives(channelID: String, messageTS: String) -> URL? {
        let raw = SlackAccountID.raw(channelID)
        guard !raw.isEmpty, !messageTS.isEmpty else { return nil }
        return URL(string: "https://slack.com/archives/\(raw)/p\(messageTS.replacingOccurrences(of: ".", with: ""))")
    }

    /// `https://slack.com/app_redirect?channel=<raw>` — a channel with no message.
    package static func channelRedirect(channelID: String) -> URL? {
        let raw = SlackAccountID.raw(channelID)
        guard !raw.isEmpty else { return nil }
        return URL(string: "https://slack.com/app_redirect?channel=\(raw)")
    }

    /// A target `external_ref` of the form `slack:<channelID>[:<ts>]`
    /// (`TargetPrefillBuilder`, `internal/targets/resolver.go`), where the
    /// channel id may itself be namespaced (`slack:2:C0456:1740.1`) — the
    /// namespace is peeled before the ts split, or a namespaced ref would read
    /// the account number as the channel.
    package static func targetRef(_ ref: String) -> URL? {
        guard ref.hasPrefix("slack:") else { return nil }
        let parts = SlackAccountID.raw(String(ref.dropFirst(6))).split(separator: ":", maxSplits: 1)
        guard let channel = parts.first.map(String.init) else { return nil }
        guard parts.count == 2 else { return channelRedirect(channelID: channel) }
        return archives(channelID: channel, messageTS: String(parts[1]))
    }
}

/// Resolves a stored Slack id to the team + raw id a deep link needs,
/// mirroring `internal/ai/slack_link.go`'s `resolveSlackLinkTarget` ladder
/// exactly (a deliberate dual path — change both sides together):
/// not namespaced ⇒ `(fallback, id)` unchanged; unknown account ⇒
/// `(fallback, rawID)`; account with an empty team id ⇒ `(fallback, rawID)`;
/// else `(account's team, rawID)`. The fallback is the frozen `workspace.id`
/// snapshot of account #1 — the pre-multi-account behavior for bare ids.
package struct SlackLinkResolver: Equatable, Sendable {
    package let teamIDByAccount: [Int: String]
    package let fallbackTeamID: String

    package init(teamIDByAccount: [Int: String], fallbackTeamID: String) {
        self.teamIDByAccount = teamIDByAccount
        self.fallbackTeamID = fallbackTeamID
    }

    /// `slack_accounts` team ids plus the `workspace.id` fallback ("" when the
    /// workspace row is missing).
    package static func load(_ db: Database) throws -> Self {
        Self(
            teamIDByAccount: try SlackAccountQueries.fetchTeamIDs(db),
            fallbackTeamID: try WorkspaceQueries.fetchWorkspace(db)?.id ?? ""
        )
    }

    package func resolve(_ id: String) -> (teamID: String, rawID: String) {
        guard let (accountID, rawID) = SlackAccountID.split(id) else { return (fallbackTeamID, id) }
        guard let teamID = teamIDByAccount[accountID], !teamID.isEmpty else { return (fallbackTeamID, rawID) }
        return (teamID, rawID)
    }

    package func channelURL(_ channelID: String, messageTS: String? = nil) -> URL? {
        let (teamID, rawID) = resolve(channelID)
        return SlackDeepLink.channel(teamID: teamID, rawChannelID: rawID, messageTS: messageTS)
    }

    package func userURL(_ userID: String) -> URL? {
        let (teamID, rawID) = resolve(userID)
        return SlackDeepLink.user(teamID: teamID, rawUserID: rawID)
    }
}
