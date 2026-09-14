package daemon

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// ── shared attempt-marker unit tests ────────────────────────────────────────
//
// Day-plan and briefing each route through their own recordX/xAttemptsExhausted
// pair, both backed by the shared attemptMarker encoding, so the
// exhaustion/reset arithmetic for those two is pinned once here per pipeline,
// deterministically (no wall-clock dependency), rather than only exercised
// end-to-end. The daily rollup's own pair (recordRollupAttempt/
// rollupAttemptsExhausted) is a deliberate THIRD independent copy — see the
// "── daily rollup" section below — and is pinned only end-to-end via the
// TestDaemon_RollupBackoff_* tests, not by a matching unit-level pair here.

// TestDayPlanAttempts_ThreeFailuresExhaustBudget pins the counter itself: the
// 3rd recorded attempt exhausts the budget for that date, and a 4th attempt
// would be refused by the gate (proven end-to-end in
// TestDaemon_DayPlanBackoff_ThreeFailuresExhaustBudget below).
func TestDayPlanAttempts_ThreeFailuresExhaustBudget(t *testing.T) {
	d := newQuietDaemon(t)
	dir := t.TempDir()
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(d.config.WorkspaceDir(), 0o700))

	date := "2026-04-23"
	assert.False(t, d.dayPlanAttemptsExhausted(date), "budget must not be exhausted before any attempt")

	d.recordDayPlanAttempt(date)
	assert.False(t, d.dayPlanAttemptsExhausted(date), "1 of 3 must not exhaust the budget")

	d.recordDayPlanAttempt(date)
	assert.False(t, d.dayPlanAttemptsExhausted(date), "2 of 3 must not exhaust the budget")

	d.recordDayPlanAttempt(date)
	assert.True(t, d.dayPlanAttemptsExhausted(date), "3 of 3 must exhaust the budget")
}

// TestDayPlanAttempts_ResetsNextCalendarDay pins that an exhausted budget for
// one date does not carry over to a different date, and that recording an
// attempt on the new date starts its own fresh count (not 4, not carried).
func TestDayPlanAttempts_ResetsNextCalendarDay(t *testing.T) {
	d := newQuietDaemon(t)
	dir := t.TempDir()
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(d.config.WorkspaceDir(), 0o700))

	d.recordDayPlanAttempt("2026-04-23")
	d.recordDayPlanAttempt("2026-04-23")
	d.recordDayPlanAttempt("2026-04-23")
	require.True(t, d.dayPlanAttemptsExhausted("2026-04-23"))

	assert.False(t, d.dayPlanAttemptsExhausted("2026-04-24"), "a new calendar day must not inherit yesterday's exhausted budget")

	d.recordDayPlanAttempt("2026-04-24")
	assert.Equal(t, 1, d.dayPlanAttempts, "the counter must restart at 1 on a new day, not continue from 4")
	assert.False(t, d.dayPlanAttemptsExhausted("2026-04-24"))
}

// TestBriefingAttempts_ThreeFailuresExhaustBudget is the briefing counterpart
// of TestDayPlanAttempts_ThreeFailuresExhaustBudget.
func TestBriefingAttempts_ThreeFailuresExhaustBudget(t *testing.T) {
	d := newQuietDaemon(t)
	dir := t.TempDir()
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(d.config.WorkspaceDir(), 0o700))

	date := "2026-04-23"
	d.recordBriefingAttempt(date)
	d.recordBriefingAttempt(date)
	assert.False(t, d.briefingAttemptsExhausted(date), "2 of 3 must not exhaust the budget")
	d.recordBriefingAttempt(date)
	assert.True(t, d.briefingAttemptsExhausted(date), "3 of 3 must exhaust the budget")
}

// TestBriefingAttempts_ResetsNextCalendarDay is the briefing counterpart of
// TestDayPlanAttempts_ResetsNextCalendarDay.
func TestBriefingAttempts_ResetsNextCalendarDay(t *testing.T) {
	d := newQuietDaemon(t)
	dir := t.TempDir()
	d.config.ActiveWorkspace = "test"
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(d.config.WorkspaceDir(), 0o700))

	d.recordBriefingAttempt("2026-04-23")
	d.recordBriefingAttempt("2026-04-23")
	d.recordBriefingAttempt("2026-04-23")
	require.True(t, d.briefingAttemptsExhausted("2026-04-23"))

	assert.False(t, d.briefingAttemptsExhausted("2026-04-24"))
	d.recordBriefingAttempt("2026-04-24")
	assert.Equal(t, 1, d.briefingAttempts)
	assert.False(t, d.briefingAttemptsExhausted("2026-04-24"))
}

// ── day plan: end-to-end through the real daemon phase ──────────────────────
//
// runDayPlanPhase/shouldRunDayPlan take `now` as a parameter, so these tests
// drive real calendar-day transitions deterministically without depending on
// the wall clock.

func dayPlanBackoffTestSetup(t *testing.T) (*Daemon, *db.DB, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		DayPlan:         config.DayPlanConfig{Enabled: true, Hour: 0},
	}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	return d, database, wsDir
}

func TestDaemon_DayPlanBackoff_ThreeFailuresExhaustBudget(t *testing.T) {
	d, _, _ := dayPlanBackoffTestSetup(t)
	fp := &fakeDayPlanRunner{alwaysFail: true}
	d.SetDayPlanPipeline(fp)

	testTime := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)

	d.runDayPlanPhase(context.Background(), testTime)
	d.runDayPlanPhase(context.Background(), testTime.Add(time.Hour))
	d.runDayPlanPhase(context.Background(), testTime.Add(2*time.Hour))
	require.Equal(t, 3, fp.runCalls, "three real failures should each invoke Run")

	// Fourth cycle the same day: the budget is exhausted, so shouldRunDayPlan
	// must refuse before ever calling into the pipeline again.
	d.runDayPlanPhase(context.Background(), testTime.Add(3*time.Hour))
	assert.Equal(t, 3, fp.runCalls, "a 4th cycle on the same day must launch nothing once the budget is spent")
}

// TestDaemon_DayPlanBackoff_LogsGivingUpOnceBudgetExhausted pins the owner
// visibility requirement: exhausting the budget must be observable, distinct
// from "not generated yet" — and it must be logged exactly once (on the
// exhausting attempt), not repeated on every subsequent silent skip that day.
func TestDaemon_DayPlanBackoff_LogsGivingUpOnceBudgetExhausted(t *testing.T) {
	d, _, _ := dayPlanBackoffTestSetup(t)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))
	fp := &fakeDayPlanRunner{alwaysFail: true}
	d.SetDayPlanPipeline(fp)

	testTime := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)
	d.runDayPlanPhase(context.Background(), testTime)
	d.runDayPlanPhase(context.Background(), testTime.Add(time.Hour))
	assert.Equal(t, 0, strings.Count(buf.String(), "giving up"), "must not log giving-up before the budget is actually spent")

	d.runDayPlanPhase(context.Background(), testTime.Add(2*time.Hour))
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must log giving-up exactly once when the 3rd failure spends the budget")

	// A 4th (and 5th) cycle the same day is a silent skip — no repeat log line.
	d.runDayPlanPhase(context.Background(), testTime.Add(3*time.Hour))
	d.runDayPlanPhase(context.Background(), testTime.Add(4*time.Hour))
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must not repeat the giving-up line on later silent skips the same day")
}

func TestDaemon_DayPlanBackoff_BenignNoUserSkipDoesNotConsumeBudget(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	// Deliberately no workspace/slack account seeded: GetCurrentUserID() ==
	// "", so shouldRunDayPlan must refuse before ever calling Run.

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		DayPlan:         config.DayPlanConfig{Enabled: true, Hour: 0},
	}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	fp := &fakeDayPlanRunner{alwaysFail: true}
	d.SetDayPlanPipeline(fp)

	testTime := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)
	for i := 0; i < 5; i++ {
		d.runDayPlanPhase(context.Background(), testTime.Add(time.Duration(i)*time.Hour))
	}

	assert.Equal(t, 0, fp.runCalls, "a benign no-current-user skip must never invoke Run")
	assert.Equal(t, 0, d.dayPlanAttempts, "a benign skip must not consume any budget")
}

func TestDaemon_DayPlanBackoff_ResetsNextCalendarDay(t *testing.T) {
	d, _, _ := dayPlanBackoffTestSetup(t)
	fp := &fakeDayPlanRunner{alwaysFail: true}
	d.SetDayPlanPipeline(fp)

	day1 := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)
	d.runDayPlanPhase(context.Background(), day1)
	d.runDayPlanPhase(context.Background(), day1.Add(time.Hour))
	d.runDayPlanPhase(context.Background(), day1.Add(2*time.Hour))
	require.Equal(t, 3, fp.runCalls)
	d.runDayPlanPhase(context.Background(), day1.Add(3*time.Hour))
	require.Equal(t, 3, fp.runCalls, "day 1's budget must be exhausted")

	// The new day must get its OWN full budget of 3 (not just let one
	// straggler attempt through and then immediately re-exhaust because the
	// counter carried over instead of resetting).
	day2 := day1.AddDate(0, 0, 1)
	d.runDayPlanPhase(context.Background(), day2)
	assert.Equal(t, 4, fp.runCalls, "a new calendar day must get a fresh budget and actually launch a real attempt")
	d.runDayPlanPhase(context.Background(), day2.Add(time.Hour))
	assert.Equal(t, 5, fp.runCalls, "day 2's 2nd attempt must also launch — its budget must not have inherited day 1's spent count")
	d.runDayPlanPhase(context.Background(), day2.Add(2*time.Hour))
	require.Equal(t, 6, fp.runCalls, "day 2's 3rd attempt must also launch")

	// Now day 2's own budget of 3 is spent — a 4th attempt the same day must
	// be refused again.
	d.runDayPlanPhase(context.Background(), day2.Add(3*time.Hour))
	assert.Equal(t, 6, fp.runCalls, "day 2's 4th cycle must launch nothing once ITS budget is spent")
}

// TestDaemon_DayPlanBackoff_SurvivesRestart is the test the in-memory
// lastDayPlanDate field alone could never pass: attempts recorded by one
// Daemon instance must still block a brand new Daemon instance (a simulated
// restart) pointed at the same workspace directory.
func TestDaemon_DayPlanBackoff_SurvivesRestart(t *testing.T) {
	d1, database, _ := dayPlanBackoffTestSetup(t)
	fp1 := &fakeDayPlanRunner{alwaysFail: true}
	d1.SetDayPlanPipeline(fp1)

	testTime := time.Date(2026, 4, 23, 8, 0, 0, 0, time.Local)
	d1.runDayPlanPhase(context.Background(), testTime)
	d1.runDayPlanPhase(context.Background(), testTime.Add(time.Hour))
	d1.runDayPlanPhase(context.Background(), testTime.Add(2*time.Hour))
	require.Equal(t, 3, fp1.runCalls)

	// Simulate a daemon restart: a brand new Daemon, same config/workspace,
	// no in-memory state carried over except what loadDayPlanAttempts
	// restores from disk.
	d2 := newDaemon(nil, d1.config)
	d2.SetLogger(log.New(io.Discard, "", 0))
	d2.SetDB(database)
	fp2 := &fakeDayPlanRunner{alwaysFail: true}
	d2.SetDayPlanPipeline(fp2)
	d2.loadDayPlanAttempts()

	d2.runDayPlanPhase(context.Background(), testTime.Add(3*time.Hour))
	assert.Equal(t, 0, fp2.runCalls, "a restarted daemon must honor the already-spent budget instead of resetting it")
}

// ── briefing: end-to-end through the real daemon phase ──────────────────────
//
// shouldRunBriefing/recordBriefingAttempt read the wall clock directly, so
// these tests need the current hour to clear the (very low) configured
// Briefing.Hour gate — mirroring the existing TestShouldRunBriefing_* skip
// convention in daemon_helpers_test.go rather than inventing a new one.

// erroringGenerator is a digest.Generator that always fails, driving
// briefing.Pipeline.RunForDate into its real-failure return shape
// (0, err) — as opposed to its two benign-skip shapes, which both return
// (0, nil) without ever calling Generate.
type erroringGenerator struct {
	calls int
}

func (g *erroringGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	return "", nil, "", errors.New("boom")
}

func briefingBackoffTestSetup(t *testing.T) (*Daemon, *db.DB, *erroringGenerator) {
	t.Helper()
	if time.Now().Hour() < 1 {
		t.Skip("hour is below briefing threshold")
	}
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)
	require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: "alice", DisplayName: "Alice"}))

	// A digest overlapping today so RunForDate's hasData check passes and it
	// reaches the real AI-generate call instead of the benign "no data yet"
	// skip.
	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 0, 0, 0, now.Location())
	dayEnd := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, now.Location())
	_, err = database.UpsertDigest(db.Digest{
		ChannelID:    "C1",
		Type:         "channel",
		PeriodFrom:   float64(dayStart.Unix()),
		PeriodTo:     float64(dayEnd.Unix()),
		Summary:      "some discussion",
		Topics:       `[]`,
		Decisions:    `[]`,
		ActionItems:  `[]`,
		MessageCount: 5,
	})
	require.NoError(t, err)

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, Language: "English"},
		Briefing:        config.BriefingConfig{Enabled: true, Hour: 1},
	}
	gen := &erroringGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, d.logger))
	return d, database, gen
}

func TestDaemon_BriefingBackoff_ThreeFailuresExhaustBudget(t *testing.T) {
	d, _, gen := briefingBackoffTestSetup(t)

	d.phaseBriefing(context.Background())
	d.phaseBriefing(context.Background())
	d.phaseBriefing(context.Background())
	require.Equal(t, 3, gen.calls, "three real failures should each reach the AI generate call")

	d.phaseBriefing(context.Background())
	assert.Equal(t, 3, gen.calls, "a 4th cycle on the same day must launch nothing once the budget is spent")
}

// TestDaemon_BriefingBackoff_LogsGivingUpOnceBudgetExhausted is the briefing
// counterpart of TestDaemon_DayPlanBackoff_LogsGivingUpOnceBudgetExhausted —
// pinned separately because the record*Attempt functions (day-plan, briefing,
// and — see TestDaemon_RollupBackoff_* below — the daily rollup) are three
// independent copies today and a future edit could diverge them silently
// otherwise.
func TestDaemon_BriefingBackoff_LogsGivingUpOnceBudgetExhausted(t *testing.T) {
	d, _, gen := briefingBackoffTestSetup(t)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))

	d.phaseBriefing(context.Background())
	d.phaseBriefing(context.Background())
	require.Equal(t, 2, gen.calls)
	assert.Equal(t, 0, strings.Count(buf.String(), "giving up"), "must not log giving-up before the budget is actually spent")

	d.phaseBriefing(context.Background())
	require.Equal(t, 3, gen.calls)
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must log giving-up exactly once when the 3rd failure spends the budget")

	// A 4th (and 5th) cycle the same day is a silent skip — no repeat log line.
	d.phaseBriefing(context.Background())
	d.phaseBriefing(context.Background())
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must not repeat the giving-up line on later silent skips the same day")
}

func TestDaemon_BriefingBackoff_BenignNoUserSkipDoesNotConsumeBudget(t *testing.T) {
	if time.Now().Hour() < 1 {
		t.Skip("hour is below briefing threshold")
	}
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	// Deliberately no current user: RunForDate's "no current user set,
	// skipping" benign shape, (0, nil), returned before Generate is ever
	// called.

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, Language: "English"},
		Briefing:        config.BriefingConfig{Enabled: true, Hour: 1},
	}
	gen := &erroringGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, d.logger))

	for i := 0; i < 5; i++ {
		d.phaseBriefing(context.Background())
	}

	assert.Equal(t, 0, gen.calls, "a benign no-current-user skip must never reach the AI generate call")
	assert.Equal(t, 0, d.briefingAttempts, "a benign skip must not consume any budget")
}

func TestDaemon_BriefingBackoff_SurvivesRestart(t *testing.T) {
	d1, database, gen1 := briefingBackoffTestSetup(t)

	d1.phaseBriefing(context.Background())
	d1.phaseBriefing(context.Background())
	d1.phaseBriefing(context.Background())
	require.Equal(t, 3, gen1.calls)

	// Simulate a daemon restart: a brand new Daemon over the same
	// config/workspace and a fresh generator (a real process restart would
	// also re-launch the AI subprocess), restoring only what
	// loadBriefingAttempts reads back from disk.
	d2 := newDaemon(nil, d1.config)
	d2.SetLogger(log.New(io.Discard, "", 0))
	d2.SetDB(database)
	gen2 := &erroringGenerator{}
	d2.SetBriefingPipeline(briefing.New(database, d1.config, gen2, d2.logger))
	d2.loadBriefingAttempts()

	d2.phaseBriefing(context.Background())
	assert.Equal(t, 0, gen2.calls, "a restarted daemon must honor the already-spent budget instead of resetting it")
}

// ── daily rollup: end-to-end through the real daemon phase ──────────────────
//
// phaseTracksAndRollups takes a `now time.Time` parameter (the
// runDayPlanPhase/phaseBriefing shape) used only for the rollup attempt
// budget's date — RunDailyRollup itself still always computes its own
// digest-query window from time.Now().UTC() independently, unaffected by
// this parameter. rollupFixedNow below is a fixed instant whose local and
// UTC calendar dates differ by construction, threaded through the exhaust
// and restart tests so the marker file's date can be pinned exactly
// (F1: proving the phase actually calls rollupBudgetDate(now) rather than
// reading the wall clock independently — a call-site regression to
// time.Now() would write the real machine's current UTC date instead of
// this fixture's, and the exact-match assertion below would fail
// deterministically, regardless of the machine's own time zone or time of
// day). TestDaemon_RollupBackoff_ResetsNextCalendarDay still simulates a day
// boundary by rewriting rollupAttemptDate directly, the approach the
// verification report names for this shape.
var rollupFixedNow = time.Date(2026, 9, 14, 23, 30, 0, 0, time.FixedZone("UTC-10", -10*3600))

// TestRollupBudgetDate_UsesUTCNotLocal is the deterministic counterpart to
// the wall-clock UTC-date assertion inside
// TestDaemon_RollupBackoff_ThreeFailuresExhaustBudget: that assertion
// compares against the real clock, so it only catches a dropped `.UTC()`
// near the UTC day boundary (whatever the machine's own time zone happens to
// be at the moment the test runs). This test instead picks a fixed instant
// whose LOCAL and UTC calendar dates differ (23:30 in a UTC-10 zone is
// already the next day in UTC) and pins rollupBudgetDate against it
// directly — deterministic regardless of the machine or time of day running
// the test.
func TestRollupBudgetDate_UsesUTCNotLocal(t *testing.T) {
	require.Equal(t, "2026-09-14", rollupFixedNow.Format("2006-01-02"), "sanity: the local date must be the 14th")
	require.Equal(t, "2026-09-15", rollupFixedNow.UTC().Format("2006-01-02"), "sanity: the UTC date must be the 15th")

	assert.Equal(t, "2026-09-15", rollupBudgetDate(rollupFixedNow), "rollupBudgetDate must return the UTC date, not the local one")
}

// rollupBackoffTestSetup seeds two channel digests on DISTINCT channels
// inside today's UTC window. Two rows on the SAME channel would collapse via
// UpsertDigest's uniqueness constraint and turn every budget test below into
// a vacuous benign-skip test (dailyRollupNeeded's "< 2 channel digests" arm
// firing on every cycle instead of reaching Generate) — the one-element-
// fixture trap the report calls out explicitly.
func rollupBackoffTestSetup(t *testing.T) (*Daemon, *db.DB, *erroringGenerator) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))

	seedTwoChannelDigests(t, database)

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, Language: "English"},
	}
	gen := &erroringGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetDigestPipeline(digest.New(database, cfg, gen, d.logger))
	return d, database, gen
}

// seedTwoChannelDigests inserts channel digests on C1 and C2, both inside
// today's UTC window (the exact window runDailyRollupForDate computes from
// time.Now().UTC()) — enough for dailyRollupNeeded to reach the real
// AI-generate call instead of its "< 2 channel digests" benign skip.
func seedTwoChannelDigests(t *testing.T, database *db.DB) {
	t.Helper()
	now := time.Now().UTC()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	dayEnd := dayStart.Add(24*time.Hour - time.Second)
	for _, ch := range []string{"C1", "C2"} {
		_, err := database.UpsertDigest(db.Digest{
			ChannelID:    ch,
			Type:         "channel",
			PeriodFrom:   float64(dayStart.Unix()),
			PeriodTo:     float64(dayEnd.Unix()),
			Summary:      "some discussion in " + ch,
			Topics:       `[]`,
			Decisions:    `[]`,
			ActionItems:  `[]`,
			MessageCount: 5,
		})
		require.NoError(t, err)
	}
}

func TestDaemon_RollupBackoff_ThreeFailuresExhaustBudget(t *testing.T) {
	d, _, gen := rollupBackoffTestSetup(t)

	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	require.Equal(t, 3, gen.calls, "three real failures should each reach the AI generate call")

	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 3, gen.calls, "a 4th cycle on the same day must launch nothing once the budget is spent")

	// Exact-match assertion (not a prefix check against the real wall clock)
	// that the phase actually threaded rollupFixedNow into rollupBudgetDate:
	// a call-site regression to time.Now() would write the real machine's
	// current UTC date here instead, which this literal cannot coincidentally
	// match (F1) — deterministic regardless of the machine's own time zone or
	// time of day.
	data, err := os.ReadFile(d.rollupAttemptsPath())
	require.NoError(t, err)
	assert.Equal(t, "2026-09-15,3", string(data),
		"the rollup attempt marker must be keyed on rollupFixedNow's UTC date, not local and not a separate wall-clock read")
}

// TestDaemon_RollupBackoff_LogsGivingUpOnceBudgetExhausted is the rollup
// counterpart of TestDaemon_DayPlanBackoff_LogsGivingUpOnceBudgetExhausted /
// TestDaemon_BriefingBackoff_LogsGivingUpOnceBudgetExhausted — pinned
// separately per that comment's note that the three record*Attempt functions
// are independent copies. This one matters more than the other two: the
// daemon's rollup call is not wrapped in trackedPipelineRun, so this log
// line is the owner's ONLY signal that the rollup gave up for the day —
// there is no pipeline_runs error row to fall back on (see
// recordRollupAttempt's doc comment).
func TestDaemon_RollupBackoff_LogsGivingUpOnceBudgetExhausted(t *testing.T) {
	d, _, gen := rollupBackoffTestSetup(t)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))

	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	require.Equal(t, 2, gen.calls)
	assert.Equal(t, 0, strings.Count(buf.String(), "giving up"), "must not log giving-up before the budget is actually spent")

	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	require.Equal(t, 3, gen.calls)
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must log giving-up exactly once when the 3rd failure spends the budget")

	// A 4th (and 5th) cycle the same day is a silent skip — no repeat log line.
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 1, strings.Count(buf.String(), "giving up"), "must not repeat the giving-up line on later silent skips the same day")
}

// TestDaemon_RollupBackoff_BenignSkipDoesNotConsumeBudget uses the "< 2
// channel digests" benign-skip arm specifically (dailyRollupNeeded is never
// even reached), per the report's warning: this is the arm an implementer is
// most likely to get wrong by gating *before* it, and the "!needed" arm alone
// would not distinguish a correct implementation from one that miscounts
// only the other benign returns.
func TestDaemon_RollupBackoff_BenignSkipDoesNotConsumeBudget(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))

	// Only ONE channel digest this time: dailyRollupNeeded's "< 2 channel
	// digests" arm returns nil before ever looking at existing daily rows.
	now := time.Now().UTC()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	dayEnd := dayStart.Add(24*time.Hour - time.Second)
	_, err = database.UpsertDigest(db.Digest{
		ChannelID:    "C1",
		Type:         "channel",
		PeriodFrom:   float64(dayStart.Unix()),
		PeriodTo:     float64(dayEnd.Unix()),
		Summary:      "some discussion",
		Topics:       `[]`,
		Decisions:    `[]`,
		ActionItems:  `[]`,
		MessageCount: 5,
	})
	require.NoError(t, err)

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, Language: "English"},
	}
	gen := &erroringGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetDigestPipeline(digest.New(database, cfg, gen, d.logger))

	for i := 0; i < 5; i++ {
		d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	}

	assert.Equal(t, 0, gen.calls, "a benign <2-channel-digests skip must never reach the AI generate call")
	assert.Equal(t, 0, d.rollupAttempts, "a benign skip must not consume any budget")
}

func TestDaemon_RollupBackoff_ResetsNextCalendarDay(t *testing.T) {
	d, _, gen := rollupBackoffTestSetup(t)

	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	require.Equal(t, 3, gen.calls)
	require.True(t, d.rollupAttemptsExhausted(rollupBudgetDate(rollupFixedNow)), "today's budget must be exhausted")

	// A new UTC calendar day is simulated by rewriting the in-memory attempt
	// date to the day before rollupFixedNow's own UTC date ("2026-09-14",
	// one day before the "2026-09-15" all three calls above recorded), the
	// shape the verification report names for this pipeline.
	d.rollupAttemptDate = "2026-09-14"

	// The new day must get its OWN full budget of 3, not just let one
	// straggler attempt through and then immediately re-exhaust because the
	// counter carried over from yesterday instead of resetting to 0 before
	// incrementing (a single extra call cannot tell "reset to a fresh 3"
	// apart from "kept counting from 3").
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 4, gen.calls, "a new calendar day must get a fresh budget and actually launch a real attempt")
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 5, gen.calls, "the new day's 2nd attempt must also launch — its budget must not have inherited yesterday's spent count")
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 6, gen.calls, "the new day's 3rd attempt must also launch")

	// Now the new day's own budget of 3 is spent — a 4th attempt the same day
	// must be refused again.
	d.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 6, gen.calls, "the new day's 4th cycle must launch nothing once ITS budget is spent")
}

// TestDaemon_RollupBackoff_SurvivesRestart is the test an in-memory-only
// counter could never pass: attempts recorded by one Daemon instance must
// still block a brand new Daemon instance (a simulated restart) pointed at
// the same workspace directory.
func TestDaemon_RollupBackoff_SurvivesRestart(t *testing.T) {
	d1, database, gen1 := rollupBackoffTestSetup(t)

	d1.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d1.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	d1.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	require.Equal(t, 3, gen1.calls)

	// Simulate a daemon restart: a brand new Daemon over the same
	// config/workspace and a fresh generator, restoring only what
	// loadRollupAttempts reads back from disk.
	d2 := newDaemon(nil, d1.config)
	d2.SetLogger(log.New(io.Discard, "", 0))
	d2.SetDB(database)
	gen2 := &erroringGenerator{}
	d2.SetDigestPipeline(digest.New(database, d1.config, gen2, d2.logger))
	d2.loadRollupAttempts()

	d2.phaseTracksAndRollups(context.Background(), rollupFixedNow)
	assert.Equal(t, 0, gen2.calls, "a restarted daemon must honor the already-spent budget instead of resetting it")
}
