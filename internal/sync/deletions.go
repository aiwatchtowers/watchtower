package sync

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sourcediff"

	"github.com/slack-go/slack"
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

// searchLatestDayStart is how far after UTC midnight a calendar day can
// start in the searcher's Slack profile timezone (UTC-12 at the latest).
const searchLatestDayStart = 12 * time.Hour

// searchListing collects what one search.messages run returned, so a
// completed run can be diffed against the stored rows it covered.
type searchListing struct {
	seen     map[db.SlackMessageKey]struct{}
	pages    []pageEdge // first and last match ts of every page, in API order
	matched  int        // matches received across pages
	total    int        // result.Total from page 1
	maxPages int        // 0 = no cap; the rolling sweep sets sweepMaxPages
	tooLarge bool       // page 1 reported more than maxPages pages; only page 1 was fetched
	badEdge  bool       // a page edge ts did not parse, so page boundaries are unknown
}

// pageEdge is the first and last match time of one received page.
type pageEdge struct{ first, last time.Time }

// addPage records a received page's edge timestamps (in API order).
func (l *searchListing) addPage(matches []slack.SearchMessage) {
	if len(matches) == 0 {
		return
	}
	first, ferr := parseSlackTS(matches[0].Timestamp)
	last, lerr := parseSlackTS(matches[len(matches)-1].Timestamp)
	if ferr != nil || lerr != nil {
		// An unparseable edge leaves no boundary to guard; the listing is
		// then never diffed (see tombstoneMissing).
		l.badEdge = true
		return
	}
	l.pages = append(l.pages, pageEdge{first: first, last: last})
}

// atPageBoundary reports that at lies in the closed range between the last
// match of one page and the first match of the next. Offset paging can skip
// a match there when the result set shifts mid-paging (a deletion moves the
// next page's first match back onto a fetched page while a new arrival keeps
// the count), so a row missing there is not proven gone.
func (l *searchListing) atPageBoundary(at time.Time) bool {
	for i := 0; i+1 < len(l.pages); i++ {
		lo, hi := l.pages[i].last, l.pages[i+1].first
		if hi.Before(lo) {
			lo, hi = hi, lo
		}
		if !at.Before(lo) && !at.After(hi) {
			return true
		}
	}
	return false
}

func newSearchListing(maxPages int) *searchListing {
	return &searchListing{seen: make(map[db.SlackMessageKey]struct{}), maxPages: maxPages}
}

// complete reports that every match Slack counted was received. A search
// stops at 100 pages, so page >= pages alone does not prove a full listing.
func (l *searchListing) complete() bool { return l.matched >= l.total }

// liveDiffWindow is the part of a forward search the diff may judge: UTC
// today up to now − 2 h, clamped to what the query's after: date provably
// covers. It is empty (to <= from) in the first 2 h of a UTC day.
//
// after: is a machine-local date (searchWindow, local today − 2 at most)
// and Slack reads it in the searcher's profile timezone: after:X returns
// profile-local dates > X, so coverage starts at X+1 00:00 profile-local,
// which is at the latest X+1 12:00Z (UTC−12). When the machine's local date
// runs ahead of UTC (east of UTC, past local midnight) X+1 can be UTC today,
// and from is moved to X+1 12:00Z; the early-UTC-day hours left out are the
// sweep's. to is never widened. An unparseable after gives an empty window.
func liveDiffWindow(now time.Time, after string) (from, to time.Time) {
	now = now.UTC()
	from = time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	to = now.Add(-liveDiffLag)
	x, err := time.Parse(searchDateFormat, after)
	if err != nil {
		return from, from
	}
	if covered := x.AddDate(0, 0, 1).Add(searchLatestDayStart); covered.After(from) {
		from = covered
	}
	return from, to
}

// tombstoneMissing tombstones the account's stored plain messages in
// [from, to) that the listing did not return, unless sourcediff.Check
// refuses (an empty listing, or more than half missing). Only channels the
// listing returned at least one message from inside the range are judged: a
// channel search does not see (hidden from search, shared from another
// org) would otherwise lose every row each cycle and never heal. A missing
// row at a page boundary (atPageBoundary) or with an unparseable ts is not
// judged either, and a listing with an unparseable page edge (badEdge) is
// not diffed at all. Every skip is logged. The stored set is read and diffed before the short writes.
func (o *Orchestrator) tombstoneMissing(l *searchListing, from, to time.Time) error {
	if l.badEdge {
		return nil // callers log and skip a badEdge listing first
	}
	all, err := o.db.LiveSlackMessageKeys(o.accountID, float64(from.Unix()), float64(to.Unix()))
	if err != nil {
		return err
	}
	listedIn, listed := l.listedIn(from, to)
	c := l.candidates(all, listedIn)
	rangeDesc := from.UTC().Format(time.RFC3339) + ".." + to.UTC().Format(time.RFC3339)
	o.logCandidateSkips(rangeDesc, c)
	ok, reason := sourcediff.Check(len(c.stored), listed, len(c.missing), sourcediff.SlackFloors)
	if !ok {
		if reason != "" {
			o.logger.Printf("slack deletions: account %d range %s: skipped: %s", o.accountID, rangeDesc, reason)
		}
		return nil
	}
	n, err := o.db.TombstoneSlackMessages(c.missing)
	if err != nil {
		if n > 0 {
			o.logger.Printf("slack deletions: account %d range %s: tombstoned %d messages before failing: %v",
				o.accountID, rangeDesc, n, err)
		}
		return err
	}
	o.logger.Printf("slack deletions: account %d range %s: tombstoned %d of %d stored messages (%d listed)",
		o.accountID, rangeDesc, n, len(c.stored), listed)
	return nil
}

// listedIn counts the listing's messages inside [from, to), per channel and
// in total.
func (l *searchListing) listedIn(from, to time.Time) (perChannel map[string]int, total int) {
	perChannel = make(map[string]int)
	for k := range l.seen {
		at, err := parseSlackTS(k.TS)
		if err != nil {
			continue
		}
		if !at.Before(from) && at.Before(to) {
			perChannel[k.ChannelID]++
			total++
		}
	}
	return perChannel, total
}

// diffCandidates is the stored set of a range split for the diff: the rows
// judged (stored), those of them to tombstone (missing), and what was not
// judged and why.
type diffCandidates struct {
	stored, missing   []db.SlackMessageKey
	unlistedChannels  int
	atBoundary, badTS int
}

// candidates splits the stored rows of a range: rows of channels the listing
// returned nothing from are not judged, and a missing row with an
// unparseable ts or at a page boundary is not tombstoned.
func (l *searchListing) candidates(all []db.SlackMessageKey, listedIn map[string]int) diffCandidates {
	var c diffCandidates
	unlisted := make(map[string]bool)
	for _, k := range all {
		if listedIn[k.ChannelID] == 0 {
			unlisted[k.ChannelID] = true
			continue
		}
		c.stored = append(c.stored, k)
		if _, ok := l.seen[k]; ok {
			continue
		}
		at, err := parseSlackTS(k.TS)
		switch {
		case err != nil:
			c.badTS++
		case l.atPageBoundary(at):
			c.atBoundary++
		default:
			c.missing = append(c.missing, k)
		}
	}
	c.unlistedChannels = len(unlisted)
	return c
}

// logCandidateSkips logs each kind of row candidates did not judge.
func (o *Orchestrator) logCandidateSkips(rangeDesc string, c diffCandidates) {
	if c.unlistedChannels > 0 {
		o.logger.Printf("slack deletions: account %d range %s: skipped %d channels with stored messages but none listed",
			o.accountID, rangeDesc, c.unlistedChannels)
	}
	if c.badTS > 0 {
		o.logger.Printf("slack deletions: account %d range %s: skipped %d missing messages with an unparseable ts",
			o.accountID, rangeDesc, c.badTS)
	}
	if c.atBoundary > 0 {
		o.logger.Printf("slack deletions: account %d range %s: skipped %d missing messages at a page boundary",
			o.accountID, rangeDesc, c.atBoundary)
	}
}

// diffLiveWindow tombstones messages deleted at the source inside the live
// window of a completed forward search whose query used after: date after.
// It is best-effort: an incomplete listing is skipped and an error is
// logged, never failing the sync.
func (o *Orchestrator) diffLiveWindow(l *searchListing, after string) {
	from, to := liveDiffWindow(o.clock(), after)
	if !to.After(from) {
		return
	}
	if !l.complete() {
		o.logger.Printf("slack deletions: account %d range %s..%s: skipped: received %d of %d matches",
			o.accountID, from.Format(time.RFC3339), to.Format(time.RFC3339), l.matched, l.total)
		return
	}
	if l.badEdge {
		o.logger.Printf("slack deletions: account %d range %s..%s: skipped: a page edge ts did not parse, page boundaries unknown",
			o.accountID, from.Format(time.RFC3339), to.Format(time.RFC3339))
		return
	}
	if err := o.tombstoneMissing(l, from, to); err != nil {
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
// (deletion_sweep_day) advances after a finished day, a guard refusal, a
// day over sweepMaxPages pages or a listing with an unparseable page edge
// (badEdge, which a retry would hit again); a rate limit or partial pages
// leave it, so the day is retried next cycle.
func (o *Orchestrator) sweepDeletionDay(ctx context.Context) error {
	day, ok, err := o.nextSweepDay()
	if err != nil || !ok {
		return err
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
	case listing.badEdge:
		o.logger.Printf("slack deletion sweep: account %d day %s: a page edge ts did not parse, page boundaries unknown, skipped",
			o.accountID, day)
	default:
		if err := o.tombstoneMissing(listing, from, to); err != nil {
			return err
		}
	}
	return o.db.SetSlackDeletionSweepDay(o.accountID, day)
}

// nextSweepDay picks the stored day the sweep diffs next: the newest stored
// day before the cursor (deletion_sweep_day) and before the live window,
// wrapping to the newest stored day once the cursor passed the oldest. ok is
// false when no day is stored.
func (o *Orchestrator) nextSweepDay() (day string, ok bool, err error) {
	now := o.clock().UTC().Add(-liveDiffLag)
	ceiling := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	cursor, err := o.db.SlackDeletionSweepDay(o.accountID)
	if err != nil {
		return "", false, err
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
	day, ok, err = o.db.NextSlackSweepDay(o.accountID, float64(before.Unix()))
	if err != nil || ok || !cursorSet {
		return day, ok, err
	}
	return o.db.NextSlackSweepDay(o.accountID, float64(ceiling.Unix()))
}
