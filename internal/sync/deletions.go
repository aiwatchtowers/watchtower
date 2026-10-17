package sync

import (
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sourcediff"
)

// liveDiffLag keeps the newest hours out of the live diff: search indexes
// new messages with a lag, so a message missing from them may not be gone.
const liveDiffLag = 2 * time.Hour

// searchListing collects what one search.messages run returned, so a
// completed run can be diffed against the stored rows it covered.
type searchListing struct {
	seen     map[db.SlackMessageKey]struct{}
	matched  int // matches received across pages
	total    int // result.Total from page 1
	maxPages int // 0 = no cap (the rolling sweep sets one and adds tooLarge)
}

func newSearchListing(maxPages int) *searchListing {
	return &searchListing{seen: make(map[db.SlackMessageKey]struct{}), maxPages: maxPages}
}

// complete reports that every match Slack counted was received. A search
// stops at 100 pages, so page >= pages alone does not prove a full listing.
func (l *searchListing) complete() bool { return l.matched >= l.total }

// liveDiffWindow is the part of a forward search the diff may judge: UTC
// today up to now − 2 h. It is empty (to <= from) in the first 2 h of a UTC
// day. searchWindow keeps after: at or before local today − 2, so the query
// always covers it.
func liveDiffWindow(now time.Time) (from, to time.Time) {
	now = now.UTC()
	from = time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return from, now.Add(-liveDiffLag)
}

// tombstoneMissing tombstones the account's stored plain messages in
// [from, to) that the listing did not return, unless sourcediff.Check
// refuses (an empty listing, or more than half missing). Only channels the
// listing returned at least one message from inside the range are judged: a
// channel search does not see (hidden from search, shared from another
// org) would otherwise lose every row each cycle and never heal. Every skip
// is logged. The stored set is read and diffed before the short writes.
func (o *Orchestrator) tombstoneMissing(l *searchListing, from, to time.Time) (int, error) {
	all, err := o.db.LiveSlackMessageKeys(o.accountID, float64(from.Unix()), float64(to.Unix()))
	if err != nil {
		return 0, err
	}
	listedIn := make(map[string]int)
	listed := 0
	for k := range l.seen {
		at, err := parseSlackTS(k.TS)
		if err != nil {
			continue
		}
		if !at.Before(from) && at.Before(to) {
			listedIn[k.ChannelID]++
			listed++
		}
	}
	rangeDesc := from.UTC().Format(time.RFC3339) + ".." + to.UTC().Format(time.RFC3339)
	var stored, missing []db.SlackMessageKey
	unlisted := make(map[string]bool)
	for _, k := range all {
		if listedIn[k.ChannelID] == 0 {
			unlisted[k.ChannelID] = true
			continue
		}
		stored = append(stored, k)
		if _, ok := l.seen[k]; !ok {
			missing = append(missing, k)
		}
	}
	if len(unlisted) > 0 {
		o.logger.Printf("slack deletions: account %d range %s: skipped %d channels with stored messages but none listed",
			o.accountID, rangeDesc, len(unlisted))
	}
	ok, reason := sourcediff.Check(len(stored), listed, len(missing), sourcediff.SlackFloors)
	if !ok {
		if reason != "" {
			o.logger.Printf("slack deletions: account %d range %s: skipped: %s", o.accountID, rangeDesc, reason)
		}
		return 0, nil
	}
	n, err := o.db.TombstoneSlackMessages(missing)
	if err != nil {
		return 0, err
	}
	o.logger.Printf("slack deletions: account %d range %s: tombstoned %d of %d stored messages (%d listed)",
		o.accountID, rangeDesc, n, len(stored), listed)
	return n, nil
}

// diffLiveWindow tombstones messages deleted at the source inside the live
// window of a completed forward search. It is best-effort: an incomplete
// listing is skipped and an error is logged, never failing the sync.
func (o *Orchestrator) diffLiveWindow(l *searchListing) {
	from, to := liveDiffWindow(o.clock())
	if !to.After(from) {
		return
	}
	if !l.complete() {
		o.logger.Printf("slack deletions: account %d range %s..%s: skipped: received %d of %d matches",
			o.accountID, from.Format(time.RFC3339), to.Format(time.RFC3339), l.matched, l.total)
		return
	}
	if _, err := o.tombstoneMissing(l, from, to); err != nil {
		o.logger.Printf("slack deletions: account %d: live diff failed: %v", o.accountID, err)
	}
}
