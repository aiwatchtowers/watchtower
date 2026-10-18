package ideas

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// One workspace's failure is logged and returned, and never stops the next
// workspace's pass (the runJiraDigests shape): the failing floor stays, the
// healthy one advances.
func TestRunLinearDigests_ContinuesAfterAnAccountFailure(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	bad, good := db.SeedLinearTestAccount(t, d), db.SeedLinearTestAccount(t, d)
	for _, acct := range []int64{bad, good} {
		require.NoError(t, d.SetIdeasLinearFloor(acct, lt(base)))
	}
	u := lt(base.Add(time.Second))
	seedLinearIssueIdeas(t, d, bad, "b1", "BAD-1", "BAD", "t", "Todo", "d", u)
	seedLinearIssueIdeas(t, d, good, "g1", "GOOD-1", "GOOD", "t", "Todo", "d", u)

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "BAD-1") {
			return "", fmt.Errorf("boom")
		}
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"A","ref":"GOOD-1"}],"decisions":[]}]}`, nil
	}}
	err := New(d, testCfg(), gen, testLogger()).runLinearDigests(context.Background())
	require.Error(t, err, "the first account error is returned")
	assert.Equal(t, 2, gen.calls, "the second workspace still ran")

	badFloor, err := d.IdeasLinearFloor(bad)
	require.NoError(t, err)
	assert.Equal(t, lt(base), badFloor)
	goodFloor, err := d.IdeasLinearFloor(good)
	require.NoError(t, err)
	assert.Equal(t, u, goodFloor)
}

// A team failing for longer than the cap no longer holds the floor (logged),
// so a permanently broken team cannot stall Linear mining forever.
func TestIdeas01_LinearAbandonedTeamNoLongerHoldsTheFloor(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC()
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "tb", Key: "BBB"}}, map[string]bool{"tb": true}))
	require.NoError(t, d.SetIdeasLinearFloor(acct, lt(now.Add(-3*time.Hour))))
	require.NoError(t, d.RecordLinearSyncSuccess(acct, "tb", "", lt(now.Add(-jiraLaggingProjectMaxAge-time.Hour))))
	require.NoError(t, d.RecordLinearSyncError(acct, "tb", "boom"))
	seedLinearIssueIdeas(t, d, acct, "a1", "AAA-1", "AAA", "fresh", "Todo", "x", lt(now.Add(-10*time.Minute)))

	var buf bytes.Buffer
	p := New(d, testCfg(), &fakeGen{reply: jiraTopicsFor("AAA-1")}, log.New(&buf, "", 0))
	require.NoError(t, p.runLinearDigests(context.Background()))
	floor, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, lt(now.Add(-10*time.Minute)), floor, "an abandoned team does not clamp")
	assert.Contains(t, buf.String(), "a selected team has failed to sync since")
}
