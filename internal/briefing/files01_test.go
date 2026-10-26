package briefing

import (
	"context"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/logcanary"
)

// TestFILES01_BriefingNeverLogsContent generates a briefing over an owner,
// a channel, a digest, a target and a track made of canaries, once with a
// valid answer quoting canaries and once with unparseable output; returned
// errors are logged the way a caller would.
func TestFILES01_BriefingNeverLogsContent(t *testing.T) {
	c := logcanary.Text
	valid := `{"attention":[{"text":"` + c("llm.attention") + `","source_type":"digest","source_id":"1","priority":"high"}],` +
		`"your_day":[{"text":"` + c("llm.your_day") + `","track_id":0,"priority":"medium"}],` +
		`"what_happened":[{"text":"` + c("llm.what_happened") + `","digest_id":1,"channel_name":"` + c("llm.channel") + `"}]}`
	invalid := c("llm.output") + ` {"attention":`

	for _, out := range []string{valid, invalid} {
		sink := logcanary.Capture(t)
		database := testDB(t)
		require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: c("workspace.name"), Domain: c("workspace.domain")}))
		_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
		require.NoError(t, err)
		require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: c("user.name"), DisplayName: c("user.display_name"), RealName: c("user.real_name")}))
		require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: c("channel.name"), Type: "public"}))
		now := time.Now()
		dayStart := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 0, 0, 0, now.Location())
		_, err = database.UpsertDigest(db.Digest{
			ChannelID: "C1", Type: "channel", PeriodFrom: float64(dayStart.Unix()), PeriodTo: float64(now.Unix()),
			Summary: c("digest.summary"), Topics: `["` + c("digest.topic") + `"]`,
			Decisions: `[{"text":"` + c("digest.decision") + `"}]`, ActionItems: `[]`, MessageCount: 5,
		})
		require.NoError(t, err)
		_, err = database.CreateTarget(db.Target{Text: c("target.text"), Level: "day", Status: "todo",
			Priority: "high", Ownership: "mine", SourceType: "manual"})
		require.NoError(t, err)
		_, err = database.UpsertTrack(db.Track{AssigneeUserID: "U001", Text: c("track.text"), Context: c("track.context"),
			Category: "task", Ownership: "mine", Priority: "high", ChannelIDs: `["C1"]`})
		require.NoError(t, err)

		pipe := New(database, testConfig(), &mockGenerator{response: out}, sink.Logger())
		_, err = pipe.RunForDate(context.Background(), now.Format("2006-01-02"))
		log.Printf("run: %v", err)

		require.Contains(t, sink.String(), "briefing: ", "the pipeline logged nothing; the guard would be vacuous")
		sink.AssertClean(t)
	}
}
