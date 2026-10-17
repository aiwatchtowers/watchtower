package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/cobra"

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

func useReviewGen(t *testing.T, g *fakeReviewGen) { t.Helper(); useReviewGenerator(t, g) }

func useReviewGenerator(t *testing.T, g digest.Generator) {
	t.Helper()
	old := reviewAIGeneratorFactory
	reviewAIGeneratorFactory = func(*config.Config) digest.Generator { return g }
	t.Cleanup(func() { reviewAIGeneratorFactory = old })
}

const overviewReply = `{"summary":"Edits the readme.","coverage":[],"out_of_scope":[],"risk":[{"path":"README.md","level":"low","why":"docs"}],"chapters":[{"title":"Readme","paths":["README.md"],"core":true,"lenses":["correctness"]}]}`

// overviewRound: a changed README and an open round on the fixture session.
func overviewRound(t *testing.T) (database *db.DB, wb, session int64, round string) {
	t.Helper()
	database, wb, session, round, _ = overviewRoundIn(t)
	return database, wb, session, round
}

func overviewRoundIn(t *testing.T) (database *db.DB, wb, session int64, round, repo string) {
	t.Helper()
	database, wb, session, repo = reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	r := reviewJSON(t, wb, "start", "--session", itoa(session))["round"].(map[string]any)
	return database, wb, session, itoa(int64(r["id"].(float64))), repo
}

func roundTree(t *testing.T, database *db.DB, round string) string {
	t.Helper()
	var tree string
	require.NoError(t, database.QueryRow(`SELECT tree_sha FROM review_rounds WHERE id = ?`, round).Scan(&tree))
	return tree
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

// blockingReviewGen blocks until its context ends, as the claude/codex child
// does until the generator kills it.
type blockingReviewGen struct {
	started chan struct{}
	done    chan struct{}
}

func newBlockingReviewGen() *blockingReviewGen {
	return &blockingReviewGen{started: make(chan struct{}), done: make(chan struct{})}
}

func (g *blockingReviewGen) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	close(g.started)
	<-ctx.Done()
	close(g.done)
	return "", nil, "", ctx.Err()
}

// runReviewWithContext runs one review subcommand under parent. Cobra only
// hands a context down to a command whose own is unset, so leaf's is cleared
// before and after.
func runReviewWithContext(t *testing.T, parent context.Context, leaf *cobra.Command, args ...string) (string, error) {
	t.Helper()
	leaf.SetContext(nil) //nolint:staticcheck // nil lets cobra pass parent down
	t.Cleanup(func() {
		leaf.SetContext(nil)    //nolint:staticcheck // the next Execute hands its own down
		rootCmd.SetContext(nil) //nolint:staticcheck // ditto
	})
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(io.Discard)
	rootCmd.SetArgs(append([]string{"workbench", "review"}, args...))
	err := rootCmd.ExecuteContext(parent)
	rootCmd.SetArgs(nil)
	resetSetFlags(append(workbenchReviewCmd.Commands(), workbenchReviewLessonsCmd.Commands()...)...)
	resetSetFlags(append(workbenchCmd.Commands(), workbenchCmd, rootCmd)...)
	return out.String(), err
}

// cancelWhileGenerating runs the command, cancels once the model call is in
// flight, and checks the call saw ctx.Done() and the command returned.
func cancelWhileGenerating(t *testing.T, g *blockingReviewGen, cancelIt func(), run func() (string, error)) map[string]any {
	t.Helper()
	type result struct {
		out string
		err error
	}
	res := make(chan result, 1)
	go func() {
		out, err := run()
		res <- result{out, err}
	}()
	select {
	case <-g.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the model call never started")
	}
	cancelIt()
	select {
	case <-g.done:
	case <-time.After(10 * time.Second):
		t.Fatal("the model call never saw its context end")
	}
	var r result
	select {
	case r = <-res:
	case <-time.After(10 * time.Second):
		t.Fatal("the command did not return after the cancel")
	}
	require.NoError(t, r.err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(r.out), &m), r.out)
	return m
}

func TestWorkbenchReviewOverview_CancelEndsTheModelCall(t *testing.T) {
	t.Run("parent cancelled", func(t *testing.T) {
		database, wb, _, round := overviewRound(t)
		g := newBlockingReviewGen()
		useReviewGenerator(t, g)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		out := cancelWhileGenerating(t, g, cancel, func() (string, error) {
			return runReviewWithContext(t, ctx, workbenchReviewOverviewCmd, "overview", "--workbench", itoa(wb), "--round", round, "--json")
		})
		assert.Equal(t, false, out["ok"])
		var n int
		require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
		assert.Zero(t, n)
	})
	t.Run("interrupt signal", func(t *testing.T) {
		_, wb, _, round := overviewRound(t)
		g := newBlockingReviewGen()
		useReviewGenerator(t, g)
		out := cancelWhileGenerating(t, g, func() {
			require.NoError(t, syscall.Kill(os.Getpid(), syscall.SIGINT)) // caught: the command registered for it
		}, func() (string, error) {
			return runReviewWithContext(t, context.Background(), workbenchReviewOverviewCmd, "overview", "--workbench", itoa(wb), "--round", round, "--json")
		})
		assert.Equal(t, false, out["ok"])
	})
}

func TestWorkbenchReviewOverview_ContextReadFailureIsAnError(t *testing.T) {
	database, wb, s, round := overviewRound(t)
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Goal")
	_, err := database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	// A value the target scan cannot read: GetTargetByID fails.
	_, err = database.Exec(`UPDATE targets SET next_step_attempts = 'many' WHERE id = ?`, tid)
	require.NoError(t, err)
	g := &fakeReviewGen{out: overviewReply}
	useReviewGen(t, g)

	ctxOut := reviewJSON(t, wb, "context", "--session", itoa(s))
	assert.Equal(t, false, ctxOut["ok"])
	assert.Contains(t, ctxOut["error"], "reading linked target")
	ov := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, false, ov["ok"])
	assert.Contains(t, ov["error"], "reading linked target")
	assert.Zero(t, g.calls)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
	assert.Zero(t, n)
}

func TestWorkbenchReviewOverview_CacheHitReadsNoDiff(t *testing.T) {
	database, wb, s, round, repo := overviewRoundIn(t)
	g := &fakeReviewGen{out: overviewReply}
	useReviewGen(t, g)
	first := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, first["ok"], first)
	tree := roundTree(t, database, round)
	// The tree object is gone: a diff now fails, a cache hit does not care.
	obj := filepath.Join(repo, ".git", "objects", tree[:2], tree[2:])
	require.NoError(t, os.Rename(obj, obj+".moved"))
	second := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, true, second["ok"], second)
	assert.Equal(t, true, second["overview_cached"])
	assert.Equal(t, 1, g.calls)
	require.NoError(t, os.Rename(obj+".moved", obj))

	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed again\n"), 0o644))
	reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")
	require.NotEqual(t, tree, roundTree(t, database, round))
	third := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, true, third["ok"], third)
	assert.NotEqual(t, true, third["overview_cached"])
	assert.Equal(t, 2, g.calls)
}

func TestWorkbenchReviewOverview_CacheWriteFailureKeepsTheOverview(t *testing.T) {
	database, wb, _, round := overviewRound(t)
	_, err := database.Exec(`CREATE TRIGGER fail_overview_cache BEFORE INSERT ON review_overviews BEGIN SELECT RAISE(ABORT, 'disk full'); END`)
	require.NoError(t, err)
	g := &fakeReviewGen{out: overviewReply}
	useReviewGen(t, g)
	out := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, out["ok"], out)
	assert.Equal(t, "Edits the readme.", out["overview"].(map[string]any)["summary"])
	assert.NotEqual(t, true, out["overview_cached"])
}

// Board #585: Quick mode asks with --cached-only — a miss answers ok with no
// overview and never calls the model; a cached overview comes back as usual.
func TestWorkbenchReviewOverview_CachedOnlyNeverCallsTheModel(t *testing.T) {
	database, wb, _, round := overviewRound(t)
	g := &fakeReviewGen{out: overviewReply}
	useReviewGen(t, g)
	miss := reviewJSON(t, wb, "overview", "--round", round, "--cached-only")
	assert.Equal(t, true, miss["ok"], miss)
	assert.Nil(t, miss["overview"])
	assert.Zero(t, g.calls)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
	assert.Zero(t, n)

	require.Equal(t, true, reviewJSON(t, wb, "overview", "--round", round)["ok"])
	hit := reviewJSON(t, wb, "overview", "--round", round, "--cached-only")
	assert.Equal(t, true, hit["overview_cached"], hit)
	assert.Equal(t, "Edits the readme.", hit["overview"].(map[string]any)["summary"])
	assert.Equal(t, 1, g.calls)
}
