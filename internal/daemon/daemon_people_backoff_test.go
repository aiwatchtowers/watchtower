package daemon

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/guide"
)

// peopleBackoffTestSetup wires a people pipeline whose every AI call fails over
// TWO low-data users inside Run's 7-day window (plus a digest situation so the
// "no situations yet" benign skip does not fire) — so each phase call is a real
// failed attempt, not a benign skip.
func peopleBackoffTestSetup(t *testing.T) (*Daemon, *db.DB, *erroringGenerator) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(dir+"/.local/share/watchtower/test-ws", 0o755))

	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "general", Type: "public"}))

	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	base := dayStart.Add(-3 * 24 * time.Hour)
	for u, id := range []string{"U1", "U2"} {
		require.NoError(t, database.UpsertUser(db.User{ID: id, Name: id, DisplayName: id}))
		for i := range 4 {
			ts := float64(base.Add(time.Duration(u*100+i) * time.Minute).Unix())
			require.NoError(t, database.UpsertMessage(db.Message{
				ChannelID: "C1", TS: fmt.Sprintf("%.6f", ts), UserID: id, Text: "msg",
			}))
		}
	}
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(dayStart.Add(-4 * 24 * time.Hour).Unix()),
		PeriodTo:   float64(dayStart.Add(-2 * 24 * time.Hour).Unix()),
		Summary:    "d", Topics: "[]", Decisions: "[]", ActionItems: "[]", PeopleSignals: "[]",
		Situations:   `[{"topic":"X","type":"collaboration","participants":[{"user_id":"U3","role":"lead"}],"dynamic":"d","outcome":"o","red_flags":[],"observations":[],"message_refs":[]}]`,
		MessageCount: 8,
	})
	require.NoError(t, err)

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, MinMessages: 1},
		People:          config.PeopleConfig{Enabled: true},
	}
	gen := &erroringGenerator{}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetPeoplePipeline(guide.New(database, cfg, gen, d.logger))
	return d, database, gen
}

// A failed people run does not stamp the 24h throttle, so without a budget an
// AI outage re-ran every batch on every cycle. Three real failures spend the
// day's budget; a 4th cycle launches nothing and the give-up line logs once.
func TestDaemon_PeopleBackoff_ThreeFailuresExhaustBudget(t *testing.T) {
	d, _, gen := peopleBackoffTestSetup(t)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))

	for i := 0; i < maxDailyAIAttempts; i++ {
		d.phasePeopleCards(context.Background())
	}
	require.Equal(t, maxDailyAIAttempts, gen.calls, "each failed cycle reaches the AI once (one batch of two users)")
	assert.True(t, d.lastPeople.IsZero(), "a failed run must not stamp the throttle")
	assert.Equal(t, 1, strings.Count(buf.String(), "people: giving up"))

	d.phasePeopleCards(context.Background())
	d.phasePeopleCards(context.Background())
	assert.Equal(t, maxDailyAIAttempts, gen.calls, "the spent budget launches nothing more today")
	assert.Equal(t, 1, strings.Count(buf.String(), "people: giving up"), "no repeat give-up line")
}

// A shutdown mid-run is not a failed attempt.
func TestDaemon_PeopleBackoff_ShutdownDoesNotConsumeBudget(t *testing.T) {
	d, _, _ := peopleBackoffTestSetup(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	for i := 0; i < 5; i++ {
		d.phasePeopleCards(ctx)
	}
	assert.Equal(t, 0, d.peopleAttempts, "a cancelled run must not be charged")
	assert.True(t, d.lastPeople.IsZero(), "an interrupted run must not stamp the throttle")
}

// The budget is persisted: a restarted daemon honors an already-spent budget.
func TestDaemon_PeopleBackoff_SurvivesRestart(t *testing.T) {
	d1, database, gen1 := peopleBackoffTestSetup(t)
	for i := 0; i < maxDailyAIAttempts; i++ {
		d1.phasePeopleCards(context.Background())
	}
	require.Equal(t, maxDailyAIAttempts, gen1.calls)

	d2 := newDaemon(nil, d1.config)
	d2.SetLogger(log.New(io.Discard, "", 0))
	d2.SetDB(database)
	gen2 := &erroringGenerator{}
	d2.SetPeoplePipeline(guide.New(database, d1.config, gen2, d2.logger))
	d2.loadPeopleAttempts()

	d2.phasePeopleCards(context.Background())
	assert.Equal(t, 0, gen2.calls)
}

// A new calendar day gets a fresh budget of three.
func TestDaemon_PeopleBackoff_ResetsNextCalendarDay(t *testing.T) {
	d, _, gen := peopleBackoffTestSetup(t)
	for i := 0; i < maxDailyAIAttempts; i++ {
		d.phasePeopleCards(context.Background())
	}
	require.Equal(t, maxDailyAIAttempts, gen.calls)

	d.peopleAttemptDate = time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	for i := 0; i < maxDailyAIAttempts+1; i++ {
		d.phasePeopleCards(context.Background())
	}
	assert.Equal(t, 2*maxDailyAIAttempts, gen.calls, "the new day's own full budget, then nothing")
}
