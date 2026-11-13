package db

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// addressedFixture is internal/inbox/testdata/addressed_to_owner.json.
type addressedFixture struct {
	AccountID int64  `json:"account_id"`
	Owner     string `json:"owner"`
	Users     []struct {
		ID, Name    string
		DisplayName string `json:"display_name"`
	} `json:"users"`
	Channels []struct {
		ID, Name, Type string
		DMUserID       string `json:"dm_user_id"`
	} `json:"channels"`
	Messages []struct {
		ID, Channel, User, Text string
		MinutesAgo              int    `json:"minutes_ago"`
		ThreadOf                string `json:"thread_of"`
		Reactions               []struct{ User, Emoji string }
	} `json:"messages"`
	ExpectedToOwner []string `json:"expected_to_owner"`
}

// seedAddressedFixture loads the shared fixture into d and returns it with a
// "<channel>|<ts>" → fixture id map.
func seedAddressedFixture(t *testing.T, d *DB, now time.Time) (addressedFixture, map[string]string) {
	t.Helper()
	raw, err := os.ReadFile("../inbox/testdata/addressed_to_owner.json")
	require.NoError(t, err)
	var fx addressedFixture
	require.NoError(t, json.Unmarshal(raw, &fx))

	acct, err := d.CreateSlackAccount(SlackAccount{TeamID: "T1", TeamName: "acme", TeamDomain: "acme", CurrentUserID: fx.Owner})
	require.NoError(t, err)
	require.Equal(t, fx.AccountID, acct)
	for _, u := range fx.Users {
		_, err := d.Exec(`INSERT INTO users (id, name, display_name) VALUES (?, ?, ?)`, u.ID, u.Name, u.DisplayName)
		require.NoError(t, err)
	}
	for _, c := range fx.Channels {
		_, err := d.Exec(`INSERT INTO channels (id, name, type, is_member, dm_user_id) VALUES (?, ?, ?, 1, NULLIF(?, ''))`,
			c.ID, c.Name, c.Type, c.DMUserID)
		require.NoError(t, err)
	}
	tsOf := map[string]string{}
	byKey := map[string]string{}
	for i, m := range fx.Messages {
		ts := fmt.Sprintf("%d.%06d", now.Add(-time.Duration(m.MinutesAgo)*time.Minute).Unix(), i+1)
		tsOf[m.ID] = ts
		thread := ""
		if m.ThreadOf != "" {
			thread = tsOf[m.ThreadOf]
			require.NotEmpty(t, thread, "thread_of %q must name an earlier message", m.ThreadOf)
			_, err := d.Exec(`UPDATE messages SET thread_ts = ts WHERE channel_id = ? AND ts = ?`, m.Channel, thread)
			require.NoError(t, err)
		}
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES (?, ?, ?, ?, ?)`,
			m.Channel, ts, m.User, m.Text, thread)
		require.NoError(t, err)
		for _, r := range m.Reactions {
			_, err := d.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES (?, ?, ?, ?)`,
				m.Channel, ts, r.User, r.Emoji)
			require.NoError(t, err)
		}
		byKey[m.Channel+"|"+ts] = m.ID
	}
	return fx, byKey
}

// detectorAddressedIDs runs the four detector queries over the fixture.
func detectorAddressedIDs(t *testing.T, d *DB, fx addressedFixture, byKey map[string]string) []string {
	t.Helper()
	seen := map[string]bool{}
	for _, find := range []func(int64, string, float64) ([]InboxCandidate, error){
		d.FindPendingMentions, d.FindThreadRepliesToUser, d.FindReactionRequests, d.FindPendingDMs,
	} {
		cands, err := find(fx.AccountID, fx.Owner, 0)
		require.NoError(t, err)
		for _, c := range cands {
			id, ok := byKey[c.ChannelID+"|"+c.MessageTS]
			require.True(t, ok, "detector returned an unknown message %s %s", c.ChannelID, c.MessageTS)
			seen[id] = true
		}
	}
	out := make([]string, 0, len(seen))
	for id := range seen {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func TestSlackWindow_ToOwnerMatchesDetectorFixture(t *testing.T) {
	d := openTestDB(t)
	now := time.Now()
	fx, byKey := seedAddressedFixture(t, d, now)

	w, err := d.ReadSlackWindow(context.Background(), SlackWindowQuery{Scope: WindowScopeMemberChannels, Now: now})
	require.NoError(t, err)
	require.Len(t, w.Messages, len(fx.Messages), "every fixture line is in the window")
	var window []string
	for _, m := range w.Messages {
		if m.ToOwner {
			window = append(window, byKey[m.ChannelID+"|"+m.TS])
		}
	}
	sort.Strings(window)

	expected := append([]string(nil), fx.ExpectedToOwner...)
	sort.Strings(expected)
	assert.Equal(t, expected, detectorAddressedIDs(t, d, fx, byKey), "the detector matches the fixture")
	assert.Equal(t, expected, window, "the window's ToOwner matches the fixture and the detector")
}

// TestOwnerAddressed_DetectorQueriesUnchanged pins what the three detector
// queries return over the fixture now that their WHERE comes from
// owner_addressed.go: each finds exactly its own trigger's lines, with the
// trigger type and (for a reaction request) the reactor as sender. The
// package's older per-detector tests (TestFindPendingMentions*,
// TestFindThreadRepliesToUser*, TestFindReactionRequests*) run unchanged.
func TestOwnerAddressed_DetectorQueriesUnchanged(t *testing.T) {
	d := openTestDB(t)
	fx, byKey := seedAddressedFixture(t, d, time.Now())

	ids := func(cands []InboxCandidate, trigger string) []string {
		var out []string
		for _, c := range cands {
			assert.Equal(t, trigger, c.TriggerType)
			out = append(out, byKey[c.ChannelID+"|"+c.MessageTS])
		}
		sort.Strings(out)
		return out
	}

	mentions, err := d.FindPendingMentions(fx.AccountID, fx.Owner, 0)
	require.NoError(t, err)
	assert.Equal(t, []string{"group_dm_mention", "mention_pipe", "mention_strict"}, ids(mentions, "mention"))

	replies, err := d.FindThreadRepliesToUser(fx.AccountID, fx.Owner, 0)
	require.NoError(t, err)
	assert.Equal(t, []string{"reply_in_owner_thread"}, ids(replies, "thread_reply"))

	reactions, err := d.FindReactionRequests(fx.AccountID, fx.Owner, 0)
	require.NoError(t, err)
	assert.Equal(t, []string{"owner_eyes_from_other"}, ids(reactions, "reaction"))
	require.Len(t, reactions, 1)
	assert.Equal(t, "1:U0ALICE", reactions[0].SenderUserID, "the reactor is the sender")

	// Newest first, as before.
	require.Len(t, mentions, 3)
	assert.Equal(t, "group_dm_mention", byKey[mentions[0].ChannelID+"|"+mentions[0].MessageTS])

	// Another account's identity sees nothing of account 1.
	none, err := d.FindReactionRequests(2, fx.Owner, 0)
	require.NoError(t, err)
	assert.Empty(t, none)
}

// TestOwnerAddressed_ReactorIsLowestOtherUser keeps the reaction detector's
// reactor choice: the lowest user id among others' attention reactions,
// never the owner's own and never a non-attention emoji.
func TestOwnerAddressed_ReactorIsLowestOtherUser(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'acme-infra', 'public')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', 'U_ME', 'proposal')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES
		('1:C1', '1000.001', 'U_A', 'thumbsup'),
		('1:C1', '1000.001', 'U_C', 'eyes'),
		('1:C1', '1000.001', 'U_B', 'question'),
		('1:C1', '1000.001', 'U_B', 'warning'),
		('1:C1', '1000.001', 'U_ME', 'sos')`)
	require.NoError(t, err)

	cands, err := d.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	require.Len(t, cands, 1)
	assert.Equal(t, "U_B", cands[0].SenderUserID)
}
