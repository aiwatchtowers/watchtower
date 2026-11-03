package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	gosync "sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/sync"
)

// backfillGen answers every digest and rollup call with one small topic and
// records the prompts it was sent.
type backfillGen struct {
	mu      gosync.Mutex
	prompts []string
}

func (g *backfillGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, user)
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func (g *backfillGen) calls() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.prompts)
}

type backfillDigestFixture struct {
	db     *db.DB
	pipe   *digest.Pipeline
	gen    *backfillGen
	wsDir  string
	ledger *backfillLedger
}

func newBackfillDigestFixture(t *testing.T) *backfillDigestFixture {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test", Digest: config.DigestConfig{Enabled: true, MinMessages: 1}}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	gen := &backfillGen{}
	ledger, err := loadBackfillLedger(cfg.WorkspaceDir())
	require.NoError(t, err)
	return &backfillDigestFixture{db: database, pipe: digest.New(database, cfg, gen, log.New(io.Discard, "", 0)),
		gen: gen, wsDir: cfg.WorkspaceDir(), ledger: ledger}
}

// reload reads the ledger back from disk, as a new run of the command does.
func (f *backfillDigestFixture) reload(t *testing.T) {
	t.Helper()
	ledger, err := loadBackfillLedger(f.wsDir)
	require.NoError(t, err)
	f.ledger = ledger
}

// holdDigestLock takes the digest lock the way a daemon digest run does.
func (f *backfillDigestFixture) holdDigestLock(t *testing.T) (release func()) {
	t.Helper()
	lock, err := os.OpenFile(filepath.Join(f.wsDir, "digest.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	require.NoError(t, err)
	require.NoError(t, syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	return func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}
}

func seedBackfillMessage(t *testing.T, database *db.DB, channel string, at time.Time, text string) {
	t.Helper()
	require.NoError(t, database.UpsertChannel(db.Channel{ID: channel, Name: channel, Type: "public"}))
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: channel, TS: fmt.Sprintf("%d.000100", at.Unix()), UserID: "1:U1", Text: text,
	}))
}

func seedBackfillDigest(t *testing.T, database *db.DB, channel string, from, to time.Time) {
	t.Helper()
	_, err := database.UpsertDigest(db.Digest{ChannelID: channel, Type: "channel",
		PeriodFrom: float64(from.Unix()), PeriodTo: float64(to.Unix()), Summary: "old", Model: "m"})
	require.NoError(t, err)
}

func countDigests(t *testing.T, database *db.DB, where string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM digests WHERE `+where, args...).Scan(&n))
	return n
}

// gapFixture is three UTC days 20 days back:
//   - C1 held a message on day 1 and a digest covered it;
//   - C2 has a forward digest whose period spans every day but saw no
//     message of them (the first digest after a sync gap);
//   - C3 holds a message on day 3 that no digest covers.
//
// The fetch (fetchGap) brings day 1 news for C1 and day 2 news for C2.
type gapFixture struct {
	*backfillDigestFixture
	day1, day2, day3, from, to time.Time
}

func newGapFixture(t *testing.T) *gapFixture {
	t.Helper()
	f := &gapFixture{backfillDigestFixture: newBackfillDigestFixture(t)}
	f.day1 = time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	f.day2 = f.day1.Add(24 * time.Hour)
	f.day3 = f.day2.Add(24 * time.Hour)
	f.from, f.to = f.day1, f.day3.Add(24*time.Hour)
	seedBackfillMessage(t, f.db, "1:C1", f.day1.Add(time.Hour), "c1-old")
	seedBackfillDigest(t, f.db, "1:C1", f.day1, f.day1.Add(2*time.Hour))
	seedBackfillDigest(t, f.db, "1:C2", f.day1.Add(-24*time.Hour), f.to.Add(24*time.Hour))
	seedBackfillMessage(t, f.db, "1:C3", f.day3.Add(3*time.Hour), "c3-old")
	return f
}

func (f *gapFixture) freeze(t *testing.T) {
	t.Helper()
	require.NoError(t, freezeDigestedChannelDays(f.db, f.ledger, 1, f.from, f.to))
}

func (f *gapFixture) fetchGap(t *testing.T) {
	t.Helper()
	seedBackfillMessage(t, f.db, "1:C1", f.day1.Add(5*time.Hour), "c1-new")
	seedBackfillMessage(t, f.db, "1:C2", f.day2.Add(4*time.Hour), "c2-new")
}

func (f *gapFixture) digest(t *testing.T) (digests, rolled int, err error) {
	t.Helper()
	return backfillSlackDigests(context.Background(), f.db, f.pipe, f.ledger, 1, f.from, f.to)
}

func (f *gapFixture) dailyOn(t *testing.T, day time.Time) int {
	t.Helper()
	return countDigests(t, f.db, `type = 'daily' AND period_from >= ? AND period_from < ?`,
		float64(day.Unix()), float64(day.Add(24*time.Hour).Unix()))
}

// slack backfill never digests anything again (#915 owner decision): a
// channel day a digest already covered keeps its digest and gets only its
// messages; a channel day no digest saw is digested — including a day inside
// the period of a forward digest that spans a sync gap without having seen a
// message of it; a daily rollup is rebuilt only for a day that got a new
// digest.
func TestBackfillSlackDigests_OnlyWhatNoDigestCovered(t *testing.T) {
	f := newGapFixture(t)
	f.freeze(t)
	f.fetchGap(t)

	digests, rolled, err := f.digest(t)
	require.NoError(t, err)
	assert.Equal(t, 2, digests, "C2 on day 2, C3 on day 3")
	assert.Equal(t, 2, rolled, "days 2 and 3 got a new digest")
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C1'`), "C1's day 1 is not digested again")
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`))
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C3'`))
	assert.Zero(t, f.dailyOn(t, f.day1), "no rollup for a day without a new digest")
	assert.Equal(t, 1, f.dailyOn(t, f.day2))
	assert.Equal(t, 1, f.dailyOn(t, f.day3))
	for _, p := range f.gen.prompts {
		assert.NotContains(t, p, "c1-new", "a covered channel day never reaches a prompt")
	}

	// A second run of the command: nothing is digested or rolled up.
	f.reload(t)
	f.freeze(t)
	calls := f.gen.calls()
	digests, rolled, err = f.digest(t)
	require.NoError(t, err)
	assert.Zero(t, digests)
	assert.Zero(t, rolled)
	assert.Equal(t, calls, f.gen.calls(), "no AI call on a second run")
}

// The run that fetched the gap could not digest it (the daemon held the
// digest lock). By the rerun the gap messages are stored, yet the frozen
// decision still digests C2's gap day.
func TestBackfillSlackDigests_RerunAfterAHeldLockStillDigestsTheGap(t *testing.T) {
	f := newGapFixture(t)
	f.freeze(t)
	f.fetchGap(t)
	release := f.holdDigestLock(t)
	_, _, err := f.digest(t)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "run it again")
	release()

	f.reload(t)
	f.freeze(t) // a no-op: the days are already decided
	digests, _, err := f.digest(t)
	require.NoError(t, err)
	assert.Equal(t, 2, digests)
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`), "C2's gap day is digested on the rerun")
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C1'`))
}

// A day whose digests were written but whose rollup could not run is rolled
// up by the rerun, which writes no digest.
func TestBackfillSlackDigests_RerunRebuildsAPendingRollup(t *testing.T) {
	f := newGapFixture(t)
	f.freeze(t)
	f.fetchGap(t)
	day2 := f.ledger.Days[backfillLedgerKey(1, utcDayKey(f.day2))]
	require.NotNil(t, day2)
	// The first run wrote day 2's digest and stopped before its rollup.
	day2.RollupPending = true
	require.NoError(t, f.ledger.save())
	seedBackfillDigest(t, f.db, "1:C2", f.day2.Add(4*time.Hour-time.Minute), f.day2.Add(4*time.Hour))

	f.reload(t)
	_, rolled, err := f.digest(t)
	require.NoError(t, err)
	assert.Equal(t, 1, f.dailyOn(t, f.day2), "the pending rollup is rebuilt")
	assert.Equal(t, 2, rolled, "day 2 (pending) and day 3 (new digest)")
	assert.False(t, f.ledger.Days[backfillLedgerKey(1, utcDayKey(f.day2))].RollupPending)
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`), "no digest on top of the first run's")
}

func TestBackfillDays_SplitsOnUTCDaysClippedToTheChunk(t *testing.T) {
	from := time.Date(2026, 3, 10, 22, 0, 0, 0, time.UTC)
	to := from.Add(48 * time.Hour)
	days := backfillDays(from, to)
	require.Len(t, days, 3)
	assert.Equal(t, from, days[0][0])
	assert.Equal(t, time.Date(2026, 3, 11, 0, 0, 0, 0, time.UTC), days[0][1])
	assert.Equal(t, to, days[2][1])
}

// The whole command path with digests on: fetch, then the chunk's digest and
// its day's rollup; a second run fetches again but digests nothing.
func TestBackfillSlackRange_WithDigests(t *testing.T) {
	database, _ := slackBackfillEnv(t, "T_HOME")
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	cfg.Digest = config.DigestConfig{Enabled: true, MinMessages: 1}
	gen := &backfillGen{}
	pipe := digest.New(database, cfg, gen, log.New(io.Discard, "", 0))
	orch := sync.NewOrchestrator(database, newSlackClientForToken("xoxp-test"), cfg, 1)
	orch.SetLogger(log.New(io.Discard, "", 0))
	// The stub's one message is at 2026-03-13 12:00 UTC.
	floor := time.Date(2026, 3, 13, 0, 0, 0, 0, time.UTC)
	upper := floor.Add(24 * time.Hour)
	run := func() string {
		ledger, err := loadBackfillLedger(cfg.WorkspaceDir())
		require.NoError(t, err)
		var out bytes.Buffer
		require.NoError(t, backfillSlackRange(context.Background(), &out, database, orch, pipe, ledger, floor, upper))
		return out.String()
	}

	assert.Contains(t, run(), "1 messages, 1 digests, daily rollups run for 1 days")
	assert.Equal(t, 1, countDigests(t, database, `type = 'channel' AND channel_id = '1:C001'`))

	calls := gen.calls()
	assert.Contains(t, run(), "1 messages, 0 digests, daily rollups run for 0 days")
	assert.Equal(t, calls, gen.calls(), "the second run digests nothing")
}
