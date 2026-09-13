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
// Both day-plan and briefing route through the same recordX/xAttemptsExhausted
// pair backed by attemptMarker, so the exhaustion/reset arithmetic is pinned
// once here, deterministically (no wall-clock dependency), rather than
// duplicated per pipeline.

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
// pinned separately because the two record*Attempt functions are independent
// copies today and a future edit could diverge them silently otherwise.
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
