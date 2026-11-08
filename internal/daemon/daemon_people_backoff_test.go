package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/guide"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
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

	for range maxDailyAIAttempts {
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

	for range 5 {
		d.phasePeopleCards(ctx)
	}
	assert.Equal(t, 0, d.peopleAttempts, "a cancelled run must not be charged")
	assert.True(t, d.lastPeople.IsZero(), "an interrupted run must not stamp the throttle")
}

// The budget is persisted: a restarted daemon honors an already-spent budget.
func TestDaemon_PeopleBackoff_SurvivesRestart(t *testing.T) {
	d1, database, gen1 := peopleBackoffTestSetup(t)
	for range maxDailyAIAttempts {
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
	for range maxDailyAIAttempts {
		d.phasePeopleCards(context.Background())
	}
	require.Equal(t, maxDailyAIAttempts, gen.calls)

	d.peopleAttemptDate = time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	for range maxDailyAIAttempts + 1 {
		d.phasePeopleCards(context.Background())
	}
	assert.Equal(t, 2*maxDailyAIAttempts, gen.calls, "the new day's own full budget, then nothing")
}

// Both the metadata-only wait and quota discovered by real router attempts
// preserve the on-disk poison budget, including its old calendar date.
func TestDaemon_PeopleProviderDeferredPreservesPersistentMarkers(t *testing.T) {
	for _, known := range []bool{true, false} {
		t.Run(fmt.Sprintf("known=%v", known), func(t *testing.T) {
			d, database, _ := peopleBackoffTestSetup(t)
			cfg := d.config
			cfg.AI.Provider = "claude"
			cfg.AI.Fallback.Enabled = true
			cfg.AI.Fallback.Provider = "codex"
			store := providerhealth.New(t.TempDir(), nil)
			if known {
				for _, p := range []string{"claude", "codex"} {
					require.NoError(t, store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}))
				}
			}
			calls := 0
			factory := func(p string) digest.Generator {
				return deferredPeopleLeaf{call: func() error { calls++; return &providers.Failure{Provider: p, Category: providers.Quota} }}
			}
			gen := providerrouting.WrapGenerator(cfg, factory("claude"), factory, providerrouting.GeneratorOptions{Router: &providerrouting.Router{Health: store, Allowed: func(string) error { return nil }}})
			d.SetPeoplePipeline(guide.New(database, cfg, gen, d.logger))
			oldDate := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
			require.NoError(t, saveAttemptMarker(d.peopleAttemptsPath(), attemptMarker{date: oldDate, attempts: 2}))
			d.loadPeopleAttempts()
			before, err := os.ReadFile(d.peopleAttemptsPath())
			require.NoError(t, err)
			d.phasePeopleCards(context.Background())
			after, err := os.ReadFile(d.peopleAttemptsPath())
			require.NoError(t, err)
			require.Equal(t, before, after)
			require.Equal(t, oldDate, d.peopleAttemptDate)
			require.Equal(t, 2, d.peopleAttempts)
			require.True(t, d.lastPeople.IsZero())
			_, err = os.Stat(d.lastPeoplePath())
			require.ErrorIs(t, err, os.ErrNotExist)
			for _, id := range []string{"U1", "U2"} {
				card, err := database.GetLatestPeopleCard(id)
				require.NoError(t, err)
				require.Nil(t, card)
			}
			if known {
				require.Zero(t, calls)
				var rows int
				require.NoError(t, database.QueryRow("SELECT count(*) FROM pipeline_runs WHERE pipeline='people'").Scan(&rows))
				require.Zero(t, rows)
			} else {
				require.Equal(t, 2, calls)
				require.Equal(t, guide.OutcomeDeferred, d.peoplePipe.LastOutcome())
			}
			restarted := newDaemon(nil, cfg)
			restarted.loadPeopleAttempts()
			require.Equal(t, oldDate, restarted.peopleAttemptDate)
			require.Equal(t, 2, restarted.peopleAttempts)
		})
	}
}

type deferredPeopleLeaf struct{ call func() error }

func (g deferredPeopleLeaf) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	return "", nil, "", g.call()
}

type successfulPeopleLeaf struct{ batchCalls int }

func (g *successfulPeopleLeaf) RoutingPreflight(context.Context) error { return nil }
func (g *successfulPeopleLeaf) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	source, _ := digest.SourceFromContext(ctx)
	if source != "people.batch" {
		return `{"summary":"team"}`, nil, "", nil
	}
	g.batchCalls++
	return `[{"user_id":"U1","summary":"summary"},{"user_id":"U2","summary":"summary"}]`, nil, "", nil
}
func TestDaemon_PeopleStampFailureKeepsPendingWindowAndMemory(t *testing.T) {
	d, database, _ := peopleBackoffTestSetup(t)
	gen := &successfulPeopleLeaf{}
	d.SetPeoplePipeline(guide.New(database, d.config, gen, d.logger))
	// An existing directory makes the final atomic rename fail without touching
	// permissions or depending on running as a particular OS user.
	require.NoError(t, os.Mkdir(d.lastPeoplePath(), 0o700))
	d.phasePeopleCards(context.Background())
	require.True(t, d.lastPeople.IsZero(), "a failed stamp must not advance the in-memory throttle")
	require.Zero(t, d.peopleAttempts, "a stamp write failure is not poisoned input")
	require.Equal(t, 1, gen.batchCalls)
	pendingPath := filepath.Join(d.config.WorkspaceDir(), "people_pending_window.json")
	before, err := os.ReadFile(pendingPath)
	require.NoError(t, err)
	var status string
	require.NoError(t, database.QueryRow("SELECT status FROM pipeline_runs WHERE pipeline='people' ORDER BY id DESC LIMIT 1").Scan(&status))
	require.Equal(t, "error", status)
	require.NoError(t, os.Remove(d.lastPeoplePath()))
	restarted := newDaemon(nil, d.config)
	restarted.SetLogger(d.logger)
	restarted.SetDB(database)
	restarted.SetPeoplePipeline(guide.New(database, d.config, gen, d.logger))
	restarted.phasePeopleCards(context.Background())
	require.Equal(t, 1, gen.batchCalls, "committed cards must not be regenerated after stamp failure")
	require.False(t, restarted.lastPeople.IsZero())
	_, err = os.Stat(pendingPath)
	require.ErrorIs(t, err, os.ErrNotExist)
	var descriptor struct{ StartedAt time.Time }
	require.NoError(t, json.Unmarshal(before, &descriptor))
	require.Equal(t, descriptor.StartedAt, restarted.lastPeople)
}
