package sync

import "time"

// slackFetchDeadline bounds the Slack fetches of one search-path Run: its
// rate-limit retry chain goes on while each hold ends before it, so the rest
// of the daemon cycle never waits behind a rate-limited account. Unread
// pages are kept for the next run (searchResume).
const slackFetchDeadline = 10 * time.Minute

// searchResume is where the blanket search stopped with pages left: its
// query and the first page not fetched. The next Run with the same query
// starts there; a different query (the window moved) drops it. firstSync
// carries the window's first-sync state, which a resumed run can no longer
// read off the account (run 1 already stored messages). It lives in memory:
// a restarted daemon re-reads the window (idempotent upserts).
type searchResume struct {
	query     string
	nextPage  int
	firstSync bool
}

// RunOutcome is what the last Run tells the daemon's cadence: whether Slack
// answered any call with a 429 (retried ones included), whether the blanket
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

// searchStart returns the page the blanket query starts at and the window's
// first-sync state: a pending resume of the same query wins, any other
// resume is dropped.
func (o *Orchestrator) searchStart(query string, firstSync bool) (startPage int, first bool) {
	r := o.resume
	o.resume = nil
	if r == nil || r.query != query {
		return 1, firstSync
	}
	o.logger.Printf("search sync: resuming %q at page %d", query, r.nextPage)
	return r.nextPage, r.firstSync
}

// recordSearchStop counts the blanket pass's pages and messages and keeps
// its position when it stopped with pages left (a rate limit, the fetch
// deadline, a cancel, an error).
func (o *Orchestrator) recordSearchStop(query string, startPage, next int, completed, firstSync bool, messages int) {
	o.outcome.Pages += next - startPage
	o.outcome.Messages += messages
	if !completed && next > 1 {
		o.resume = &searchResume{query: query, nextPage: next, firstSync: firstSync}
	}
}
