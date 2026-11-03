package slackbackfill

import (
	"bytes"
	"context"
	"errors"
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

// recGen answers every digest and rollup call with one small topic, records
// the prompts it was sent, and fails its failOn-th call (1-based; 0 never).
type recGen struct {
	mu      gosync.Mutex
	prompts []string
	failOn  int
}

func (g *recGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, user)
	if g.failOn == len(g.prompts) {
		return "", nil, "", errors.New("model unavailable")
	}
	return `{"summary":"s","topics":[{"title":"t","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":[]}]}`,
		&digest.Usage{Model: "m", InputTokens: 1, OutputTokens: 1}, "", nil
}

func (g *recGen) calls() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.prompts)
}

// fakeFetcher stands in for BackfillSearch: each call runs onFetch (the
// messages "Slack" returns for the chunk) and records the chunk.
type fakeFetcher struct {
	id      int64
	onFetch func(from, to time.Time) error
	chunks  [][2]time.Time
}

func (f *fakeFetcher) AccountID() int64 { return f.id }

func (f *fakeFetcher) BackfillSearch(_ context.Context, from, to time.Time) (int, error) {
	f.chunks = append(f.chunks, [2]time.Time{from, to})
	if f.onFetch != nil {
		return 0, f.onFetch(from, to)
	}
	return 0, nil
}

type fixture struct {
	db    *db.DB
	pipe  *digest.Pipeline
	gen   *recGen
	wsDir string
	fetch *fakeFetcher
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test", Digest: config.DigestConfig{Enabled: true, MinMessages: 1}}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	gen := &recGen{}
	return &fixture{db: database, pipe: digest.New(database, cfg, gen, log.New(io.Discard, "", 0)),
		gen: gen, wsDir: cfg.WorkspaceDir(), fetch: &fakeFetcher{id: 1}}
}

// newRun is one command run: the ledger is read back from disk.
func (f *fixture) newRun(t *testing.T, digests bool) *Run {
	t.Helper()
	ledger, err := LoadLedger(f.wsDir)
	require.NoError(t, err)
	r := &Run{DB: f.db, Fetch: f.fetch, Ledger: ledger, Out: &bytes.Buffer{}}
	if digests {
		r.Digest = f.pipe
	}
	return r
}

func (f *fixture) runRange(t *testing.T, floor, upper time.Time) error {
	t.Helper()
	return f.newRun(t, true).Range(context.Background(), floor, upper)
}

func (f *fixture) holdDigestLock(t *testing.T) (release func()) {
	t.Helper()
	lock, err := os.OpenFile(filepath.Join(f.wsDir, "digest.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	require.NoError(t, err)
	require.NoError(t, syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	return func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}
}

func (f *fixture) ledgerDay(t *testing.T, accountID int64, day time.Time) *ledgerDay {
	t.Helper()
	ledger, err := LoadLedger(f.wsDir)
	require.NoError(t, err)
	return ledger.Days[ledgerKey(accountID, utcDayKey(day))]
}

func seedMessage(t *testing.T, database *db.DB, channel string, at time.Time, text string) {
	t.Helper()
	require.NoError(t, database.UpsertChannel(db.Channel{ID: channel, Name: channel, Type: "public"}))
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: channel, TS: fmt.Sprintf("%d.000100", at.Unix()), UserID: "1:U1", Text: text,
	}))
}

func seedDigest(t *testing.T, database *db.DB, channel string, from, to time.Time) {
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

func dailyOn(t *testing.T, database *db.DB, day time.Time) int {
	t.Helper()
	return countDigests(t, database, `type = 'daily' AND period_from >= ? AND period_from < ?`,
		float64(day.Unix()), float64(day.Add(24*time.Hour).Unix()))
}

func useLocal(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	require.NoError(t, err)
	orig := time.Local
	time.Local = loc
	t.Cleanup(func() { time.Local = orig })
	return loc
}

// gapFixture is three UTC days 20 days back:
//   - C1 held a message on day 1 and a digest ending 2 h into the day covered
//     it; that digest is C1's forward mark;
//   - C2 has a forward digest whose period spans every day but saw no
//     message of them (the first digest after a sync gap);
//   - C3 holds a message on day 3 that no digest covers.
//
// The first fetch brings day 1 news for C1 (above its forward mark) and
// day 2 news for C2.
type gapFixture struct {
	*fixture
	day1, day2, day3, from, to time.Time
}

func newGapFixture(t *testing.T) *gapFixture {
	t.Helper()
	f := &gapFixture{fixture: newFixture(t)}
	f.day1 = time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	f.day2 = f.day1.Add(24 * time.Hour)
	f.day3 = f.day2.Add(24 * time.Hour)
	f.from, f.to = f.day1, f.day3.Add(24*time.Hour)
	seedMessage(t, f.db, "1:C1", f.day1.Add(time.Hour), "c1-old")
	seedDigest(t, f.db, "1:C1", f.day1, f.day1.Add(2*time.Hour))
	seedDigest(t, f.db, "1:C2", f.day1.Add(-24*time.Hour), f.to.Add(24*time.Hour))
	seedMessage(t, f.db, "1:C3", f.day3.Add(3*time.Hour), "c3-old")
	fetched := false
	f.fetch.onFetch = func(_, _ time.Time) error {
		if !fetched {
			fetched = true
			seedMessage(t, f.db, "1:C1", f.day1.Add(5*time.Hour), "c1-new")
			seedMessage(t, f.db, "1:C2", f.day2.Add(4*time.Hour), "c2-new")
		}
		return nil
	}
	return f
}

// slack backfill never digests anything again (#915 owner decision) and
// never above a channel's forward mark (M2): C1's new message lies above its
// forward digest and is left to the forward digest; C2's gap day is
// digested although a forward digest's period spans it; C3's day is
// digested; a daily rollup is rebuilt only for a day that got a new digest.
func TestRange_DigestsOnlyWhatNoDigestCovered(t *testing.T) {
	f := newGapFixture(t)
	require.NoError(t, f.runRange(t, f.from, f.to))

	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C1'`), "C1's news is the forward digest's")
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`), "C2's gap day is digested")
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C3'`))
	assert.Zero(t, dailyOn(t, f.db, f.day1), "no rollup for a day without a new digest")
	assert.Equal(t, 1, dailyOn(t, f.db, f.day2))
	assert.Equal(t, 1, dailyOn(t, f.db, f.day3))
	for _, p := range f.gen.prompts {
		assert.NotContains(t, p, "c1-new")
	}

	calls := f.gen.calls()
	require.NoError(t, f.runRange(t, f.from, f.to))
	assert.Equal(t, calls, f.gen.calls(), "a second run makes no AI call")
}

// M2: a channel whose forward digest ends below the range, with an
// undigested message between the two. The backfill digests none of the
// channel's range messages, so the next forward window still starts below
// that message.
func TestRange_NeverDigestsAboveTheForwardMark(t *testing.T) {
	f := newFixture(t)
	floor := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	upper := floor.Add(24 * time.Hour)
	mark := floor.AddDate(0, 0, -3)
	seedMessage(t, f.db, "1:C1", mark.Add(-time.Hour), "digested")
	seedDigest(t, f.db, "1:C1", mark.Add(-2*time.Hour), mark)
	between := floor.AddDate(0, 0, -1)
	seedMessage(t, f.db, "1:C1", between, "undigested")
	f.fetch.onFetch = func(_, _ time.Time) error {
		seedMessage(t, f.db, "1:C1", floor.Add(6*time.Hour), "fetched")
		return nil
	}

	require.NoError(t, f.runRange(t, floor, upper))
	assert.Zero(t, f.gen.calls(), "nothing of the channel is digested")

	candidates, err := f.db.ChannelsWithUndigestedMessages(0, float64(time.Now().Unix()))
	require.NoError(t, err)
	require.Len(t, candidates, 1)
	since := max(candidates[0].LastDigestTo, candidates[0].ConsideredTS)
	assert.Equal(t, float64(mark.Unix()), since, "the forward mark did not move")
	assert.Less(t, since, float64(between.Unix()), "the next forward window includes the undigested message")
}

// m1: a day partly covered by digests gets its uncovered messages digested.
// A message on a digest's period_to is covered, one on its period_from is
// not ((from, to] periods); nothing already covered reaches a prompt.
func TestRange_PartlyCoveredDayDigestsOnlyTheUncoveredMessages(t *testing.T) {
	f := newFixture(t)
	day := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	at := func(h int) time.Time { return day.Add(time.Duration(h) * time.Hour) }
	seedMessage(t, f.db, "1:C1", at(8), "seen-8")
	seedDigest(t, f.db, "1:C1", at(0), at(9))
	seedMessage(t, f.db, "1:C1", at(13), "seen-13")
	seedDigest(t, f.db, "1:C1", at(12), at(14))
	seedDigest(t, f.db, "1:C1", day.AddDate(0, 0, 5), day.AddDate(0, 0, 5).Add(time.Hour)) // the forward mark
	f.fetch.onFetch = func(_, _ time.Time) error {
		seedMessage(t, f.db, "1:C1", at(7), "inside-7")
		seedMessage(t, f.db, "1:C1", at(9), "on-period-to-9")
		seedMessage(t, f.db, "1:C1", at(12), "on-period-from-12")
		seedMessage(t, f.db, "1:C1", at(16), "after-16")
		return nil
	}

	require.NoError(t, f.runRange(t, day, day.Add(24*time.Hour)))
	joined := fmt.Sprint(f.gen.prompts)
	assert.Contains(t, joined, "on-period-from-12")
	assert.Contains(t, joined, "after-16")
	assert.NotContains(t, joined, "inside-7")
	assert.NotContains(t, joined, "on-period-to-9")
	assert.NotContains(t, joined, "seen-8")
	assert.NotContains(t, joined, "seen-13")
	assert.Equal(t, 3+2, countDigests(t, f.db, `channel_id = '1:C1'`), "one digest per uncovered part")
	assert.Equal(t, 1, dailyOn(t, f.db, day))

	calls := f.gen.calls()
	require.NoError(t, f.runRange(t, day, day.Add(24*time.Hour)))
	assert.Equal(t, calls, f.gen.calls(), "the backfill's own digests cover what they digested")
}

// m2: the rollup is marked pending before any digest is written. The model
// fails on its second call (the rollup): the ledger on disk still says
// rollup_pending, and a rerun rebuilds the rollup with no second digest.
func TestRange_PendingRollupSurvivesAFailedRollup(t *testing.T) {
	f := newFixture(t)
	day := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	seedMessage(t, f.db, "1:C1", day.Add(3*time.Hour), "news")
	// A rollup needs two channel digests of the day.
	seedMessage(t, f.db, "1:C0", day.Add(time.Hour), "seen")
	seedDigest(t, f.db, "1:C0", day, day.Add(time.Hour))
	f.gen.failOn = 2

	err := f.runRange(t, day, day.Add(24*time.Hour))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "daily rollup failed")
	assert.Equal(t, 2, f.gen.calls())
	require.NotNil(t, f.ledgerDay(t, 1, day))
	assert.True(t, f.ledgerDay(t, 1, day).RollupPending, "pending is on disk")
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C1'`))

	f.gen.failOn = 0
	require.NoError(t, f.runRange(t, day, day.Add(24*time.Hour)))
	assert.Equal(t, 1, dailyOn(t, f.db, day), "the rerun rebuilds the rollup")
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C1'`), "no second digest")
	assert.False(t, f.ledgerDay(t, 1, day).RollupPending)
}

// A pending rollup whose digest lock another run holds is held, not failed.
func TestRange_PendingRollupWaitsForAHeldLock(t *testing.T) {
	f := newFixture(t)
	day := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	r := f.newRun(t, true)
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))
	r.Ledger.Days[ledgerKey(1, utcDayKey(day))].RollupPending = true
	require.NoError(t, r.Ledger.save())

	release := f.holdDigestLock(t)
	err := f.runRange(t, day, day.Add(24*time.Hour))
	release()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "a daily rollup waits for another digest run")
	assert.True(t, f.ledgerDay(t, 1, day).RollupPending)

	require.NoError(t, f.runRange(t, day, day.Add(24*time.Hour)))
	assert.False(t, f.ledgerDay(t, 1, day).RollupPending)
}

// The rerun after a held digest lock still digests the gap: its decision
// was frozen before the first fetch stored the gap's messages.
func TestRange_RerunAfterAHeldLockStillDigestsTheGap(t *testing.T) {
	f := newGapFixture(t)
	release := f.holdDigestLock(t)
	err := f.runRange(t, f.from, f.to)
	release()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "run it again")

	require.NoError(t, f.runRange(t, f.from, f.to))
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`))
	assert.Equal(t, 1, countDigests(t, f.db, `channel_id = '1:C3'`))
}

// M3a: a run with digests off still freezes the ledger, so a later run with
// digests on digests the gap the first run fetched.
func TestRange_DigestsOffStillFreezes(t *testing.T) {
	f := newGapFixture(t)
	require.NoError(t, f.newRun(t, false).Range(context.Background(), f.from, f.to))
	assert.Zero(t, f.gen.calls())
	require.NotNil(t, f.ledgerDay(t, 1, f.day2))

	require.NoError(t, f.runRange(t, f.from, f.to))
	assert.Equal(t, 2, countDigests(t, f.db, `channel_id = '1:C2'`), "C2's gap day is digested")
}

// M3b, in a zone west of UTC: the first run's search stores a message of the
// UTC day after its range (BackfillSearch's "before:" day); that day was
// frozen before the fetch, so a later run over it still digests the gap.
func TestRange_FreezesTheWidenedSearchDays(t *testing.T) {
	loc := useLocal(t, "America/Los_Angeles")
	f := newFixture(t)
	base := time.Now().In(loc).AddDate(0, 0, -20)
	floor := time.Date(base.Year(), base.Month(), base.Day(), 0, 0, 0, 0, loc)
	upper := floor.AddDate(0, 0, 1)
	first, last := sync.BackfillSearchDays(floor, upper)
	seedDigest(t, f.db, "1:C2", first.AddDate(0, 0, -1), last.AddDate(0, 0, 2)) // a gap digest
	neighbour := last.Add(-12 * time.Hour)                                      // past upper, inside the search
	require.True(t, neighbour.After(upper))
	f.fetch.onFetch = func(_, _ time.Time) error {
		seedMessage(t, f.db, "1:C2", neighbour, "neighbour")
		return nil
	}

	require.NoError(t, f.runRange(t, floor, upper))
	for d := first; !d.After(last); d = d.Add(24 * time.Hour) {
		assert.NotNil(t, f.ledgerDay(t, 1, d), "day %s frozen", utcDayKey(d))
	}
	assert.Zero(t, f.gen.calls(), "the neighbour is outside this run's range")

	f.fetch.onFetch = nil
	next := upper
	require.NoError(t, f.runRange(t, next, next.AddDate(0, 0, 1)))
	assert.Contains(t, fmt.Sprint(f.gen.prompts), "neighbour", "the neighbour's gap day is digested")
}

// Local 2-day chunks map onto clipped UTC days, newest first: in Los Angeles
// a chunk from local midnight touches three UTC days.
func TestUTCDaysNewestFirst_LocalChunkOnUTCDays(t *testing.T) {
	loc := useLocal(t, "America/Los_Angeles")
	from := time.Date(2026, 3, 10, 0, 0, 0, 0, loc) // 07:00 UTC (PDT)
	to := from.AddDate(0, 0, 2)
	days := utcDaysNewestFirst(from, to)
	require.Len(t, days, 3)
	assert.Equal(t, time.Date(2026, 3, 12, 0, 0, 0, 0, time.UTC), days[0][0].UTC())
	assert.Equal(t, to, days[0][1])
	assert.Equal(t, "2026-03-11", utcDayKey(days[1][0]))
	assert.Equal(t, from, days[2][0])
	assert.Equal(t, time.Date(2026, 3, 11, 0, 0, 0, 0, time.UTC), days[2][1].UTC())
}

// m3: a purge that starts during the first fetch stops the run before its
// digests and before the next chunk.
func TestRange_PurgeStartingMidRunStops(t *testing.T) {
	f := newFixture(t)
	floor := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	upper := floor.AddDate(0, 0, 3)
	f.fetch.onFetch = func(from, _ time.Time) error {
		seedMessage(t, f.db, "1:C1", from.Add(time.Hour), "news")
		_, err := f.db.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at, state)
			VALUES ('slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'running')`)
		return err
	}

	err := f.runRange(t, floor, upper)
	require.ErrorIs(t, err, ErrPurgeRunning)
	assert.Contains(t, err.Error(), "run the backfill again once it finishes")
	assert.Len(t, f.fetch.chunks, 1, "the next chunk is not fetched")
	assert.Zero(t, f.gen.calls(), "nothing is digested")
}

// A day decided before the account's latest finished purge is decided
// again, keeping its pending rollup (m7).
func TestFreeze_RedecidesADayAfterAPurge(t *testing.T) {
	f := newFixture(t)
	day := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	seedDigest(t, f.db, "1:C1", day.Add(-time.Hour), day.Add(2*time.Hour)) // saw no message: excluded
	r := f.newRun(t, true)
	r.Now = func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))
	key := ledgerKey(1, utcDayKey(day))
	require.Len(t, r.Ledger.Days[key].Excluded, 1)
	r.Ledger.Days[key].RollupPending = true
	require.NoError(t, r.Ledger.save())

	// Without a purge the day stays as decided.
	_, err := f.db.Exec(`DELETE FROM digests`)
	require.NoError(t, err)
	r = f.newRun(t, true)
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))
	assert.Len(t, r.Ledger.Days[key].Excluded, 1)

	_, err = f.db.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at, state, finished_at)
		VALUES ('slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'done', '2026-02-01T00:00:00Z')`)
	require.NoError(t, err)
	r = f.newRun(t, true)
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))
	assert.Empty(t, r.Ledger.Days[key].Excluded, "decided again from what the database holds")
	assert.True(t, r.Ledger.Days[key].RollupPending, "the pending rollup is carried over")
}

// The ledger keys one account's day apart from another's.
func TestFreeze_KeysEachAccountApart(t *testing.T) {
	f := newFixture(t)
	day := time.Now().UTC().AddDate(0, 0, -20).Truncate(24 * time.Hour)
	seedDigest(t, f.db, "2:C1", day.Add(-time.Hour), day.Add(2*time.Hour))
	r := f.newRun(t, true)
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))
	r.Fetch = &fakeFetcher{id: 2}
	require.NoError(t, r.freeze(day, day.Add(24*time.Hour)))

	assert.Empty(t, r.Ledger.Days[ledgerKey(1, utcDayKey(day))].Excluded)
	assert.Len(t, r.Ledger.Days[ledgerKey(2, utcDayKey(day))].Excluded, 1)
}
