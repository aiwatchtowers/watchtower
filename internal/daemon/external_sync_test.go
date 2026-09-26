package daemon

import (
	"context"
	"errors"
	"log"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/extsync"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeExternalSync is a scripted ExternalSyncRunner.
type fakeExternalSync struct {
	calls int
	stats extsync.Stats
	err   error
	// cancel, when set, is called inside Run before returning err — the
	// shutdown-mid-cycle shape.
	cancel context.CancelFunc
}

func (f *fakeExternalSync) Run(context.Context) (extsync.Stats, error) {
	f.calls++
	if f.cancel != nil {
		f.cancel()
	}
	return f.stats, f.err
}

func newExternalSyncTestDaemon(t *testing.T) (*Daemon, *db.DB, *fakeExternalSync) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)
	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-external-sync] ", 0))
	d.SetDB(database)
	fake := &fakeExternalSync{stats: extsync.Stats{Fetched: 2}}
	d.SetExternalSync(fake)
	return d, database, fake
}

func seedConfluenceSource(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	require.NoError(t, err)
	_, err = database.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
}

func TestPhaseExternalSync_DisabledWritesNothing(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = false
	seedConfluenceSource(t, database)

	d.phaseExternalSync(context.Background())

	assert.Zero(t, fake.calls, "a disabled feature must never call the engine")
	assert.Equal(t, 0, countPipelineRuns(t, database, "external-sync"))
}

func TestPhaseExternalSync_NoSourcesWritesNothing(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true

	d.phaseExternalSync(context.Background())

	assert.Zero(t, fake.calls, "the feature is inert until a space is selected")
	assert.Equal(t, 0, countPipelineRuns(t, database, "external-sync"))
}

func TestPhaseExternalSync_EnabledRunsOnceAndTracks(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	seedConfluenceSource(t, database)

	d.phaseExternalSync(context.Background())

	assert.Equal(t, 1, fake.calls)
	assert.Equal(t, 1, countPipelineRuns(t, database, "external-sync"))
}

func TestPhaseExternalSync_NilRunnerOrDBIsANoOp(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	assert.NotPanics(t, func() { d.phaseExternalSync(context.Background()) })

	d.SetExternalSync(&fakeExternalSync{})
	assert.NotPanics(t, func() { d.phaseExternalSync(context.Background()) })
}

func pipelineStatuses(t *testing.T, database *db.DB, pipeline string) []string {
	t.Helper()
	runs, err := database.GetPipelineRuns(50)
	require.NoError(t, err)
	var out []string
	for _, r := range runs {
		if r.Pipeline == pipeline {
			out = append(out, r.Status)
		}
	}
	return out
}

func TestPhaseExternalSync_ShutdownCancelIsNotAnError(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	seedConfluenceSource(t, database)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fake.cancel = cancel
	fake.err = context.Canceled

	d.phaseExternalSync(ctx)

	statuses := pipelineStatuses(t, database, "external-sync")
	require.NotEmpty(t, statuses)
	for _, s := range statuses {
		assert.NotEqual(t, "error", s, "a shutdown-cancelled cycle must not be recorded as a pipeline error")
	}
}

func TestPhaseExternalSync_RealErrorIsRecorded(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	seedConfluenceSource(t, database)
	fake.err = errors.New("boom")

	d.phaseExternalSync(context.Background())

	assert.Equal(t, []string{"error"}, pipelineStatuses(t, database, "external-sync"))
}
