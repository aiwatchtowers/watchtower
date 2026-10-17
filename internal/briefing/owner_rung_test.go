package briefing

import (
	"context"
	"io"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A briefing written while the owner came from the mailbox rung is today's
// briefing after the owner moves to Jira: the run adopts it instead of
// generating a second one (OWNER-01, board #576).
func TestRunForDate_RungSwitchDoesNotRegenerate(t *testing.T) {
	database := testDB(t)
	today := time.Now().Format("2006-01-02")
	_, err := database.UpsertBriefing(db.Briefing{UserID: "email:x@example.com", Date: today, Role: "EM"})
	require.NoError(t, err)

	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountOwner(id, "acc-9", "", ""))

	gen := &mockGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(database, testConfig(), gen, log.New(io.Discard, "", 0))
	_, err = pipe.RunForDate(context.Background(), today)
	require.NoError(t, err)

	assert.Zero(t, gen.calls, "no second generation")
	b, err := database.GetBriefing("jira:acc-9", today)
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, "EM", b.Role)
}
