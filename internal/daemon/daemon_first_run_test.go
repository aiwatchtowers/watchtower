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

	"watchtower/internal/briefing"
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

// firstRunClock is today at the given local hour: a fixed clock for the
// briefing and day-plan gates, never a hard-coded date.
func firstRunClock(hour int) time.Time {
	return firstRunDayStart().Add(time.Duration(hour) * time.Hour)
}

// briefingFirstRunSetup is a fresh-install daemon with briefings on at 08:00.
func briefingFirstRunSetup(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	d, database := firstRunTestSetup(t)
	d.config.Briefing = config.BriefingConfig{Enabled: true, Hour: 8}
	return d, database
}

func seedFirstRunBriefing(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.UpsertBriefing(db.Briefing{
		WorkspaceID: "T1", UserID: "U1", Date: firstRunDayStart().AddDate(0, 0, -1).Format("2006-01-02"),
	})
	require.NoError(t, err)
}

func TestShouldRunBriefingAt_FreshInstallIgnoresHour(t *testing.T) {
	d, _ := briefingFirstRunSetup(t)

	assert.True(t, d.shouldRunBriefingAt(firstRunClock(6)), "the first briefing does not wait for briefing.hour")
}

func TestShouldRunBriefingAt_HourGateAppliesAfterFirst(t *testing.T) {
	d, database := briefingFirstRunSetup(t)
	seedFirstRunBriefing(t, database)

	assert.False(t, d.shouldRunBriefingAt(firstRunClock(6)))
	assert.True(t, d.shouldRunBriefingAt(firstRunClock(9)))
}

func TestShouldRunBriefingAt_StampWipedRowsExistKeepsHourGate(t *testing.T) {
	d, database := briefingFirstRunSetup(t)
	seedFirstRunBriefing(t, database)
	require.True(t, d.lastBriefing.IsZero())

	assert.False(t, d.shouldRunBriefingAt(firstRunClock(6)), "a lost last_briefing.txt is not a fresh install")
}

func TestShouldRunBriefingAt_NilDBIsNotFresh(t *testing.T) {
	d := newQuietDaemon(t)
	d.config.Briefing = config.BriefingConfig{Enabled: true, Hour: 8}

	assert.False(t, d.shouldRunBriefingAt(firstRunClock(6)))
}

func TestShouldRunBriefingAt_FreshButBudgetExhaustedFalse(t *testing.T) {
	d, _ := briefingFirstRunSetup(t)
	now := firstRunClock(6)
	for range maxDailyAIAttempts {
		d.recordBriefingAttempt(now.Format("2006-01-02"))
	}

	assert.False(t, d.shouldRunBriefingAt(now))
}

// The fresh-install bypass adds no run: a first briefing with nothing to
// summarise yet is a benign skip that keeps the budget and the stamp clear,
// so the next cycle tries again. phaseBriefing reads time.Now(), so after
// briefing.hour this covers the no-data path only; the bypass itself is pinned
// by the shouldRunBriefingAt tests above.
func TestDaemon_FirstBriefingNoDataKeepsBudget(t *testing.T) {
	d, database := briefingFirstRunSetup(t)
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: "alice", DisplayName: "Alice"}))
	gen := &erroringGenerator{}
	d.SetBriefingPipeline(briefing.New(database, d.config, gen, d.logger))

	d.phaseBriefing(context.Background())

	assert.Equal(t, 0, gen.calls, "no digests: the AI is not reached")
	assert.Equal(t, 0, d.briefingAttempts)
	assert.True(t, d.lastBriefing.IsZero())
	assert.True(t, d.shouldRunBriefingAt(firstRunClock(6)), "still fresh on the next cycle")
}

// dayPlanFirstRunSetup is a fresh-install daemon with the day plan on at
// 08:00 and a runner that is never asked to generate by these gate tests.
func dayPlanFirstRunSetup(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	d, database := firstRunTestSetup(t)
	d.config.DayPlan = config.DayPlanConfig{Enabled: true, Hour: 8}
	d.SetDayPlanPipeline(&fakeDayPlanRunner{database: database})
	return d, database
}

var firstRunOwner = db.Owner{ID: "U001", Source: db.OwnerSourceSlack, SlackUserID: "U001"}

func TestShouldRunDayPlan_FreshInstallIgnoresHour(t *testing.T) {
	d, _ := dayPlanFirstRunSetup(t)

	assert.True(t, d.shouldRunDayPlan(firstRunClock(6), firstRunOwner), "the first day plan does not wait for day_plan.hour")
}

func TestShouldRunDayPlan_HourGateAppliesAfterFirst(t *testing.T) {
	d, database := dayPlanFirstRunSetup(t)
	_, err := database.CreateDayPlan(&db.DayPlan{
		UserID: firstRunOwner.ID, PlanDate: firstRunDayStart().AddDate(0, 0, -1).Format("2006-01-02"),
		Status: db.DayPlanStatusActive, GeneratedAt: time.Now(),
	})
	require.NoError(t, err)

	assert.False(t, d.shouldRunDayPlan(firstRunClock(6), firstRunOwner))
}

func TestShouldRunDayPlan_FreshUnknownOwnerFalse(t *testing.T) {
	d, _ := dayPlanFirstRunSetup(t)

	assert.False(t, d.shouldRunDayPlan(firstRunClock(6), db.Owner{}), "no owner stays a benign skip")
}

func TestShouldRunDayPlan_FreshBudgetExhaustedFalse(t *testing.T) {
	d, _ := dayPlanFirstRunSetup(t)
	now := firstRunClock(6)
	for range maxDailyAIAttempts {
		d.recordDayPlanAttempt(now.Format("2006-01-02"))
	}

	assert.False(t, d.shouldRunDayPlan(now, firstRunOwner))
}
