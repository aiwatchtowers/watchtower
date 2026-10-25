package guide

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

// TestFILES01_PeopleNeverLogsContent generates people cards over users,
// channels, messages and situations made of canaries, once with a valid
// answer quoting canaries and once with unparseable output; returned errors
// are logged the way a caller would.
func TestFILES01_PeopleNeverLogsContent(t *testing.T) {
	c := logcanary.Text
	valid := `{"summary":"` + c("llm.summary") + `","communication_style":"driver","highlights":["` + c("llm.highlight") + `"],` +
		`"cards":[{"user_id":"U1","summary":"` + c("llm.card") + `"}],"team_summary":"` + c("llm.team") + `"}`
	invalid := c("llm.output") + ` {"summary":`

	for _, out := range []string{valid, invalid} {
		sink := logcanary.Capture(t)
		database := testDB(t)
		require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "W1", Name: c("workspace.name")}))
		require.NoError(t, database.UpsertUser(db.User{ID: "U1", Name: c("user.name"), DisplayName: c("user.display_name"), RealName: c("user.real_name")}))
		seedChannel(t, database, "C1", c("channel.name"))
		from := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
		to := float64(time.Date(2025, 1, 8, 0, 0, 0, 0, time.UTC).Unix())
		for i := range 5 {
			seedMessage(t, database, "C1", fmt.Sprintf("%.6f", from+86400+float64(i*60)), "U1", c("message.text"))
		}
		situation := `{"topic":"` + c("situation.topic") + `","type":"collaboration","participants":[{"user_id":"U1","role":"lead"}],` +
			`"dynamic":"` + c("situation.dynamic") + `","outcome":"` + c("situation.outcome") + `","red_flags":[],"observations":[],"message_refs":[]}`
		seedDigestWithSituations(t, database, "C1", from, to, `[]`, `[`+situation+`,`+situation+`,`+situation+`]`)

		cfg := testConfig()
		cfg.AI.Workers = 1
		pipe := New(database, cfg, &mockGenerator{response: out}, sink.Logger())
		pipe.ForceRegenerate = true
		_, err := pipe.RunForWindow(context.Background(), from, to)
		log.Printf("run: %v", err)

		require.Contains(t, sink.String(), "people: ", "the pipeline logged nothing; the guard would be vacuous")
		sink.AssertClean(t)
	}
}
