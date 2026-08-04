package ai

import (
	"log"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// slackAccountCache is a per-builder/renderer cache of Slack account lookups
// by id, shared by ContextBuilder and ResponseRenderer's resolveLinkTarget so
// a message-formatting loop over hundreds of messages does one DB round-trip
// per connected account, not one per message (the channelNameCache/userCache
// pattern already used elsewhere in this package).
type slackAccountCache map[int64]db.SlackAccount

// resolveSlackLinkTarget resolves the Slack team id and raw (un-namespaced)
// channel id to use when building a deep link for a stored channel id. A
// namespaced id ("<accountID>:<rawID>") resolves to its owning Slack
// account's team id (cached per accountID); an un-namespaced id falls back to
// defaultTeamID (legacy single-account behavior). A lookup failure is logged
// rather than silently swallowed — before this, a broken lookup could render
// a deep link to the wrong workspace with no diagnostic trail.
func resolveSlackLinkTarget(database *db.DB, cache slackAccountCache, defaultTeamID, channelID string) (teamID, rawChannelID string) {
	acctID, rawID, ok := watchtowerslack.SplitAccountID(channelID)
	if !ok {
		return defaultTeamID, channelID
	}
	acct, cached := cache[acctID]
	if !cached {
		var err error
		acct, err = database.GetSlackAccount(acctID)
		if err != nil {
			log.Printf("warning: failed to resolve slack account %d for link target: %v", acctID, err)
			return defaultTeamID, rawID
		}
		cache[acctID] = acct
	}
	if acct.TeamID == "" {
		return defaultTeamID, rawID
	}
	return acct.TeamID, rawID
}
