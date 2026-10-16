package cmd

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

type fakeReviewGen struct {
	calls int
	out   string
	err   error
	users []string
}

func (g *fakeReviewGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	g.users = append(g.users, user)
	return g.out, &digest.Usage{}, "", g.err
}

func useReviewGen(t *testing.T, g *fakeReviewGen) {
	t.Helper()
	old := reviewAIGeneratorFactory
	reviewAIGeneratorFactory = func(*config.Config) digest.Generator { return g }
	t.Cleanup(func() { reviewAIGeneratorFactory = old })
}

const overviewReply = `{"summary":"Edits the readme.","coverage":[],"out_of_scope":[],"risk":[{"path":"README.md","level":"low","why":"docs"}],"chapters":[{"title":"Readme","paths":["README.md"],"core":true,"lenses":["correctness"]}]}`

// overviewRound: a changed README and an open round on the fixture session.
func overviewRound(t *testing.T) (database *db.DB, wb, session int64, round string) {
	t.Helper()
	database, wb, session, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	r := reviewJSON(t, wb, "start", "--session", itoa(session))["round"].(map[string]any)
	return database, wb, session, itoa(int64(r["id"].(float64)))
}

func TestWorkbenchReviewOverview_CachesPerTreeBaseIntent(t *testing.T) {
	database, wb, s, round := overviewRound(t)
	g := &fakeReviewGen{out: overviewReply}
	useReviewGen(t, g)
	first := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, first["ok"], first)
	assert.Equal(t, "Edits the readme.", first["overview"].(map[string]any)["summary"])
	assert.NotEqual(t, true, first["overview_cached"])
	second := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, true, second["overview_cached"])
	assert.Equal(t, 1, g.calls)

	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "A new goal")
	_, err := database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	third := reviewJSON(t, wb, "overview", "--round", round)
	assert.NotEqual(t, true, third["overview_cached"])
	assert.Equal(t, 2, g.calls)
	assert.Contains(t, g.users[1], "A new goal")
}

func TestWorkbenchReviewOverview_FailureIsAnEnvelopeAndNotCached(t *testing.T) {
	database, wb, _, round := overviewRound(t)
	g := &fakeReviewGen{err: errors.New("boom")}
	useReviewGen(t, g)
	out := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, "AI overview unavailable: boom", out["error"])
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
	assert.Zero(t, n)
	g.err, g.out = nil, overviewReply
	assert.Equal(t, true, reviewJSON(t, wb, "overview", "--round", round)["ok"])
	assert.Equal(t, 2, g.calls)
}

func TestWorkbenchReviewOverview_InvalidReplyNotCached(t *testing.T) {
	database, wb, _, round := overviewRound(t)
	g := &fakeReviewGen{out: `{"summary":""}`}
	useReviewGen(t, g)
	out := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, false, out["ok"])
	assert.Contains(t, out["error"], "AI overview unavailable:")
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
	assert.Zero(t, n)
}
