package digest

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// maxBackfillPasses bounds the passes one RunBackfillWindow call makes over a
// chunk. Each pass digests at most DefaultMaxBatchesPerRun batches and one
// load per channel, so a busy chunk needs several; one that still has work
// after this many stays incomplete and is resumed next cycle.
const maxBackfillPasses = 20

// BackfillWindowResult reports one RunBackfillWindow call: how many channel
// digests it stored, and whether no channel has undigested messages left in
// the chunk.
type BackfillWindowResult struct {
	Digests  int
	Complete bool
}

// RunBackfillWindow digests one Slack account's history inside one backfill
// chunk (from, to]: only that account's channels, since each account has its
// own backfill row (another account's messages in the same range wait for
// its own row). The interval follows the chunk convention stated once in
// internal/historybackfill/chunk.go. Each channel's window is resolved like the forward path's, but
// scoped to the chunk: it starts at the later of from, the channel's newest
// digest ending inside the chunk, what this call already considered, and the
// FEAT-03 fast-forward floor, and loads up to `to`. Passes repeat until no
// channel has undigested messages in the chunk.
//
// Forward marks are never moved: "considered" stamps stay in memory for the
// call, and the backfill's digests end below every forward window, so the
// forward MAX(period_to) is unchanged. The live-edge cooldown is off.
//
// A channel whose AI call or store fails is not re-sent in later passes of the
// same call; the call then returns that failure once nothing else is left.
// Prompts carry no previous context and no track context (see inBackfill).
//
// Lock contention (ErrDigestLocked) returns {0, false} with no error: the
// chunk is retried next cycle. Any other lock error (the lock file cannot be
// created or opened) is returned as an error. The returned usage is the sum of this call's own passes — never the
// pipeline's shared counters, which the forward phase also feeds.
func (p *Pipeline) RunBackfillWindow(ctx context.Context, slackAccountID int64, from, to float64) (BackfillWindowResult, *Usage, error) {
	if !p.cfg.Digest.Enabled {
		return BackfillWindowResult{Complete: true}, &Usage{}, nil
	}

	unlock, err := p.acquireDigestLock()
	if errors.Is(err, ErrDigestLocked) {
		p.logger.Printf("digest backfill: skipping — %v", err)
		return BackfillWindowResult{}, &Usage{}, nil
	}
	if err != nil {
		return BackfillWindowResult{}, &Usage{}, fmt.Errorf("digest backfill: %w", err)
	}
	defer unlock()

	p.loadCaches()
	scope := &backfillScope{considered: map[string]float64{}, failed: map[string]bool{}}
	p.backfill = scope
	defer func() { p.backfill = nil }()

	fastForwardTS, err := p.db.GetDigestFastForwardTS()
	if err != nil {
		p.logger.Printf("digest backfill: reading fast-forward ts: %v", err)
		fastForwardTS = 0
	}

	var res BackfillWindowResult
	usage := &Usage{}
	var prev map[string]float64
	for range maxBackfillPasses {
		if err := ctx.Err(); err != nil {
			return res, usage, err
		}
		windows, err := p.backfillWindows(slackAccountID, from, to, fastForwardTS)
		if err != nil {
			return res, usage, err
		}
		if len(windows) == 0 {
			err := scope.failure(from, to)
			res.Complete = err == nil
			return res, usage, err
		}
		// advancesWindow's invariant, asserted per pass: a pass that moved no
		// channel would repeat itself forever.
		if prev != nil && !backfillProgressed(prev, windows) {
			return res, usage, fmt.Errorf("digest backfill: no progress in [%.0f,%.0f]", from, to)
		}
		prev = make(map[string]float64, len(windows))
		for _, w := range windows {
			prev[w.channelID] = w.since
		}

		n, u, err := p.runChannelWindows(ctx, windows, to)
		res.Digests += n
		addBackfillUsage(usage, u)
		if ctxErr := ctx.Err(); ctxErr != nil {
			return res, usage, ctxErr
		}
		if err != nil {
			return res, usage, scope.chunkErrors(fmt.Sprintf("digest backfill [%.0f,%.0f]: %v", from, to, err), err)
		}
	}
	p.logger.Printf("digest backfill: [%.0f,%.0f] still has work after %d passes — resuming next cycle", from, to, maxBackfillPasses)
	return res, usage, nil
}

// failure is the outcome of a chunk with no windows left. A channel that
// failed in this call is not re-sent; with nothing else left the chunk takes
// the failure and is retried next cycle. nil means the chunk is complete.
func (b *backfillScope) failure(from, to float64) error {
	if len(b.failed) == 0 {
		return nil
	}
	var last error
	if len(b.errs) > 0 {
		last = b.errs[len(b.errs)-1]
	}
	return b.chunkErrors(fmt.Sprintf("digest backfill [%.0f,%.0f]: %d channel(s) failed: %v",
		from, to, len(b.failed), last), last)
}

// chunkErrors is the call's failure with msg as its message, carrying every
// channel failure of the call (fallback when none was recorded).
func (b *backfillScope) chunkErrors(msg string, fallback error) error {
	b.mu.Lock()
	errs := append([]error(nil), b.errs...)
	b.mu.Unlock()
	if len(errs) == 0 && fallback != nil {
		errs = []error{fallback}
	}
	return &ChunkErrors{Msg: msg, Errs: errs}
}

// ChunkErrors is a backfill chunk's failure made of several errors (every
// failed channel or rollup day of the call): errors.Is and errors.As see
// each of them, and a caller that must tell a data error from a transient
// one inspects Errs (the history backfill strikes the chunk when any is a
// data error, #580).
type ChunkErrors struct {
	Msg  string
	Errs []error
}

func (e *ChunkErrors) Error() string   { return e.Msg }
func (e *ChunkErrors) Unwrap() []error { return e.Errs }

// addBackfillUsage adds one pass's token usage to the call's own sum.
func addBackfillUsage(sum, u *Usage) {
	if u == nil {
		return
	}
	sum.InputTokens += u.InputTokens
	sum.OutputTokens += u.OutputTokens
	sum.TotalAPITokens += u.TotalAPITokens
}

// backfillWindows resolves the chunk-scoped window of every digestable channel
// that still has messages in (from, to] past its window start. Muted channels
// and 1:1 DMs are dropped here, not only inside runChannelWindows: they are
// never digested, so leaving them in would read as a pass without progress.
func (p *Pipeline) backfillWindows(slackAccountID int64, from, to, fastForwardTS float64) ([]channelWindow, error) {
	candidates, err := p.db.ChannelsWithMessagesInRange(slackAccountID, from, to)
	if err != nil {
		return nil, fmt.Errorf("digest backfill: %w", err)
	}
	b := p.backfill
	b.mu.Lock()
	defer b.mu.Unlock()
	windows := make([]channelWindow, 0, len(candidates))
	for _, c := range candidates {
		if b.failed[c.ChannelID] {
			continue
		}
		since := max(from, c.LastDigestInRange, b.considered[c.ChannelID], fastForwardTS)
		if c.NewestInRange > since {
			windows = append(windows, channelWindow{channelID: c.ChannelID, since: since})
		}
	}
	if len(windows) == 0 {
		return nil, nil
	}
	return p.filterDigestableChannels(windows), nil
}

// backfillProgressed reports whether any channel's window moved since the
// previous pass — its start advanced, or it left the candidate set.
func backfillProgressed(prev map[string]float64, windows []channelWindow) bool {
	if len(windows) < len(prev) {
		return true
	}
	for _, w := range windows {
		before, ok := prev[w.channelID]
		if !ok || w.since > before {
			return true
		}
	}
	return false
}

// RunBackfillRollups generates the daily rollup of every UTC day the backfill
// chunk [from, to) touches. Every day is tried; one failed day returns its error, several return a *ChunkErrors with the first one's message.
// It does not touch the daemon's forward rollup attempt budget, and its
// prompts carry no previous context and no track context (see inBackfill).
// Lock contention returns an error wrapping ErrDigestLocked, so the caller
// can hold the chunk instead of counting a failure.
func (p *Pipeline) RunBackfillRollups(ctx context.Context, from, to float64) error {
	if !p.cfg.Digest.Enabled {
		return nil
	}

	unlock, err := p.acquireDigestLock()
	if err != nil {
		return fmt.Errorf("digest backfill rollups: %w", err)
	}
	defer unlock()

	p.loadCaches()
	p.backfillRollups = true
	defer func() { p.backfillRollups = false }()

	var errs []error
	end := time.Unix(int64(to), 0).UTC()
	for d := utcDayStart(time.Unix(int64(from), 0)); d.Before(end); d = d.Add(24 * time.Hour) {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			break
		}
		if err := p.runDailyRollupForDate(ctx, d); err != nil {
			if len(errs) > 0 {
				p.logger.Printf("digest backfill rollup %s: %v", d.Format("2006-01-02"), err)
			}
			errs = append(errs, fmt.Errorf("digest backfill rollup %s: %w", d.Format("2006-01-02"), err))
		}
	}
	switch len(errs) {
	case 0:
		return nil
	case 1:
		return errs[0]
	}
	return &ChunkErrors{Msg: errs[0].Error(), Errs: errs}
}
