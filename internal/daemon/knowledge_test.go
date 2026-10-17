package daemon

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newKnowledgeTestDaemon builds a Daemon with a test DB, suitable for
// calling phaseKnowledgeIndex directly (the newCleanupTestDaemon precedent).
func newKnowledgeTestDaemon(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)

	database := db.OpenTestDB(t)

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-knowledge-index] ", 0))
	d.SetDB(database)
	return d, database
}

// seedOneJiraIssue seeds one indexable Jira issue — kb's source_work.go
// requires only the account + issue rows (the internal/kb seedJira
// fixture's shape; kb is off-limits to touch/import from here).
func seedOneJiraIssue(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, description_text, status, status_category, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-1','PROJ','Stage environment','Need a stage','In Progress','indeterminate','2026-04-01T09:00:00.000+0100','2026-04-20T09:37:38.027+0100','2026-04-20T11:00:01Z')`)
	require.NoError(t, err)
}

func countPipelineRuns(t *testing.T, database *db.DB, pipeline string) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM pipeline_runs WHERE pipeline = ?`, pipeline).Scan(&n))
	return n
}

// TestPhaseKnowledgeIndex_EnabledIndexesAndTracks pins the happy path: one
// Jira issue seeded, knowledge.enabled=true, phaseKnowledgeIndex runs kb.Run
// and records a knowledge-index pipeline_runs row.
func TestPhaseKnowledgeIndex_EnabledIndexesAndTracks(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	seedOneJiraIssue(t, database)

	d.phaseKnowledgeIndex(context.Background())

	var jira int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents WHERE source <> 'guide'`).Scan(&jira))
	assert.Equal(t, 1, jira, "the seeded Jira issue must be indexed")
	assert.Equal(t, 1, countPipelineRuns(t, database, "knowledge-index"), "a knowledge-index pipeline_runs row must be written")
}

// TestPhaseKnowledgeIndex_DisabledWritesNothing pins FEAT-01: off means zero
// indexing and zero pipeline_runs rows, not merely an empty/no-op run.
func TestPhaseKnowledgeIndex_DisabledWritesNothing(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = false
	seedOneJiraIssue(t, database)

	d.phaseKnowledgeIndex(context.Background())

	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents WHERE source <> 'guide'`).Scan(&n))
	assert.Equal(t, 0, n, "a disabled feature must never index owner data (the built-in guide excepted)")
	assert.Equal(t, 0, countPipelineRuns(t, database, "knowledge-index"), "a disabled feature must write zero pipeline_runs rows")
}

// TestPhaseKnowledgeIndexGuideRunsWhenKnowledgeOff pins that the built-in
// guide is indexed with the switch off, alone, and survives a later cycle.
func TestPhaseKnowledgeIndexGuideRunsWhenKnowledgeOff(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = false
	seedOneJiraIssue(t, database)

	d.phaseKnowledgeIndex(context.Background())
	d.phaseKnowledgeIndex(context.Background())

	var guide, other int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents WHERE source = 'guide'`).Scan(&guide))
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents WHERE source <> 'guide'`).Scan(&other))
	assert.Positive(t, guide, "the guide must be indexed while knowledge search is off")
	assert.Zero(t, other, "no other source may be indexed while knowledge search is off")
}

// TestPhaseKnowledgeIndex_NilDBIsANoOp mirrors every other phase's
// d.db == nil guard — a daemon constructed without SetDB must never panic.
func TestPhaseKnowledgeIndex_NilDBIsANoOp(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.Knowledge.Enabled = true

	assert.NotPanics(t, func() { d.phaseKnowledgeIndex(context.Background()) })
}

// TestPhaseKnowledgeIndex_CancelledContextIsNotAnError pins the fix: a daemon
// shutdown mid-cycle (kb.Run sees ctx already done and returns a pure
// cancellation error) must never surface as a pipeline_runs status "error" —
// cursors are tx-safe, nothing broke, the next cycle just resumes. The row
// may or may not exist (trackedPipelineRun always creates one, but this pins
// the observable contract, not the mechanism); if it exists its status must
// not be "error".
func TestPhaseKnowledgeIndex_CancelledContextIsNotAnError(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	seedOneJiraIssue(t, database)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	d.phaseKnowledgeIndex(ctx)

	runs, err := database.GetPipelineRuns(50)
	require.NoError(t, err)
	for _, r := range runs {
		if r.Pipeline != "knowledge-index" {
			continue
		}
		assert.NotEqual(t, "error", r.Status, "a shutdown-cancelled cycle must not be recorded as a pipeline error")
	}
}

// TestIsBenignShutdownErr unit-pins the classifier isBenignShutdownErr uses:
// a pure cancellation (however deep the join) is benign; a genuine error —
// alone, or joined alongside a cancellation — is not.
func TestIsBenignShutdownErr(t *testing.T) {
	cancelledCtx, cancel := context.WithCancel(context.Background())
	cancel()
	liveCtx := context.Background()

	genuine := fmt.Errorf("jira: %w", errors.New("boom"))

	cases := []struct {
		name string
		ctx  context.Context
		err  error
		want bool
	}{
		{"nil error", cancelledCtx, nil, false},
		{"ctx not done", liveCtx, context.Canceled, false},
		{"bare cancel, ctx done", cancelledCtx, context.Canceled, true},
		{"bare deadline exceeded, ctx done", cancelledCtx, context.DeadlineExceeded, true},
		{"wrapped cancel, ctx done", cancelledCtx, fmt.Errorf("kb: %w", context.Canceled), true},
		{"joined pure cancel, ctx done", cancelledCtx, errors.Join(context.Canceled), true},
		{"genuine error alone, ctx done", cancelledCtx, genuine, false},
		{"genuine error joined with cancel, ctx done", cancelledCtx, errors.Join(genuine, context.Canceled), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, isBenignShutdownErr(tc.ctx, tc.err))
		})
	}
}
