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
	RunBackfillWindowChannels(ctx context.Context, slackAccountID int64, from, to float64, channels []string, ignore []int64) (digest.BackfillWindowResult, *digest.Usage, error)
	RunBackfillDayRollups(ctx context.Context, from, to float64) error
	InitialHistorySince(nowUnix float64) float64
}

// ErrPurgeRunning refuses a backfill, or stops one, while a purge deletes
// the account's data: the backfill must not refill it behind the purge
// (PURGE-01).
var ErrPurgeRunning = errors.New("watchtower is deleting this account's data; " +
	"run the backfill again once it finishes (see 'watchtower accounts purges')")

// ErrPurgedDuringRun stops a backfill whose account a purge deleted between
// two checks: its token is gone and the account needs a Re-login.
var ErrPurgedDuringRun = errors.New("watchtower deleted this account's data during the backfill; " +
	"Re-login, then run the backfill again")

// Run is one `slack backfill` command.
type Run struct {
	DB     *db.DB
	Fetch  Fetcher
	Digest Digester // nil: digests off — the ledger is still frozen
	Ledger *Ledger  // held under LockLedger
	Out    io.Writer
	Now    func() time.Time // nil: time.Now

	purgeChecked bool   // CheckPurge ran once and recorded purgedAt
	purgedAt     string // the account's latest finished purge at the first check
}

// ownerError shows an owner text and still unwraps to its cause.
type ownerError struct {
	msg   string
	cause error
}

func (e *ownerError) Error() string { return e.msg }
func (e *ownerError) Unwrap() error { return e.cause }

func (r *Run) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// CheckPurge returns ErrPurgeRunning while the account's purge runs, and
// ErrPurgedDuringRun once a purge finished after the run's first check.
// Range checks it before each chunk and each digest day, so a purge that
// starts, or even finishes, during one fetch stops the run at the next step.
func (r *Run) CheckPurge() error {
	id := r.Fetch.AccountID()
	running, err := r.DB.AccountPurgeRunning("slack", id)
	if err != nil {
		return err
	}
	if running {
		return fmt.Errorf("slack account %d: %w", id, ErrPurgeRunning)
	}
	latest, err := lastFinishedPurge(r.DB, id)
	if err != nil {
		return err
	}
	if !r.purgeChecked {
		r.purgeChecked, r.purgedAt = true, latest
	} else if latest != r.purgedAt {
		return fmt.Errorf("slack account %d: %w", id, ErrPurgedDuringRun)
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
				return &ownerError{msg: mismatch.OwnerMessage(), cause: err}
			}
			if errors.Is(err, ErrPurgeRunning) || errors.Is(err, ErrPurgedDuringRun) {
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
// know yet, the digests overlapping the day that held none of its messages
// and the highest digest id.
// It runs before any fetch of the range, digests on or off, so "held" means
// messages the digests could have seen. A day decided before the account's
// latest finished purge is decided again, keeping its pending rollup.
func (r *Run) freeze(floor, upper time.Time) error {
	id := r.Fetch.AccountID()
	purgedAt, err := lastFinishedPurge(r.DB, id)
	if err != nil {
		return err
	}
	// One snapshot for every day this call decides, taken before any fetch.
	idMax, err := r.DB.MaxDigestID()
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
			return fmt.Errorf("deciding %s of slack account %d: %w", utcDayKey(d), id, err)
		}
		times, err := r.DB.ChannelMessageTimesInRange(id, day.from, day.to)
		if err != nil {
			return fmt.Errorf("deciding %s of slack account %d: %w", utcDayKey(d), id, err)
		}
		r.Ledger.Days[key] = &ledgerDay{
			Excluded:      excludedDigests(day, digests, times),
			DigestIDMax:   idMax,
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
	digests, kept, rolled := 0, 0, 0
	for _, d := range utcDaysNewestFirst(from, to) {
		if err := r.CheckPurge(); err != nil {
			return "", err
		}
		n, k, didRoll, err := r.digestDay(ctx, d[0], d[1])
		digests += n
		kept += k
		if err != nil {
			return "", err
		}
		if didRoll {
			rolled++
		}
	}
	line = fmt.Sprintf("%s, %d digests, daily rollups run for %d days", line, digests, rolled)
	if kept > 0 {
		line += fmt.Sprintf("; %d channel days already had a digest: their messages are saved, not digested", kept)
	}
	return line, nil
}

// digestDay digests, for every channel whose UTC day no digest covers
// (coverage.go), the account's messages of the day (clipped to the chunk) at
// or below the channel's forward mark — anything above belongs to the
// forward digest — then rebuilds the day's daily rollup when it got a digest
// (now, or in an unfinished earlier run: the ledger's rollup_pending). kept
// counts the channel days a digest kept messages of from being digested.
func (r *Run) digestDay(ctx context.Context, dayFrom, dayTo time.Time) (digests, kept int, rolled bool, err error) {
	id := r.Fetch.AccountID()
	day := r.Ledger.Days[ledgerKey(id, utcDayKey(dayFrom))]
	if day == nil {
		return 0, kept, false, fmt.Errorf("slack backfill ledger has no entry for %s", utcDayKey(dayFrom))
	}
	groups, kept, err := r.uncoveredGroups(id, dayFrom, dayTo, day)
	if err != nil {
		return 0, kept, false, err
	}
	wasPending := day.RollupPending
	if len(groups) > 0 && !wasPending {
		// Saved before any digest is written, so a crash or a failed save
		// later still leaves the rollup to the rerun.
		day.RollupPending = true
		if err := r.Ledger.save(); err != nil {
			return 0, kept, false, err
		}
	}
	for _, g := range groups {
		res, _, err := r.Digest.RunBackfillWindowChannels(ctx, id, g.span.from, g.span.to, g.channels, day.Excluded)
		digests += res.Digests
		if err != nil {
			return digests, kept, false, fmt.Errorf("messages saved, digests failed: %w", err)
		}
		if !res.Complete {
			return digests, kept, false, errors.New("messages saved, digests not finished (another digest run holds the lock, " +
				"or the day needs more passes); run it again")
		}
	}
	if !day.RollupPending {
		return digests, kept, false, nil
	}
	if digests == 0 && !wasPending {
		// Nothing was written (muted channels, a declined model call).
		day.RollupPending = false
		return 0, kept, false, r.Ledger.save()
	}
	if err := r.Digest.RunBackfillDayRollups(ctx, float64(dayFrom.Unix()), float64(dayTo.Unix())); err != nil {
		if errors.Is(err, digest.ErrDigestLocked) {
			return digests, kept, false, errors.New("messages and digests saved, a daily rollup waits for another digest run; run it again")
		}
		return digests, kept, false, fmt.Errorf("messages and digests saved, daily rollup failed: %w", err)
	}
	day.RollupPending = false
	if err := r.Ledger.save(); err != nil {
		return digests, kept, false, err
	}
	return digests, kept, true, nil
}

// spanGroup is the channels sharing one uncovered span: one digest call.
type spanGroup struct {
	span     span
	channels []string
}

// uncoveredGroups resolves, with three queries for the day, the spans to
// digest of every channel whose day is not covered — the window
// [dayFrom, dayTo) (the UTC day clipped to the chunk) cut at the channel's
// forward mark and outside every digest written since the day was decided —
// and groups the channels by span, newest span first. Coverage looks at the
// whole UTC day, so a day split across two chunks is decided the same in
// both. kept counts the channel days with a message at or below the mark
// that a digest keeps from being digested: a covered day, or a later
// digest's period.
func (r *Run) uncoveredGroups(id int64, dayFrom, dayTo time.Time, day *ledgerDay) (groups []spanGroup, kept int, err error) {
	start := dayFrom.UTC().Truncate(24 * time.Hour)
	whole := spanOf(start, start.Add(24*time.Hour))
	digests, err := r.DB.ChannelDigestsOverlapping(id, whole.from, whole.to)
	if err != nil {
		return nil, 0, err
	}
	window := spanOf(dayFrom, dayTo)
	times, err := r.DB.ChannelMessageTimesInRange(id, window.from, window.to)
	if err != nil {
		return nil, 0, err
	}
	marks, err := r.DB.ChannelForwardMarks(id)
	if err != nil {
		return nil, 0, err
	}
	never := r.Digest.InitialHistorySince(float64(r.now().Unix()))

	covered := coveredChannels(digests, day)
	later := laterPeriods(digests, day)
	bySpan := map[span][]string{}
	for ch, ts := range times {
		limit, ok := marks[ch]
		if !ok {
			limit = never
		}
		reachable := countTimes(span{window.from, min(window.to, limit)}, ts)
		if covered[ch] {
			if reachable > 0 {
				kept++
			}
			continue
		}
		pieces := uncovered(window, limit, later[ch], ts)
		digestable := 0
		for _, s := range pieces {
			bySpan[s] = append(bySpan[s], ch)
			digestable += countTimes(s, ts)
		}
		if digestable < reachable {
			kept++
		}
	}
	groups = make([]spanGroup, 0, len(bySpan))
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
	return groups, kept, nil
}
