package tracks

import (
	"context"
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/logcanary"
)

// seedCanaryTrackWindow adds a digest of channel C1 whose texts are
// canaries; digestIdx shifts its period so each call adds a distinct digest.
func seedCanaryTrackWindow(t *testing.T, database *db.DB, digestIdx int) {
	t.Helper()
	c := logcanary.Text
	now := time.Now()
	from := float64(now.Add(-2 * time.Hour).Unix())
	to := float64(now.Unix())
	digestID, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: from + float64(digestIdx), PeriodTo: to,
		Summary: c("digest.summary"), MessageCount: 5, Model: "test",
	})
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
		VALUES (?, 0, ?, ?, '[]', ?, '[]', '[]')`, digestID, c("topic.title"), c("topic.summary"),
		`[{"text":"`+c("action.text")+`","assignee":"@alice","status":"open"}]`)
	require.NoError(t, err)
}

// TestFILES01_TracksNeverLogsContent runs the tracks pipeline over canary
// channels, people and digests: a valid answer that creates a track and drops
// a low-value one, a second run that merges into the stored track, and an
// unparseable answer. Returned errors go to the log too.
func TestFILES01_TracksNeverLogsContent(t *testing.T) {
	c := logcanary.Text
	sink := logcanary.Capture(t)
	database := testDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: c("workspace.name")}))
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: c("user.name"), DisplayName: c("user.display_name"), RealName: c("user.real_name")}))
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: c("channel.name"), Type: "public"}))

	item := func(text, ownership, priority, category string) string {
		return fmt.Sprintf(`{"text":%q,"context":%q,"category":%q,"ownership":%q,"priority":%q,`+
			`"requester":{"name":%q,"user_id":"U2"},"sub_items":[{"text":%q}]}`,
			text, c("llm.context"), category, ownership, priority, c("llm.requester"), c("llm.sub_item"))
	}
	valid := `[{"channel_id":"C1","items":[` + item(c("llm.track"), "mine", "high", "task") + `,` +
		item(c("llm.dropped"), "watching", "low", "discussion") + `]}]`
	invalid := c("llm.output") + ` [{"channel_id":`

	for i, out := range []string{valid, valid, invalid} {
		seedCanaryTrackWindow(t, database, i)
		cfg := testConfig()
		cfg.AI.Workers = 1
		pipe := New(database, cfg, &mockGenerator{response: out}, sink.Logger())
		_, _, err := pipe.Run(context.Background())
		log.Printf("tracks run %d: %v", i, err)
	}

	require.Contains(t, sink.String(), "tracks: ", "the pipeline logged nothing; the guard would be vacuous")
	sink.AssertClean(t)
}
