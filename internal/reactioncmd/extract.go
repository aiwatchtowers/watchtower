// Package reactioncmd turns the owner's Slack reactions into Watchtower
// agent-actions: a reaction whose emoji is in the dictionary
// (reaction_command_map) becomes a command that gathers the reacted message's
// context and dispatches a tool through the agent-actions registry.
//
// Detection reads reactions.list under the owner's own token, so it sees the
// owner's reactions regardless of message age and needs no "is this the owner?"
// filter. Idempotency and "no undo" live in the reaction_commands ledger.
// Spec: docs/superpowers/specs/2026-09-05-reaction-commands-design.md.
package reactioncmd

import (
	watchtowerslack "watchtower/internal/slack"

	"github.com/slack-go/slack"

	"watchtower/internal/db"
)

// candidate is one owner reaction that matched the dictionary, carrying the
// context reactions.list already returned (message text + thread) so dispatch
// needs no extra fetch for the common case.
type candidate struct {
	AccountID int64
	ChannelID string // namespaced accountID:rawID
	MessageTS string
	Emoji     string
	Mapping   db.ReactionCommandMapping
	AuthorID  string // raw Slack user id of the message author
	Text      string
	ThreadTS  string
}

// extractOwnerReactions filters a reactions.list result to the owner's own
// reactions whose emoji is in the dictionary. It is pure — the poll's Slack
// call is elsewhere — so the dictionary matching is unit-testable without Slack.
// Only message items are considered (file/comment reactions are ignored). The
// returned channel id is namespaced for DB storage; author id stays raw.
func extractOwnerReactions(items []slack.ReactedItem, ownerRawID string, dict map[string]db.ReactionCommandMapping, accountID int64) []candidate {
	var out []candidate
	for _, it := range items {
		if it.Type != "message" || it.Message == nil {
			continue
		}
		ts := it.Message.Timestamp
		if ts == "" {
			ts = it.Timestamp
		}
		if ts == "" || it.Channel == "" {
			continue
		}
		for _, r := range it.Reactions {
			m, ok := dict[r.Name]
			if !ok || !reactorIsOwner(r.Users, ownerRawID) {
				continue
			}
			out = append(out, candidate{
				AccountID: accountID,
				ChannelID: watchtowerslack.Namespace(accountID, it.Channel),
				MessageTS: ts,
				Emoji:     r.Name,
				Mapping:   m,
				AuthorID:  it.Message.User,
				Text:      it.Message.Text,
				ThreadTS:  it.Message.ThreadTimestamp,
			})
		}
	}
	return out
}

// reactorIsOwner reports whether the owner is among a reaction's users.
// ListUserReactions sets Full=true, so the users array is authoritative. An
// item is returned because the owner reacted to it with SOME emoji, but its
// Reactions array carries every emoji on the message — including ones other
// people placed. So an emoji whose Users list does not contain the owner is
// NOT the owner's, even on a message the owner reacted to; an empty/unknown
// list is excluded rather than attributed to the owner, since this predicate
// gates a write and a phantom command is worse than a missed one.
func reactorIsOwner(users []string, ownerRawID string) bool {
	for _, u := range users {
		if u == ownerRawID {
			return true
		}
	}
	return false
}
