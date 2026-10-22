package daemon

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mbSentinel is a coaching line of the generated brief; the day plan's
// prompt carries it when the plan reads the brief.
const mbSentinel = "Ship the morning sentinel"

const (
	mbBriefResponse = `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],` +
		`"coaching":[{"text":"` + mbSentinel + `","category":"process"}]}`
	mbPlanResponse = `{"timeblocks":[{"source_type":"focus","source_id":null,"title":"Deep work",` +
		`"description":"Block","rationale":"r","start_time_local":"10:00","end_time_local":"11:30","priority":"high"}],` +
		`"backlog":[{"source_type":"focus","source_id":null,"title":"Task","description":"x","rationale":"y","priority":"medium"}],` +
		`"summary":"Focused morning"}`
)

// mbGenerator answers the briefing and the day-plan calls, failing either on
// request, and records the day plan's system prompts.
type mbGenerator struct {
	mu          gosync.Mutex
	briefErr    error
	planErr     error
	calls       int
	planPrompts []string
}

func (g *mbGenerator) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	usage := &digest.Usage{InputTokens: 10, OutputTokens: 5, TotalAPITokens: 15}
	switch user {
	case "Generate the daily briefing.":
		if g.briefErr != nil {
			return "", nil, "", g.briefErr
		}
		return mbBriefResponse, usage, "", nil
	case "Generate the day plan.":
		g.planPrompts = append(g.planPrompts, system)
		if g.planErr != nil {
			return "", nil, "", g.planErr
		}
		return mbPlanResponse, usage, "", nil
	}
	return "", nil, "", errors.New("unexpected call: " + user)
}

func (g *mbGenerator) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls
}

// mbFixture is a daemon over a real database with an owner, a digest for
// the day, both Morning brief features on (briefing.hour 9) and real
// briefing/day-plan pipelines over gen.
type mbFixture struct {
	d     *Daemon
	db    *db.DB
	cfg   *config.Config
	gen   *mbGenerator
	clock *automationstest.FakeClock
	log   *strings.Builder
}

// mbDay is the fixture's day (local).
func mbAt(hour, minute int) time.Time {
	return time.Date(2026, 10, 22, hour, minute, 0, 0, time.Local)
}

func newMBFixture(t *testing.T, edit func(cfg *config.Config)) *mbFixture {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	require.NoError(t, err)
	cfg.ActiveWorkspace = "test-ws"
	cfg.Digest.Enabled, cfg.Digest.Language = true, "English"
	cfg.Briefing.Enabled, cfg.Briefing.Hour = true, 9
	cfg.DayPlan.Enabled = true
	if edit != nil {
		edit(cfg)
	}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))

	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))
	_, err = database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: "alice", DisplayName: "Alice"}))
	day := mbAt(0, 0)
	_, err = database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(day.AddDate(0, 0, -1).Unix()), PeriodTo: float64(day.AddDate(0, 0, 1).Unix()),
		Summary: "some discussion", Topics: `[]`, Decisions: `[]`, ActionItems: `[]`, MessageCount: 5,
	})
	require.NoError(t, err)

	var buf strings.Builder
	l := log.New(&buf, "", 0)
	gen := &mbGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(l)
	d.SetDB(database)
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, l))
	d.SetDayPlanPipeline(dayplan.New(database, cfg, gen, l))
	f := &mbFixture{d: d, db: database, cfg: cfg, gen: gen, clock: automationstest.NewFakeClock(mbAt(10, 0)), log: &buf}
	wireTestBuiltins(t, d, database, cfg, f.clock)
	return f
}

// wireTestBuiltins wires the built-ins as wireBuiltins does: a slot
// executor over d's primitives, the Morning brief's gate, synced rows, the
// Morning brief active.
func wireTestBuiltins(t *testing.T, d *Daemon, database *db.DB, cfg *config.Config, clock automations.Clock) {
	t.Helper()
	b := automations.Backends{DB: database, Clock: clock, Primitives: d.BuiltinPrimitives(), DefaultPrompt: builtin.DefaultPromptFunc}
	exec := automations.NewExecutor(database, b, automations.ExecutorOptions{Logger: log.New(io.Discard, "", 0)})
	r := builtin.NewRunner(database, exec, map[string]builtin.Gate{morningBriefID: d.MorningBriefGate()}, cfg, clock, d.logger)
	_, err := builtin.Sync(context.Background(), database, cfg.WorkspaceDir(), cfg, clock.Now())
	require.NoError(t, err)
	d.SetBuiltins(r, map[string]bool{morningBriefID: true})
}

// cycle runs the Morning brief slot at now.
func (f *mbFixture) cycle(now time.Time) {
	f.clock.Set(now)
	f.d.phaseMorningBrief(context.Background(), now)
}

func (f *mbFixture) runs(t *testing.T) []db.AutomationRun {
	t.Helper()
	a, err := f.db.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	runs, err := f.db.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	return runs
}

func countRows(t *testing.T, database *db.DB, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(query, args...).Scan(&n))
	return n
}

func assertNoAutomationRuns(t *testing.T, database *db.DB) {
	t.Helper()
	assert.Equal(t, 0, countRows(t, database, `SELECT COUNT(*) FROM automation_runs`), "no automation_runs row")
}

func TestMorningBrief_DueRunMakesBriefThenPlanInOneRun(t *testing.T) {
	f := newMBFixture(t, nil)
	f.cycle(mbAt(10, 0))

	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerSync, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Positive(t, runs[0].InputTokens, "the run's meter saw the pipelines' usage")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM briefings`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM day_plans`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'briefing'`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'day_plan'`))
	require.Len(t, f.gen.planPrompts, 1)
	assert.Contains(t, f.gen.planPrompts[0], mbSentinel, "the plan reads the brief made before it")
}

func TestMorningBrief_PlanWaitsForBriefingHour(t *testing.T) {
	f := newMBFixture(t, func(cfg *config.Config) { cfg.Briefing.Enabled = false })
	owner, err := f.db.ResolveOwner()
	require.NoError(t, err)
	_, err = f.db.UpsertDayPlan(&db.DayPlan{UserID: owner.ID, PlanDate: "2026-10-21", Status: "active",
		GeneratedAt: mbAt(9, 0).AddDate(0, 0, -1), FeedbackHistory: "[]"})
	require.NoError(t, err)

	f.cycle(mbAt(8, 30))
	assert.Empty(t, f.runs(t), "before briefing.hour the plan waits")
	plan, err := f.db.GetDayPlan(owner.ID, "2026-10-22")
	require.NoError(t, err)
	assert.Nil(t, plan)

	f.cycle(mbAt(9, 5))
	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	plan, err = f.db.GetDayPlan(owner.ID, "2026-10-22")
	require.NoError(t, err)
	assert.NotNil(t, plan)
}

func TestMorningBrief_FreshInstallBypassesHour(t *testing.T) {
	f := newMBFixture(t, nil)
	f.cycle(mbAt(7, 0))

	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM briefings`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM day_plans`))
}

func TestMorningBrief_ThreeFailedAttemptsStopForTheDay(t *testing.T) {
	f := newMBFixture(t, nil)
	f.gen.briefErr, f.gen.planErr = errors.New("boom"), errors.New("boom")

	for i := range 3 {
		f.cycle(mbAt(10, 15*i))
	}
	runs := f.runs(t)
	require.Len(t, runs, 3)
	for _, r := range runs {
		assert.Equal(t, db.RunFailed, r.Status)
	}
	assert.Equal(t, 6, f.gen.count(), "each cycle reached both model calls")

	f.cycle(mbAt(11, 0))
	assert.Len(t, f.runs(t), 3, "the fourth cycle writes no run")
	assert.Equal(t, 6, f.gen.count())
}

func TestMorningBrief_SecondCycleSameDayWritesNoRun(t *testing.T) {
	f := newMBFixture(t, nil)
	f.cycle(mbAt(10, 0))
	f.cycle(mbAt(10, 15))

	assert.Len(t, f.runs(t), 1)
	assert.Equal(t, 2, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs`), "one briefing row, one day_plan row")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'day_plan'`))
}

func TestMorningBrief_BriefFailsPlanStillRuns(t *testing.T) {
	f := newMBFixture(t, nil)
	f.gen.briefErr = errors.New("boom")
	f.cycle(mbAt(10, 0))

	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunFailed, runs[0].Status)
	assert.Equal(t, db.ErrKindBackend, runs[0].ErrorKind)
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM day_plans`))
	assert.Equal(t, 1, f.d.briefingAttempts)
	assert.Equal(t, 0, f.d.dayPlanAttempts)
}

func TestMorningBrief_InterruptedRunDoesNotBlockNextCycle(t *testing.T) {
	f := newMBFixture(t, nil)
	a, err := f.db.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	left, _, err := f.db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync, Now: mbAt(9, 0)})
	require.NoError(t, err)
	_, err = f.db.Exec(`UPDATE automation_runs SET status = 'running', started_at = queued_at WHERE id = ?`, left)
	require.NoError(t, err)

	f.d.sweepBuiltinRuns() // the daemon's start
	interrupted, err := f.db.GetAutomationRun(left)
	require.NoError(t, err)
	assert.Equal(t, db.RunFailed, interrupted.Status)
	assert.Equal(t, db.ErrKindInterrupted, interrupted.ErrorKind)

	f.cycle(mbAt(10, 0))
	runs := f.runs(t)
	require.Len(t, runs, 2)
	var ran *db.AutomationRun
	for i := range runs {
		if runs[i].ID != left {
			ran = &runs[i]
		}
	}
	require.NotNil(t, ran)
	assert.Equal(t, db.RunSucceeded, ran.Status, ran.Error)
	assert.LessOrEqual(t, f.d.briefingAttempts, 1)
	assert.LessOrEqual(t, f.d.dayPlanAttempts, 1)
}

func TestMorningBrief_LegacyPathWhenNotActive(t *testing.T) {
	f := newMBFixture(t, nil)
	f.d.builtinActive[morningBriefID] = false
	f.cycle(mbAt(10, 0))

	assertNoAutomationRuns(t, f.db)
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'briefing'`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'day_plan'`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM briefings WHERE date = '2026-10-22'`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM day_plans WHERE plan_date = '2026-10-22'`))
}

// TestMorningBrief_NoDataBriefBacksOffAnHour: a sync brief that finds nothing
// to summarize writes one run; the next cycles of the hour write none (the
// plan is not due either); an hour later the brief is due again. (An earlier
// day's briefing exists: a fresh install has no backoff, see
// TestMorningBrief_FreshInstallNoDataHasNoBackoff.)
func TestMorningBrief_NoDataBriefBacksOffAnHour(t *testing.T) {
	f := newMBFixture(t, func(cfg *config.Config) { cfg.DayPlan.Enabled = false })
	_, err := f.db.Exec(`DELETE FROM digests`)
	require.NoError(t, err)
	_, err = f.db.Exec(`INSERT INTO briefings (workspace_id, user_id, date) VALUES ('T1', 'U001', '2026-10-21')`)
	require.NoError(t, err)

	f.cycle(mbAt(10, 0))
	runs := f.runs(t)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Zero(t, f.gen.count(), "no data, no model call")

	f.cycle(mbAt(10, 15))
	f.cycle(mbAt(10, 45))
	assert.Len(t, f.runs(t), 1, "within the hour a no-data brief is not due")

	f.cycle(mbAt(11, 1))
	assert.Len(t, f.runs(t), 2, "an hour later the brief is due again")
	assert.Zero(t, f.d.briefingAttempts, "no data is not a failed attempt")
}

// TestMorningBrief_FreshInstallNoDataHasNoBackoff: while no briefing was
// ever made, a no-data brief does not hold the next cycle back, so the first
// brief comes in the first cycle after the first digests land.
func TestMorningBrief_FreshInstallNoDataHasNoBackoff(t *testing.T) {
	f := newMBFixture(t, func(cfg *config.Config) { cfg.DayPlan.Enabled = false })
	_, err := f.db.Exec(`DELETE FROM digests`)
	require.NoError(t, err)

	f.cycle(mbAt(10, 0))
	require.Len(t, f.runs(t), 1)
	assert.Zero(t, f.gen.count(), "no data, no model call")

	day := mbAt(0, 0)
	_, err = f.db.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(day.AddDate(0, 0, -1).Unix()), PeriodTo: float64(day.AddDate(0, 0, 1).Unix()),
		Summary: "some discussion", Topics: `[]`, Decisions: `[]`, ActionItems: `[]`, MessageCount: 5,
	})
	require.NoError(t, err)
	f.cycle(mbAt(10, 15))
	assert.Len(t, f.runs(t), 2, "no backoff on a fresh install")
	assert.Equal(t, 1, f.gen.count(), "the first brief is made as soon as there is data")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM briefings WHERE date = '2026-10-22'`))
}

// TestMorningBrief_ManualRunChargesNoAttempt: a manual run (Run Now) that
// fails is the owner's own run — it charges neither day's attempt budget.
func TestMorningBrief_ManualRunChargesNoAttempt(t *testing.T) {
	f := newMBFixture(t, nil)
	f.gen.briefErr, f.gen.planErr = errors.New("boom"), errors.New("boom")

	run, err := f.d.builtins.RunNow(context.Background(), morningBriefID, automations.BuiltinInput{Date: "2026-10-22"})
	require.NoError(t, err)
	assert.Equal(t, db.RunFailed, run.Status)
	assert.Equal(t, 2, f.gen.count(), "both model calls were made")
	assert.Zero(t, f.d.briefingAttempts)
	assert.Zero(t, f.d.dayPlanAttempts)
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'briefing'`))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'day_plan'`))
}

// TestMorningBrief_ManualRunWithoutOwnerFails pins OWNER-02 for a manual
// run: no owner fails the run with db.ErrNoOwner's text, for the brief and
// for the plan alike, with no model call and no budget.
func TestMorningBrief_ManualRunWithoutOwnerFails(t *testing.T) {
	for _, only := range []string{"brief.compose", "plan.compose"} {
		t.Run(only, func(t *testing.T) {
			cfg := &config.Config{
				Digest:   config.DigestConfig{Enabled: true, Language: "English"},
				Briefing: config.BriefingConfig{Enabled: true, Hour: 1},
				DayPlan:  config.DayPlanConfig{Enabled: true},
			}
			d, database, _ := noOwnerDaemon(t, cfg)
			gen := &mbGenerator{}
			d.SetBriefingPipeline(briefing.New(database, cfg, gen, d.logger))
			d.SetDayPlanPipeline(dayplan.New(database, cfg, gen, d.logger))
			wireTestBuiltins(t, d, database, cfg, automations.RealClock{})

			run, err := d.builtins.RunNow(context.Background(), morningBriefID, automations.BuiltinInput{Only: []string{only}})
			require.NoError(t, err)
			assert.Equal(t, db.RunFailed, run.Status)
			assert.Contains(t, run.Error, db.ErrNoOwner.Error())
			assert.Zero(t, gen.count())
			assert.Zero(t, d.briefingAttempts)
			assert.Zero(t, d.dayPlanAttempts)
		})
	}
}

func TestMorningBrief_ConflictPhaseStillEveryCycle(t *testing.T) {
	f := newMBFixture(t, func(cfg *config.Config) { cfg.Briefing.Enabled = false })
	fp := &fakeDayPlanRunner{database: f.db}
	f.d.SetDayPlanPipeline(fp)
	wireTestBuiltins(t, f.d, f.db, f.cfg, f.clock) // primitives over the fake

	f.cycle(mbAt(10, 0))
	assert.Equal(t, 1, fp.runCalls)
	assert.Equal(t, 1, fp.syncCalls, "the conflict phase runs after the slot")
	f.cycle(mbAt(10, 15))
	f.cycle(mbAt(10, 30))
	assert.Equal(t, 1, fp.runCalls, "one plan a day")
	assert.Equal(t, 3, fp.syncCalls, "the conflict phase runs every cycle")
	assert.Equal(t, 3, fp.detectCalls)
	assert.Len(t, f.runs(t), 1)
}

func TestBuiltinPrimitives_HoldsMorningBriefPrimitives(t *testing.T) {
	d := New(&config.Config{})
	prims := d.BuiltinPrimitives()
	assert.NotNil(t, prims["brief.compose"])
	assert.NotNil(t, prims["plan.compose"])
	for _, name := range automations.BuiltinPrimitiveNames {
		assert.NotNil(t, prims[name], "primitive %s has no implementation", name)
	}
}

// A Run Now queued for the Morning brief while it runs on its legacy phases
// (its move failed) is cancelled: only the slot runner would take it.
func TestMorningBrief_LegacyPathCancelsQueuedRunNow(t *testing.T) {
	f := newMBFixture(t, nil)
	a, err := f.db.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	queued, _, err := f.db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: mbAt(9, 0)})
	require.NoError(t, err)
	f.d.builtinActive[morningBriefID] = false
	f.cycle(mbAt(10, 0))
	run, err := f.db.GetAutomationRun(queued)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)
	assert.Equal(t, db.ErrKindNotRunnable, run.ErrorKind)
}
