package daemon

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/guide"
)

// firstRunTestSetup wires a daemon over an empty database in a temp HOME
// workspace, the state of a fresh install's first cycle. Seed data with the
// seedFirstRun* helpers and attach the pipelines the test needs.
func firstRunTestSetup(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	require.NoError(t, os.MkdirAll(dir+"/.local/share/watchtower/test-ws", 0o755))

	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-ws", Domain: "test-ws"}))

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Digest:          config.DigestConfig{Enabled: true, MinMessages: 1},
		People:          config.PeopleConfig{Enabled: true},
	}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	return d, database
}

// firstRunDayStart is the start of today: people Run's window ends here.
func firstRunDayStart() time.Time {
	now := time.Now()
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
}

// seedFirstRunMessages seeds U1 and U2 as active users inside people Run's
// 7-day window.
func seedFirstRunMessages(t *testing.T, database *db.DB) {
	t.Helper()
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "general", Type: "public"}))
	base := firstRunDayStart().Add(-3 * 24 * time.Hour)
	for u, id := range []string{"U1", "U2"} {
		require.NoError(t, database.UpsertUser(db.User{ID: id, Name: id, DisplayName: id}))
		for i := range 4 {
			ts := float64(base.Add(time.Duration(u*100+i) * time.Minute).Unix())
			require.NoError(t, database.UpsertMessage(db.Message{
				ChannelID: "C1", TS: fmt.Sprintf("%.6f", ts), UserID: id, Text: "msg",
			}))
		}
	}
}

// seedFirstRunSituation seeds a channel digest carrying a situation, what the
// first digest run leaves for people cards to mine.
func seedFirstRunSituation(t *testing.T, database *db.DB) {
	t.Helper()
	dayStart := firstRunDayStart()
	_, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(dayStart.Add(-4 * 24 * time.Hour).Unix()),
		PeriodTo:   float64(dayStart.Add(-2 * 24 * time.Hour).Unix()),
		Summary:    "d", Topics: "[]", Decisions: "[]", ActionItems: "[]", PeopleSignals: "[]",
		Situations:   `[{"topic":"X","type":"collaboration","participants":[{"user_id":"U1","role":"lead"}],"dynamic":"d","outcome":"o","red_flags":[],"observations":[],"message_refs":[]}]`,
		MessageCount: 8,
	})
	require.NoError(t, err)
}

// peopleCardsGenerator answers every people batch with a card for U1 and U2.
type peopleCardsGenerator struct {
	calls int
}

func (g *peopleCardsGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	card := `{"user_id":%q,"summary":"s","communication_style":"","decision_role":"","red_flags":[],"highlights":[],"accomplishments":[],"communication_guide":"","decision_style":"","tactics":[]}`
	return "[" + fmt.Sprintf(card, "U1") + "," + fmt.Sprintf(card, "U2") + "]", &digest.Usage{}, "", nil
}

func attachPeoplePipeline(d *Daemon, database *db.DB) *peopleCardsGenerator {
	gen := &peopleCardsGenerator{}
	d.SetPeoplePipeline(guide.New(database, d.config, gen, d.logger))
	return gen
}

func TestDaemon_PeopleNoDataRunDoesNotStamp(t *testing.T) {
	d, database := firstRunTestSetup(t)
	attachPeoplePipeline(d, database)

	d.phasePeopleCards(context.Background())

	assert.True(t, d.lastPeople.IsZero(), "a no-data run must not start the 24 h throttle")
	_, err := os.Stat(d.lastPeoplePath())
	assert.True(t, os.IsNotExist(err), "a no-data run must not write last_people.txt")
}

func TestDaemon_PeopleNoDataRecordsNoAttempt(t *testing.T) {
	d, database := firstRunTestSetup(t)
	attachPeoplePipeline(d, database)

	d.phasePeopleCards(context.Background())

	assert.Equal(t, 0, d.peopleAttempts, "a no-data run is not a failed attempt")
	d.loadPeopleAttempts()
	assert.Equal(t, 0, d.peopleAttempts, "nothing persisted to people_attempts.txt")
}

func TestDaemon_PeopleNoDataRetriesNextCycle(t *testing.T) {
	d, database := firstRunTestSetup(t)
	seedFirstRunMessages(t, database)
	gen := attachPeoplePipeline(d, database)

	d.phasePeopleCards(context.Background())
	require.Equal(t, 0, gen.calls, "no situations yet: the AI is not reached")
	require.True(t, d.lastPeople.IsZero())

	seedFirstRunSituation(t, database)
	d.phasePeopleCards(context.Background())

	assert.Positive(t, gen.calls, "the next cycle with situations generates cards")
	assert.False(t, d.lastPeople.IsZero(), "the generating run stamps the throttle")
}

func TestDaemon_PeopleCoveredRunStamps(t *testing.T) {
	d, database := firstRunTestSetup(t)
	seedFirstRunMessages(t, database)
	seedFirstRunSituation(t, database)
	gen := attachPeoplePipeline(d, database)
	d.phasePeopleCards(context.Background())
	require.Positive(t, gen.calls)

	// A restart without last_people.txt: every user already has a card.
	d.lastPeople = time.Time{}
	require.NoError(t, os.Remove(d.lastPeoplePath()))
	calls := gen.calls
	d.phasePeopleCards(context.Background())

	assert.Equal(t, calls, gen.calls, "a covered window reaches no AI")
	assert.False(t, d.lastPeople.IsZero(), "a covered window stamps the throttle")
}

func TestDaemon_PeopleGeneratedRunStamps(t *testing.T) {
	d, database := firstRunTestSetup(t)
	seedFirstRunMessages(t, database)
	seedFirstRunSituation(t, database)
	gen := attachPeoplePipeline(d, database)

	d.phasePeopleCards(context.Background())

	require.Positive(t, gen.calls)
	assert.False(t, d.lastPeople.IsZero())
	_, err := os.Stat(d.lastPeoplePath())
	assert.NoError(t, err, "last_people.txt is written")
}

func peopleRunCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'people'`).Scan(&n))
	return n
}

// A workspace that stays without data must not write an empty "people" row
// every cycle. Both no-data shapes: no active users, then users without
// situations.
func TestDaemon_PeopleNoDataRunLeavesNoPipelineRun(t *testing.T) {
	d, database := firstRunTestSetup(t)
	gen := attachPeoplePipeline(d, database)

	d.phasePeopleCards(context.Background())
	seedFirstRunMessages(t, database)
	d.phasePeopleCards(context.Background())

	assert.Equal(t, 0, peopleRunCount(t, database))
	assert.Equal(t, 0, gen.calls)

	seedFirstRunSituation(t, database)
	d.phasePeopleCards(context.Background())
	assert.Equal(t, 1, peopleRunCount(t, database), "the first cycle with data is tracked")
}
