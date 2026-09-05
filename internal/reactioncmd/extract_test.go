package reactioncmd

import (
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func msgItem(channel, ts, author, text, threadTS string, reactions ...slack.ItemReaction) slack.ReactedItem {
	m := &slack.Message{}
	m.Timestamp = ts
	m.User = author
	m.Text = text
	m.ThreadTimestamp = threadTS
	return slack.ReactedItem{
		Item:      slack.Item{Type: "message", Channel: channel, Message: m},
		Reactions: reactions,
	}
}

func testDict() map[string]db.ReactionCommandMapping {
	return map[string]db.ReactionCommandMapping{
		"white_check_mark": {Emoji: "white_check_mark", Kind: "builtin_tool", Tool: "create_target", Enabled: true},
	}
}

func TestExtractOwnerReactions_MatchesDictionaryAndOwner(t *testing.T) {
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	got := extractOwnerReactions(items, "UOWNER", testDict(), 1)
	assert.Len(t, got, 1)
	assert.Equal(t, "1:C1", got[0].ChannelID)
	assert.Equal(t, "111.1", got[0].MessageTS)
	assert.Equal(t, "white_check_mark", got[0].Emoji)
	assert.Equal(t, "create_target", got[0].Mapping.Tool)
	assert.Equal(t, "handle the deploy", got[0].Text)
}

func TestExtractOwnerReactions_IgnoresUnmappedEmoji(t *testing.T) {
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "thumbsup", Users: []string{"UOWNER"}}),
	}
	assert.Empty(t, extractOwnerReactions(items, "UOWNER", testDict(), 1))
}

func TestExtractOwnerReactions_IgnoresOtherUsersReaction(t *testing.T) {
	// The emoji matches but the owner is NOT among the reactors (a non-empty
	// user list that excludes the owner).
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"USOMEONE"}}),
	}
	assert.Empty(t, extractOwnerReactions(items, "UOWNER", testDict(), 1))
}

func TestExtractOwnerReactions_ExcludesEmptyUsers(t *testing.T) {
	// With Full=true the Users list is authoritative; an empty list is NOT
	// attributed to the owner (a phantom command would be worse than a miss).
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: nil}),
	}
	assert.Empty(t, extractOwnerReactions(items, "UOWNER", testDict(), 1))
}

func TestExtractOwnerReactions_IgnoresNonMessageItems(t *testing.T) {
	items := []slack.ReactedItem{{
		Item:      slack.Item{Type: "file", Channel: "C1"},
		Reactions: []slack.ItemReaction{{Name: "white_check_mark", Users: []string{"UOWNER"}}},
	}}
	assert.Empty(t, extractOwnerReactions(items, "UOWNER", testDict(), 1))
}
