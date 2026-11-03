// Package slackbackfill is `watchtower slack backfill`: an owner-run refetch
// of a past date range of one Slack account through the history backfill's
// search (sync.Orchestrator.BackfillSearch), with digests and daily rollups
// for what no digest covered yet. It creates no history_backfill row
// (BACKFILL-01), moves no forward digest mark (BACKFILL-02: every digest it
// writes ends at or below the channel's forward mark) and runs no inbox
// detection.
package slackbackfill

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/historybackfill"
	"watchtower/internal/sync"
)

// Fetcher fetches one chunk of the account (sync.Orchestrator).
type Fetcher interface {
	AccountID() int64
	BackfillSearch(ctx context.Context, from, to time.Time) (int, error)
}

// Digester writes the chunk digests and daily rollups (digest.Pipeline).
type Digester interface {
	RunBackfillWindowChannels(ctx context.Context, slackAccountID int64, from, to float64, channels []string) (digest.BackfillWindowResult, *digest.Usage, error)
	RunBackfillRollupsForAccount(ctx context.Context, account int64, from, to float64) error
	InitialHistorySince(nowUnix float64) float64
}

// ErrPurgeRunning refuses a backfill, or stops one, while a purge deletes
// the account's data: the backfill must not refill it behind the purge
// (PURGE-01).
var ErrPurgeRunning = errors.New("watchtower is deleting this account's data; " +
	"run the backfill again once it finishes (see 'watchtower accounts purges')")

// Run is one `slack backfill` command.
type Run struct {
	DB     *db.DB
	Fetch  Fetcher
	Digest Digester // nil: digests off — the ledger is still frozen
	Ledger *Ledger  // held under LockLedger
	Out    io.Writer
	Now    func() time.Time // nil: time.Now
}

func (r *Run) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// CheckPurge returns ErrPurgeRunning while the account's purge runs. Range
// checks it before each chunk and each digest day; a purge that starts during
// one fetch finds that chunk's rows still in place and deletes them.
func (r *Run) CheckPurge() error {
	id := r.Fetch.AccountID()
	running, err := r.DB.AccountPurgeRunning("slack", id)
	if err != nil {
		return err
	}
	if running {
		return fmt.Errorf("slack account %d: %w", id, ErrPurgeRunning)
	}
	return nil
}

// Range walks [floor, upper) in history-backfill chunks, newest first: fetch,
// then — with Digest set — digests for what no digest covered yet. What the
// existing digests covered is frozen in the ledger before the first fetch, so
// a rerun decides the same. It stops at the first chunk it cannot finish and
// names the --to that resumes there; everything fetched stays saved.
func (r *Run) Range(ctx context.Context, floor, upper time.Time) error {
	if err := r.CheckPurge(); err != nil {
		return err
	}
	if err := r.freeze(floor, upper); err != nil {
		return err
	}
	floorTS := float64(floor.Unix())
	for reached := float64(upper.Unix()); ; {
		fromTS, toTS, ok := historybackfill.NextChunk(reached, floorTS)
		if !ok {
			break
		}
		if err := r.CheckPurge(); err != nil {
			return err
		}
		from, to := time.Unix(int64(fromTS), 0), time.Unix(int64(toTS), 0)
		last := to.Add(-time.Second).Format("2006-01-02")
		days := from.Format("2006-01-02") + ".." + last
		line, err := r.chunk(ctx, from, to)
		if err != nil {
			var mismatch *sync.TeamMismatchError
			if errors.As(err, &mismatch) {
				return errors.New(mismatch.OwnerMessage())
			}
			if errors.Is(err, ErrPurgeRunning) {
				return err
			}
			return fmt.Errorf("%s: %w; resume with --to %s", days, err, last)
		}
		fmt.Fprintf(r.Out, "%s: %s\n", days, line)
		reached = fromTS
	}
	fmt.Fprintf(r.Out, "Slack account %d: %s..%s done\n", r.Fetch.AccountID(),
		floor.Format("2006-01-02"), upper.AddDate(0, 0, -1).Format("2006-01-02"))
	return nil
}

// freeze records, for each UTC day the range's searches can store messages
// of (sync.BackfillSearchDays: wider than the range) and the ledger does not
// know yet, the digests overlapping the day that held none of its messages.
// It runs before any fetch of the range, digests on or off, so "held" means
// messages the digests could have seen. A day decided before the account's
// latest finished purge is decided again, keeping its pending rollup.
func (r *Run) freeze(floor, upper time.Time) error {
	id := r.Fetch.AccountID()
	purgedAt, err := lastFinishedPurge(r.DB, id)
	if err != nil {
		return err
	}
	first, last := sync.BackfillSearchDays(floor, upper)
	changed := false
	for d := first; !d.After(last); d = d.Add(24 * time.Hour) {
		key := ledgerKey(id, utcDayKey(d))
		known := r.Ledger.Days[key]
		if known != nil && (purgedAt == "" || purgedAt < known.DecidedAt) {
			continue
		}
		day := spanOf(d, d.Add(24*time.Hour))
		digests, err := r.DB.ChannelDigestsOverlapping(id, day.from, day.to)
		if err != nil {
			return err
		}
		times, err := r.DB.ChannelMessageTimesInRange(id, day.from, day.to)
		if err != nil {
			return err
		}
		r.Ledger.Days[key] = &ledgerDay{
			Excluded:      excludedDigests(day, digests, times),
			RollupPending: known != nil && known.RollupPending,
			DecidedAt:     r.now().UTC().Format(time.RFC3339),
		}
		changed = true
	}
	if !changed {
		return nil
	}
	return r.Ledger.save()
}

// lastFinishedPurge is the finished_at (RFC 3339 UTC) of the Slack
// account's latest done purge, "" when it has none.
func lastFinishedPurge(database *db.DB, accountID int64) (string, error) {
	purges, err := database.ListAccountPurges(false)
	if err != nil {
		return "", err
	}
	latest := ""
	for _, p := range purges {
		if p.Source == "slack" && p.AccountID == accountID && p.State == "done" && p.FinishedAt > latest {
			latest = p.FinishedAt
		}
	}
	return latest, nil
}

// chunk fetches one chunk and, with Digest set, digests what no digest
// covered. line is the chunk's report.
func (r *Run) chunk(ctx context.Context, from, to time.Time) (string, error) {
	saved, err := r.Fetch.BackfillSearch(ctx, from, to)
	if errors.Is(err, sync.ErrSlackTeamMismatch) {
		return "", err
	}
	if errors.Is(err, sync.ErrBackfillIncomplete) {
		return "", fmt.Errorf("slack did not return every page (rate limit), %d messages saved; run it again later: %w", saved, err)
	}
	if err != nil {
		return "", err
	}
	line := strconv.Itoa(saved) + " messages"
	if r.Digest == nil {
		return line, nil
	}
	digests, rolled := 0, 0
	for _, d := range utcDaysNewestFirst(from, to) {
		if err := r.CheckPurge(); err != nil {
			return "", err
		}
		n, didRoll, err := r.digestDay(ctx, d[0], d[1])
		digests += n
		if err != nil {
			return "", err
		}
		if didRoll {
			rolled++
		}
	}
	return fmt.Sprintf("%s, %d digests, daily rollups run for %d days", line, digests, rolled), nil
}

// digestDay digests the account's messages of one UTC day (clipped to the
// chunk) that lie outside every covering digest period (uncovered) and at or
// below the channel's forward mark — anything above belongs to the forward
// digest — then rebuilds the day's daily rollup when it got a digest (now, or
// in an unfinished earlier run: the ledger's rollup_pending).
func (r *Run) digestDay(ctx context.Context, dayFrom, dayTo time.Time) (digests int, rolled bool, err error) {
	id := r.Fetch.AccountID()
	day := r.Ledger.Days[ledgerKey(id, utcDayKey(dayFrom))]
	if day == nil {
		return 0, false, fmt.Errorf("slack backfill ledger has no entry for %s", utcDayKey(dayFrom))
	}
	groups, err := r.uncoveredGroups(id, spanOf(dayFrom, dayTo), day)
	if err != nil {
		return 0, false, err
	}
	wasPending := day.RollupPending
	if len(groups) > 0 && !wasPending {
		// Saved before any digest is written, so a crash or a failed save
		// later still leaves the rollup to the rerun.
		day.RollupPending = true
		if err := r.Ledger.save(); err != nil {
			return 0, false, err
		}
	}
	for _, g := range groups {
		res, _, err := r.Digest.RunBackfillWindowChannels(ctx, id, g.span.from, g.span.to, g.channels)
		digests += res.Digests
		if err != nil {
			return digests, false, fmt.Errorf("messages saved, digests failed: %w", err)
		}
		if !res.Complete {
			return digests, false, errors.New("messages saved, digests not finished (another digest run holds the lock, " +
				"or the day needs more passes); run it again")
		}
	}
	if !day.RollupPending {
		return digests, false, nil
	}
	if digests == 0 && !wasPending {
		// Nothing was written (muted channels, a declined model call).
		day.RollupPending = false
		return 0, false, r.Ledger.save()
	}
	if err := r.Digest.RunBackfillRollupsForAccount(ctx, id, float64(dayFrom.Unix()), float64(dayTo.Unix())); err != nil {
		if errors.Is(err, digest.ErrDigestLocked) {
			return digests, false, errors.New("messages and digests saved, a daily rollup waits for another digest run; run it again")
		}
		return digests, false, fmt.Errorf("messages and digests saved, daily rollup failed: %w", err)
	}
	day.RollupPending = false
	if err := r.Ledger.save(); err != nil {
		return digests, false, err
	}
	return digests, true, nil
}

// spanGroup is the channels sharing one uncovered span: one digest call.
type spanGroup struct {
	span     span
	channels []string
}

// uncoveredGroups resolves, with three queries for the day, every channel's
// uncovered spans and groups the channels by span, newest span first.
func (r *Run) uncoveredGroups(id int64, window span, day *ledgerDay) ([]spanGroup, error) {
	digests, err := r.DB.ChannelDigestsOverlapping(id, window.from, window.to)
	if err != nil {
		return nil, err
	}
	times, err := r.DB.ChannelMessageTimesInRange(id, window.from, window.to)
	if err != nil {
		return nil, err
	}
	marks, err := r.DB.ChannelForwardMarks(id)
	if err != nil {
		return nil, err
	}
	never := r.Digest.InitialHistorySince(float64(r.now().Unix()))

	covering := map[string][]span{}
	for _, d := range digests {
		if !slices.Contains(day.Excluded, d.ID) {
			covering[d.ChannelID] = append(covering[d.ChannelID], span{d.From, d.To})
		}
	}
	bySpan := map[span][]string{}
	for ch, ts := range times {
		limit, ok := marks[ch]
		if !ok {
			limit = never
		}
		for _, s := range uncovered(window, limit, covering[ch], ts) {
			bySpan[s] = append(bySpan[s], ch)
		}
	}
	groups := make([]spanGroup, 0, len(bySpan))
	for s, chans := range bySpan {
		slices.Sort(chans)
		groups = append(groups, spanGroup{s, chans})
	}
	slices.SortFunc(groups, func(a, b spanGroup) int {
		if c := cmp.Compare(b.span.to, a.span.to); c != 0 {
			return c
		}
		return cmp.Compare(strings.Join(a.channels, ","), strings.Join(b.channels, ","))
	})
	return groups, nil
}
