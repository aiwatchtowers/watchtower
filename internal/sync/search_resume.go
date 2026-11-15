package sync

import (
	"context"
	"fmt"
	"time"
)

// slackFetchDeadline bounds the Slack fetches of one search-path Run: its
// rate-limit retry chain goes on while each hold ends before it, so the rest
// of the daemon cycle never waits behind a rate-limited account. Unread
// pages are kept for the next run (searchResume).
const slackFetchDeadline = 10 * time.Minute

// runFetchDeadline is how long a Run's rate-limit retry chain may go on:
// slackFetchDeadline for a search-path run, none (the client's plain retry
// cap) for an explicit full or per-channel sync, which can rightly run
// longer.
func runFetchDeadline(opts SyncOptions) time.Duration {
	if opts.Full || len(opts.Channels) > 0 {
		return 0
	}
	return slackFetchDeadline
}

// searchResume is where the blanket search stopped with pages left: its
// query and the first page not fetched. The next Run with the same query
// starts there; a different query (the window moved) drops it. A window
// computed from now keeps after across midnight (syncViaSearch). firstSync
// carries the window's first-sync state, which a resumed run can no longer
// read off the account (run 1 already stored messages). It lives in memory:
// a restarted daemon re-reads the window (idempotent upserts).
type searchResume struct {
	query     string
	after     string // the window's after: date, kept while a moving window resumes
	nextPage  int
	firstSync bool
}

// RunOutcome is what the last Run tells the daemon's cadence: whether Slack
// answered any of the run's own calls with a 429 (retried ones included; not
// another caller's on the same client), whether the blanket
// search stopped with pages left for the next run, and how many blanket
// pages and messages it read.
type RunOutcome struct {
	RateLimited   bool
	ResumePending bool
	Pages         int
	Messages      int
}

// RunOutcome returns the last Run's outcome.
func (o *Orchestrator) RunOutcome() RunOutcome { return o.outcome }

// searchStart returns the page the blanket query starts at, the page the
// pending resume stopped on (1 when none) and the window's first-sync state:
// a pending resume of the same query wins, any other resume is dropped. A
// resume starts one page before where it stopped: a message deleted from an
// already-read page between runs shifts the rest of the listing back by
// one, and re-reading that page (the upserts dedupe it) picks up the match
// that slid onto it.
func (o *Orchestrator) searchStart(query string, firstSync bool) (startPage, stopPage int, first bool) {
	r := o.resume
	o.resume = nil
	if r == nil || r.query != query {
		return 1, 1, firstSync
	}
	startPage = max(1, r.nextPage-1)
	o.logger.Printf("search sync: resuming %q at page %d (stopped at %d)", query, startPage, r.nextPage)
	return startPage, r.nextPage, r.firstSync
}

// recordSearchStop counts the blanket pass's pages and messages and keeps
// its position when it stopped with pages left (a rate limit, the fetch
// deadline, a cancel, an error). A resumed pass that stopped before passing
// its old stop page keeps that page, so failing runs never walk the
// position backwards.
func (o *Orchestrator) recordSearchStop(query, after string, startPage, stopPage, next int, completed, firstSync bool, messages int) {
	o.outcome.Pages += next - startPage
	o.outcome.Messages += messages
	if next = max(next, stopPage); !completed && next > 1 {
		o.resume = &searchResume{query: query, after: after, nextPage: next, firstSync: firstSync}
	}
}

// behind reports whether the account's blanket search is lagging: a window
// left unfinished, or a last run that met a rate limit. Only then does the
// mention query run first; a clean account reads its mentions in the
// blanket pass at no extra call.
func (o *Orchestrator) behind() bool {
	return o.resume != nil || o.lastRunRateLimited
}

// searchMentions runs the owner's mention query over the window before the
// blanket query when the account is behind, so a throttled account still
// gets its mentions. It saves like the forward sync but never moves the
// watermark, and its own incompleteness does not mark the window
// incomplete: the blanket query covers the same messages. Skipped while the
// account's user is unknown. It returns the channels it saw.
func (o *Orchestrator) searchMentions(ctx context.Context, after string) (map[string]bool, error) {
	owner, ok := o.ownerRawID()
	if !ok || !o.behind() {
		return nil, nil
	}
	_, _, seen, err := o.searchAndSave(ctx, fmt.Sprintf("<@%s> after:%s", owner, after), true, nil)
	if err != nil && ctx.Err() == nil && isNonFatalError(err) {
		// Page 1 failed for a reason other than a rate limit (a scope, a
		// dead channel): the blanket query still covers the mentions, so
		// this never falls back to the full sync.
		o.logger.Printf("search sync: mention query failed, continuing with the blanket query: %v", err)
		return nil, nil
	}
	return seen, err
}
