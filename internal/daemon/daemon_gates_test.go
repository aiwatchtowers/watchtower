package daemon

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/feed"
	"watchtower/internal/guide"
	"watchtower/internal/ideas"
	"watchtower/internal/inbox"
	"watchtower/internal/memory"
	"watchtower/internal/targets"
	"watchtower/internal/tracks"
)

// assertNoPipelineRuns is the default gateCase.check: the observable FEAT-01
// promises for a disabled feature — zero pipeline_runs rows, not merely a
// row with items=0. Several pipelines (inbox, digest) already no-op
// internally on their own cfg.X.Enabled check, but trackedPipelineRun still
// INSERTs a "running" row before ever calling into the pipeline — so an
// internal pipeline-level check alone can't satisfy "zero rows"; the gate
// must sit in the daemon phase, before trackedPipelineRun.
func assertNoPipelineRuns(t *testing.T, _ *config.Config, database *db.DB) {
	t.Helper()
	runs, err := database.GetPipelineRuns(50)
	require.NoError(t, err)
	assert.Empty(t, runs, "disabled feature must write zero pipeline_runs rows")
}

// gateCase is one row of TestFeatureGates_DisabledPhaseWritesNoPipelineRun:
// wire a real (cheap-to-construct) pipeline with its own feature flag OFF,
// invoke the daemon phase method(s) that flag is supposed to gate, then
// assert the phase produced no observable side effect.
type gateCase struct {
	name string
	// wire turns the flag off on cfg and attaches a pipeline built via its
	// own package's New (never nil — a nil pipe would let the pre-existing
	// nil-check no-op the phase, which proves nothing about the NEW gate).
	wire func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger)
	run  func(d *Daemon)
	// check defaults to assertNoPipelineRuns; a couple of phases need a
	// different observable (ideas/stream_digests additionally must never
	// touch the backfill lock file). Feed is Core (see
	// TestDaemon_PhaseFeed_IgnoresConfigKillSwitch below) and is not one of
	// these cases — it has no gate to prove absent.
	check func(t *testing.T, cfg *config.Config, database *db.DB)
}

func TestFeatureGates_DisabledPhaseWritesNoPipelineRun(t *testing.T) {
	cases := []gateCase{
		{
			name: "digests",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Digest.Enabled = false
				d.SetDigestPipeline(digest.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phaseChannelDigests(context.Background()) },
		},
		{
			name: "inbox",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Inbox.Enabled = false
				d.SetInboxPipeline(inbox.New(database, cfg, gen, l))
			},
			// Both inbox phases share the same gate key — exercise both.
			run: func(d *Daemon) {
				d.phaseFastInbox(context.Background())
				d.phaseInbox(context.Background())
			},
		},
		{
			name: "tracks",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Tracks.Enabled = false
				d.SetTracksPipeline(tracks.New(database, cfg, gen, l))
				d.SetCustomTracksPipeline(customtracks.New(database, gen, cfg.Digest.Language, l))
			},
			// Custom tracks shares the tracks gate key (both scan/extract
			// narrative tracks) — exercise both phase methods.
			run: func(d *Daemon) {
				d.phaseTracksAndRollups(context.Background())
				d.phaseCustomTrackScan(context.Background())
			},
		},
		{
			// Tracks mine digests (tracks.Pipeline.Run reads the digests
			// table; customtracks' scan activity includes digest-derived
			// events) — tracks.enabled alone is not enough. Before the
			// compound gate, this combination let the phase gate pass,
			// trackedPipelineRun insert a row, and the pipeline return
			// immediately: an empty row leaking every cycle instead of a
			// clean skip.
			name: "tracks_starved_without_digest",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Tracks.Enabled = true
				cfg.Digest.Enabled = false
				d.SetTracksPipeline(tracks.New(database, cfg, gen, l))
				d.SetCustomTracksPipeline(customtracks.New(database, gen, cfg.Digest.Language, l))
			},
			run: func(d *Daemon) {
				d.phaseTracksAndRollups(context.Background())
				d.phaseCustomTrackScan(context.Background())
			},
		},
		{
			name: "people",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.People.Enabled = false
				d.SetPeoplePipeline(guide.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phasePeopleCards(context.Background()) },
		},
		{
			// People cards mine people_signals produced only by
			// phaseChannelDigests — people.enabled alone is not enough. Same
			// empty-row-leak class as tracks above.
			name: "people_starved_without_digest",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.People.Enabled = true
				cfg.Digest.Enabled = false
				d.SetPeoplePipeline(guide.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phasePeopleCards(context.Background()) },
		},
		{
			name: "ideas",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Ideas.Enabled = false
				d.SetIdeasPipeline(ideas.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phaseIdeas(context.Background()) },
			check: func(t *testing.T, cfg *config.Config, database *db.DB) {
				assertNoPipelineRuns(t, cfg, database)
				// The load-bearing assertion (the quirk this task closes):
				// with wireIdeasPipeline now unconditional, ideasPipe is
				// non-nil even when ideas.enabled=false, so without this
				// gate phaseIdeas would fall through past the nil-check
				// straight into AcquireBackfillLock.
				_, err := os.Stat(filepath.Join(cfg.WorkspaceDir(), "ideas_backfill.lock"))
				assert.True(t, os.IsNotExist(err), "ideas.enabled=false must never acquire the backfill lock")
			},
		},
		{
			// Stream digests share the ideas consolidator's backfill lock,
			// so the same "no lock file" assertion applies — and the pipe is
			// wired whenever streams.enabled OR ideas.enabled, so a non-nil
			// pipe with the flag off is the real configuration.
			name: "stream_digests",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Streams.Enabled = false
				d.SetIdeasPipeline(ideas.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phaseStreamDigests(context.Background()) },
			check: func(t *testing.T, cfg *config.Config, database *db.DB) {
				assertNoPipelineRuns(t, cfg, database)
				_, err := os.Stat(filepath.Join(cfg.WorkspaceDir(), "ideas_backfill.lock"))
				assert.True(t, os.IsNotExist(err), "streams.enabled=false must never acquire the backfill lock")
			},
		},
		{
			name: "memory",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Memory.Enabled = false
				vault, err := memory.OpenVault(filepath.Join(cfg.WorkspaceDir(), "memory"))
				require.NoError(t, err)
				pipe := memory.NewPipeline(database, vault, gen, cfg.Memory, l.Printf)
				pipe.Source = "daemon"
				d.SetMemoryPipeline(pipe)
			},
			run: func(d *Daemon) { d.phaseMemory(context.Background()) },
		},
		{
			name: "next_step",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Targets.NextStep.Enabled = false
				d.SetNextStepPipeline(targets.New(database, &cfg.Targets, gen, nil, cfg.Digest.Language, l))
			},
			run: func(d *Daemon) { d.phaseNextStep(context.Background()) },
		},
		{
			name: "briefing",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.Briefing.Enabled = false
				// shouldRunBriefing has its own Hour gate, unrelated to the
				// Enabled flag under test — pin Hour so shouldRunBriefing
				// would return true were Enabled the only gate (the
				// TestShouldRunBriefing_AfterHourFreshDB precedent), so this
				// case exercises the Enabled check rather than passing for
				// the wrong reason. No t.Skip: during the 00:00-00:59 local
				// hour shouldRunBriefing's own Hour check would ALSO return
				// false, so the assertion still holds (zero rows) — just
				// without distinguishing which gate fired for that one hour
				// a day, rather than skipping the case outright.
				cfg.Briefing.Hour = 1
				d.SetBriefingPipeline(briefing.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) { d.phaseBriefing(context.Background()) },
		},
		{
			name: "day_plan",
			wire: func(t *testing.T, d *Daemon, cfg *config.Config, database *db.DB, gen *mockGenerator, l *log.Logger) {
				cfg.DayPlan.Enabled = false
				require.NoError(t, database.UpsertWorkspace(db.Workspace{
					ID: "T1", Name: "test-ws", Domain: "test-ws",
				}))
				_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
				require.NoError(t, err)
				// Seed today's plan so runDayPlanConflictPhase reaches its
				// own Enabled gate instead of returning early via its
				// pre-existing "no plan yet" check (prev == nil) — the
				// latter would pass regardless of the gate under test.
				_, err = database.UpsertDayPlan(&db.DayPlan{
					UserID: "U001", PlanDate: time.Now().Format("2006-01-02"),
					Status: "active", GeneratedAt: time.Now(), FeedbackHistory: "[]",
				})
				require.NoError(t, err)
				d.SetDayPlanPipeline(dayplan.New(database, cfg, gen, l))
			},
			run: func(d *Daemon) {
				now := time.Now()
				d.runDayPlanPhase(context.Background(), now)
				d.runDayPlanConflictPhase(context.Background(), now)
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("HOME", dir)

			cfg := &config.Config{ActiveWorkspace: "test-ws"}
			require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))

			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { database.Close() })

			l := log.New(os.Stderr, "[test-gate-"+tc.name+"] ", 0)
			gen := &mockGenerator{}

			d := New(cfg)
			d.SetLogger(l)
			d.SetDB(database)

			tc.wire(t, d, cfg, database, gen, l)
			tc.run(d)

			check := tc.check
			if check == nil {
				check = assertNoPipelineRuns
			}
			check(t, cfg, database)
		})
	}
}

// TestDaemon_PhaseFeed_IgnoresConfigKillSwitch pins the Core-feature
// counterpart to TestFeatureGates_DisabledPhaseWritesNoPipelineRun: Feed is
// registered Core in internal/features (no toggle, `features
// enable/disable feed` is refused), so unlike every gated phase above,
// clearing cfg.Feed.Enabled directly — the one way `feed.enabled` remained
// reachable, via `config set feed.enabled false` or a hand-edited yaml —
// must NOT stop phaseFeed from publishing. Before this test's fix, the same
// early-return-on-disabled pattern used by every other phase let a plain
// config edit permanently kill the Dashboard timeline with no feature-manager
// path back on.
func TestDaemon_PhaseFeed_IgnoresConfigKillSwitch(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	cfg.Feed.Enabled = false
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	_, err = database.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'high', 'open', '2026-07-09T10:00:00Z')`)
	require.NoError(t, err)

	l := log.New(os.Stderr, "[test-feed-core] ", 0)
	d := New(cfg)
	d.SetLogger(l)
	d.SetDB(database)
	d.SetFeedPipeline(feed.New(database, cfg, l))

	d.phaseFeed()

	item, err := database.GetFeedItem("situation", "1")
	require.NoError(t, err)
	assert.NotNil(t, item, "feed.enabled=false must never silently kill the Core feed phase")
}

// TestDaemon_RunDayPlanConflictPhase_DisabledSkipsEntirely pins the gate this
// task adds to runDayPlanConflictPhase, which previously had NO cfg.DayPlan.
// Enabled check at all — see TestDaemon_DayPlanConflictPhase, which (before
// this task) asserted SyncCalendarItemsForDate/DetectConflicts were called
// without ever setting the flag, because nothing gated them on it. This test
// clears every OTHER precondition the old code needed to reach those calls
// (resolvable current user, an existing day plan for today) so only the new
// Enabled gate can be what stops it.
func TestDaemon_RunDayPlanConflictPhase_DisabledSkipsEntirely(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.DayPlan.Enabled = false

	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	require.NoError(t, database.UpsertWorkspace(db.Workspace{
		ID: "T024BE7LD", Name: "test-ws", Domain: "test-ws",
	}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)
	testDate := "2026-04-23"
	plan := &db.DayPlan{
		UserID: "U001", PlanDate: testDate, Status: "active",
		GeneratedAt: time.Now(), FeedbackHistory: "[]",
	}
	_, err = database.UpsertDayPlan(plan)
	require.NoError(t, err)

	fp := &fakeDayPlanRunner{database: database}
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-dayplan-conflict-gate] ", 0))
	d.SetDB(database)
	d.SetDayPlanPipeline(fp)

	testTime := time.Date(2026, 4, 23, 10, 0, 0, 0, time.Local)
	d.runDayPlanConflictPhase(context.Background(), testTime)

	assert.Equal(t, 0, fp.syncCalls, "disabled day_plan must never sync calendar items")
	assert.Equal(t, 0, fp.detectCalls, "disabled day_plan must never detect conflicts")
}
