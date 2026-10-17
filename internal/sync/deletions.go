package sync

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sourcediff"
)

// sweepMaxPages caps the search pages the rolling sweep spends per cycle:
// about 30 s of the shared ~20 req/min Tier-2 budget (internal/slack/
// ratelimit.go). It applies to the widened query (sweepSearchRange, about
// three days), so the effective cap for the swept day itself is lower. A
// day whose query needs more is skipped, not split.
const sweepMaxPages = 10

// liveDiffLag keeps the newest hours out of the live diff: search indexes
// new messages with a lag, so a message missing from them may not be gone.
const liveDiffLag = 2 * time.Hour

// searchListing collects what one search.messages run returned, so a
// completed run can be diffed against the stored rows it covered.
type searchListing struct {
	seen     map[db.SlackMessageKey]struct{}
	matched  int  // matches received across pages
	total    int  // result.Total from page 1
	maxPages int  // 0 = no cap; the rolling sweep sets sweepMaxPages
	tooLarge bool // page 1 reported more than maxPages pages; only page 1 was fetched
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

// sweepSearchRange gives the search dates for the UTC day [from, to). Slack
// reads after:/before: as dates in the searcher's own timezone, which can be
// anywhere from UTC-12 to UTC+14, so the day is widened by one more day at
// the start than slackSearchRange gives: after: from-2, before: to+1, i.e.
// local days from-1..to. Only [from, to) is diffed.
func sweepSearchRange(from, to time.Time) (after, before string) {
	return slackSearchRange(from.AddDate(0, 0, -1), to)
}

// sweepDeletionDay diffs one stored past day (before the live window)
// against search.messages per cycle, walking from the newest stored day back
// to the oldest and then wrapping, so deletions and retention purges older
// than the live window are caught and edited text is refreshed. The cursor
// (deletion_sweep_day) advances after a finished day, a guard refusal or a
// day over sweepMaxPages pages; a rate limit or partial pages leave it, so
// the day is retried next cycle.
func (o *Orchestrator) sweepDeletionDay(ctx context.Context) error {
	now := o.clock().UTC().Add(-liveDiffLag)
	ceiling := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	cursor, err := o.db.SlackDeletionSweepDay(o.accountID)
	if err != nil {
		return err
	}
	before := ceiling
	cursorSet := false
	if cursor != "" {
		if at, perr := time.Parse(searchDateFormat, cursor); perr == nil {
			cursorSet = true
			if at.Before(ceiling) {
				before = at
			}
		} else {
			o.logger.Printf("slack deletion sweep: account %d: invalid cursor %q, starting from the newest day", o.accountID, cursor)
		}
	}
	day, ok, err := o.db.NextSlackSweepDay(o.accountID, float64(before.Unix()))
	if err != nil {
		return err
	}
	if !ok && cursorSet {
		day, ok, err = o.db.NextSlackSweepDay(o.accountID, float64(ceiling.Unix()))
		if err != nil {
			return err
		}
	}
	if !ok {
		return nil
	}
	from, err := time.Parse(searchDateFormat, day)
	if err != nil {
		return fmt.Errorf("slack deletion sweep: parsing day %q: %w", day, err)
	}
	to := from.AddDate(0, 0, 1)

	after, beforeDate := sweepSearchRange(from, to)
	listing := newSearchListing(sweepMaxPages)
	completed, _, _, err := o.searchAndSave(ctx, fmt.Sprintf("after:%s before:%s", after, beforeDate), false, listing)
	if err != nil {
		return err
	}
	switch {
	case listing.tooLarge:
		o.logger.Printf("slack deletion sweep: %s has more than %d pages, skipped (query %s..%s)", day, sweepMaxPages, after, beforeDate)
	case !completed || !listing.complete():
		o.logger.Printf("slack deletion sweep: account %d day %s: incomplete listing (received %d of %d matches), retrying next cycle",
			o.accountID, day, listing.matched, listing.total)
		return nil
	default:
		if _, err := o.tombstoneMissing(listing, from, to); err != nil {
			return err
		}
	}
	return o.db.SetSlackDeletionSweepDay(o.accountID, day)
}
