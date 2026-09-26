package daemon

import (
	"bytes"
	"context"
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
	"watchtower/internal/inbox"
)

// noOwnerDaemon is a daemon over a workspace DB with no connected account,
// logging into the returned buffer.
func noOwnerDaemon(t *testing.T, cfg *config.Config) (*Daemon, *db.DB, *bytes.Buffer) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))
	database := db.OpenTestDB(t)

	cfg.ActiveWorkspace = "test-ws"
	d := newDaemon(nil, cfg)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))
	d.SetDB(database)
	return d, database, &buf
}

// TestOwner02_DaemonDayPlanNoOwnerLoggedOncePerUTCDay pins the daemon half of
// OWNER-02: a no-owner skip is visible in the log, but once per UTC day per
// phase — not once per 15-minute cycle. The conflict phase shares the day
// plan's line.
func TestOwner02_DaemonDayPlanNoOwnerLoggedOncePerUTCDay(t *testing.T) {
	d, _, buf := noOwnerDaemon(t, &config.Config{DayPlan: config.DayPlanConfig{Enabled: true, Hour: 1}})
	fp := &fakeDayPlanRunner{}
	d.SetDayPlanPipeline(fp)
	const line = "daemon: day_plan skipped: no owner identity (connect Slack, Google or Jira)"

	day1 := time.Date(2026, 4, 23, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		d.runDayPlanPhases(context.Background(), day1.Add(time.Duration(i)*time.Hour))
	}
	assert.Equal(t, 1, strings.Count(buf.String(), line), "three cycles on one UTC day log one line")

	d.runDayPlanPhases(context.Background(), day1.AddDate(0, 0, 1))
	assert.Equal(t, 2, strings.Count(buf.String(), line), "the next UTC day logs one more")
	assert.Equal(t, 0, fp.runCalls, "no owner never reaches Run")
	assert.Equal(t, 0, d.dayPlanAttempts, "no owner consumes no budget")
}

// TestOwner02_DaemonBriefingNoOwnerIsBenignAndLoggedOnce: no owner is a
// benign skip in the daemon — no budget charge, no generate call, no
// pipeline_runs row, and one log line however many cycles run the same day.
func TestOwner02_DaemonBriefingNoOwnerIsBenignAndLoggedOnce(t *testing.T) {
	if time.Now().Hour() < 1 {
		t.Skip("hour is below briefing threshold")
	}
	cfg := &config.Config{
		Digest:   config.DigestConfig{Enabled: true, Language: "English"},
		Briefing: config.BriefingConfig{Enabled: true, Hour: 1},
	}
	d, database, buf := noOwnerDaemon(t, cfg)
	gen := &erroringGenerator{}
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, d.logger))

	for i := 0; i < 3; i++ {
		d.phaseBriefing(context.Background())
	}

	assert.Equal(t, 1, strings.Count(buf.String(), "daemon: briefing skipped: no owner identity (connect Slack, Google or Jira)"))
	assert.NotContains(t, buf.String(), "briefing error", "no owner is not logged as a failure")
	assert.Equal(t, 0, gen.calls)
	assert.Equal(t, 0, d.briefingAttempts)
	var runs int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'briefing'`).Scan(&runs))
	assert.Equal(t, 0, runs, "a no-owner skip is not a pipeline run")
}

// A real owner-lookup error is a signal and is logged — once per cycle, not
// once per day-plan phase: the owner is resolved once for both phases.
func TestDaemon_DayPlanOwnerLookupErrorLoggedOncePerCycle(t *testing.T) {
	d, database, buf := noOwnerDaemon(t, &config.Config{DayPlan: config.DayPlanConfig{Enabled: true, Hour: 1}})
	fp := &fakeDayPlanRunner{}
	d.SetDayPlanPipeline(fp)
	require.NoError(t, database.Close()) // every query now errors

	d.runDayPlanPhases(context.Background(), time.Date(2026, 4, 23, 10, 0, 0, 0, time.UTC))

	assert.Equal(t, 1, strings.Count(buf.String(), "dayplan: resolving owner:"))
	assert.NotContains(t, buf.String(), "no owner identity", "a lookup error is not a missing owner")
	assert.Equal(t, 0, fp.runCalls)
}

// TestOwner02_DaemonInboxNoOwnerLoggedOncePerUTCDay: a no-owner install skips
// the inbox phase with one log line per UTC day, not one per cycle, and never
// records a pipeline run for the skip.
func TestOwner02_DaemonInboxNoOwnerLoggedOncePerUTCDay(t *testing.T) {
	cfg := &config.Config{Inbox: config.InboxConfig{Enabled: true}}
	d, database, buf := noOwnerDaemon(t, cfg)
	d.SetInboxPipeline(inbox.New(database, cfg, nil, d.logger))

	for i := 0; i < 3; i++ {
		d.phaseInbox(context.Background())
	}

	assert.Equal(t, 1, strings.Count(buf.String(), "daemon: inbox skipped: no owner identity (connect Slack, Google or Jira)"))
	var runs int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'inbox'`).Scan(&runs))
	assert.Equal(t, 0, runs, "a no-owner skip is not a pipeline run")
}

// TestOwner01_DaemonInboxUsesResolvedOwnerEmail: the daemon hands the inbox
// the resolver's owner — on a Google-only install its email reaches the
// Calendar detector (the old hand-rolled Slack→Google email fallback is gone;
// the resolver is the fallback).
func TestOwner01_DaemonInboxUsesResolvedOwnerEmail(t *testing.T) {
	cfg := &config.Config{Inbox: config.InboxConfig{Enabled: true, InitialLookbackDays: 7}}
	d, database, _ := noOwnerDaemon(t, cfg)
	_, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", CalendarEnabled: true})
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO calendar_calendars (id, name, is_primary, is_selected, color, synced_at)
		VALUES ('cal-1', 'Cal', 1, 1, '#000', '2026-01-01T00:00:00Z')`)
	require.NoError(t, err)
	now := time.Now().UTC()
	_, err = database.Exec(`INSERT INTO calendar_events
		(id, calendar_id, title, attendees, event_status, synced_at, updated_at, start_time, end_time,
		 description, location, organizer_email, is_recurring, is_all_day, event_type, html_link, raw_json)
		VALUES ('evt-1', 'cal-1', 'Planning', '[{"email":"me@x.com","rsvp_status":"needsAction"}]', 'confirmed',
		        ?, ?, ?, ?, '', '', '', 0, 0, '', '', '{}')`,
		now.Add(-10*time.Minute).Format(time.RFC3339), now.Add(-10*time.Minute).Format(time.RFC3339),
		now.Add(time.Hour).Format(time.RFC3339), now.Add(2*time.Hour).Format(time.RFC3339))
	require.NoError(t, err)
	d.SetInboxPipeline(inbox.New(database, cfg, nil, d.logger))

	d.phaseInbox(context.Background())

	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type = 'calendar_invite'`).Scan(&n))
	assert.Equal(t, 1, n)
}

// An owner-lookup error in the inbox phase is reported once per cycle (as the
// phase's own error), not once by the daemon and again by Run.
func TestDaemon_InboxOwnerLookupErrorLoggedOncePerCycle(t *testing.T) {
	cfg := &config.Config{Inbox: config.InboxConfig{Enabled: true}}
	d, database, buf := noOwnerDaemon(t, cfg)
	d.SetInboxPipeline(inbox.New(database, cfg, nil, d.logger))
	require.NoError(t, database.Close()) // every query now errors

	d.phaseInbox(context.Background())

	lines := 0
	for _, l := range strings.Split(buf.String(), "\n") {
		if strings.Contains(l, "resolving owner") {
			lines++
		}
	}
	assert.Equal(t, 1, lines, buf.String())
	assert.NotContains(t, buf.String(), "no owner identity", "a lookup error is not a missing owner")
}
