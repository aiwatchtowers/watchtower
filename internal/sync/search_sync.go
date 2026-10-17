package sync

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"

	"github.com/slack-go/slack"
)

// searchDateFormat is the date-only layout search.messages "after:"/"before:"
// filters and the search_last_date watermark both use.
const searchDateFormat = "2006-01-02"

// maxSearchCatchUpDays bounds how far a stalled search-sync will catch up,
// independent of initial_history_days (which governs only a true first
// run). Slack's search.messages index has a practical recall depth beyond
// which reaching further back this way isn't reliable, so a daemon that was
// down longer than this is better served logging the gap and starting from
// the cap than silently skipping the missed messages while stamping the
// watermark to today as if nothing were missed.
const maxSearchCatchUpDays = 30

// searchWindow computes the search.messages "after:" date to query from, the
// size of the gap (in days) since the account was last synced, and whether
// that gap had to be clamped to maxSearchCatchUpDays. It is pure — no Slack
// client, no DB — so the window/clamp math is unit-testable on its own.
//
// initial_history_days applies only on a true first run: an empty lastDate,
// or one that fails to parse (should never happen since Watchtower is the
// only writer, but a corrupt value must not fail the sync). Once a
// watermark exists, the window is always lastDate minus a 2-day overlap
// (Slack's search index has an indexing delay) — initial_history_days plays
// no further part, so a daemon that was down longer than it no longer
// silently skips the gap.
func searchWindow(now time.Time, lastDate string, initialDays int) (after string, gapDays int, clamped bool) {
	if lastDate != "" {
		if t, err := time.Parse(searchDateFormat, lastDate); err == nil {
			candidate := t.AddDate(0, 0, -2)
			// gapDays must be an exact calendar-day count, not a real-instant
			// subtraction: t (and so candidate) comes from time.Parse, which
			// anchors the date-only string at UTC midnight, while now is the
			// actual wall-clock instant in the local zone. Subtracting one
			// from the other mixes a UTC-midnight anchor with a local
			// time-of-day/offset residual, which time-truncates away as an
			// off-by-one whenever the local zone sits ahead of UTC (or, in
			// the other direction, behind it late in the day) — reproduced
			// by TestSearchWindow under a positive UTC offset. Re-anchor
			// "now" at its own calendar date's UTC midnight first so the
			// subtraction is between two midnights and always lands on a
			// whole number of days.
			today, err := time.Parse(searchDateFormat, now.Format(searchDateFormat))
			if err != nil {
				// now.Format always produces a value time.Parse accepts;
				// this can't fail, but fall back to the pre-fix math rather
				// than panic-adjacent silence if it somehow does.
				today = now
			}
			gapDays = int(today.Sub(candidate).Hours() / 24)
			if gapDays > maxSearchCatchUpDays {
				return now.AddDate(0, 0, -maxSearchCatchUpDays).Format(searchDateFormat), gapDays, true
			}
			return candidate.Format(searchDateFormat), gapDays, false
		}
	}

	days := initialDays
	if days <= 0 {
		days = 30
	}
	return now.AddDate(0, 0, -days).Format(searchDateFormat), days, false
}

// recordSearchGap logs the clamped-catch-up warning and best-effort records
// it on the account's error column. The DB write is diagnostic telemetry,
// not correctness-load-bearing: losing it must never abort the sync itself
// (the recordSlackWireError house shape, cmd/sync.go), so a write failure is
// logged and swallowed rather than returned.
func (o *Orchestrator) recordSearchGap(gapDays int, unclampedAfter, clampedAfter string) {
	msg := fmt.Sprintf("search sync: gap of %d days exceeds the %d-day catch-up cap; messages between %s and %s were not fetched",
		gapDays, maxSearchCatchUpDays, unclampedAfter, clampedAfter)
	o.logger.Printf("warning: %s", msg)
	o.searchGapNote = msg // survives Run's closing "ok" auth-state write
	if err := o.db.SetSlackAccountError(o.accountID, msg); err != nil {
		o.logger.Printf("search sync: failed to record gap on account %d: %v", o.accountID, err)
	}
}

// searchChannelType maps a search result CtxChannel to our type string.
func searchChannelType(ch slack.CtxChannel) string {
	if ch.IsMPIM {
		return "group_dm"
	}
	if ch.IsPrivate && strings.HasPrefix(ch.ID, "D") {
		return "dm"
	}
	if ch.IsPrivate {
		return "private"
	}
	return "public"
}

// syncViaSearch uses search.messages to find and save recent messages directly,
// without per-channel conversations.history calls. This dramatically reduces
// API calls for incremental sync (~8-10 calls vs ~50+).
func (o *Orchestrator) syncViaSearch(ctx context.Context) error {
	// Determine search start date.
	lastDate, err := o.db.GetSlackAccountSearchWatermark(o.accountID)
	if err != nil {
		return fmt.Errorf("getting search_last_date: %w", err)
	}
	_, lastErr := time.Parse(searchDateFormat, lastDate)
	if lastDate != "" && lastErr != nil {
		o.logger.Printf("search sync: invalid search_last_date %q, treating as first run", lastDate)
	}
	// A first sync (FirstSyncFrom) also needs an account with no stored
	// messages: one that always fell back to full sync has no watermark but
	// already holds its history (F5). Read before the search saves anything.
	firstSync := false
	if lastErr != nil {
		has, err := o.db.SlackAccountHasMessages(o.accountID)
		if err != nil {
			return fmt.Errorf("search sync: %w", err)
		}
		firstSync = !has
	}

	now := time.Now()
	searchAfter, gapDays, clamped := searchWindow(now, lastDate, o.config.Sync.InitialHistoryDays)
	if clamped {
		unclampedAfter := now.AddDate(0, 0, -gapDays).Format(searchDateFormat)
		o.recordSearchGap(gapDays, unclampedAfter, searchAfter)
	}

	query := fmt.Sprintf("after:%s", searchAfter)
	o.progress.SetSearchAfter(searchAfter)
	o.logger.Printf("search sync: query=%q", query)

	listing := newSearchListing(0)
	completed, totalMessages, seenChannels, err := o.searchAndSave(ctx, query, true, listing)
	if err != nil {
		return err
	}

	// Advance the watermark to today only when every page was fetched. An early
	// break (partial pagination) must leave search_last_date unchanged; otherwise
	// the next incremental sync starts after the unfetched pages and their
	// messages are lost forever.
	if completed {
		today := time.Now().Format("2006-01-02")
		if err := o.db.SetSlackAccountSearchWatermark(o.accountID, today); err != nil {
			return fmt.Errorf("saving search_last_date: %w", err)
		}
		// A completed sync that started with no usable watermark and no
		// stored messages is the account's first: its window start is where
		// a history backfill picks up (FirstSyncFrom). after:D is exclusive,
		// so the first instant this sync covered is D + 1 day (R19); the
		// backfill's top chunk then digests and rolls up day D itself. D is
		// a local date (searchWindow formats a local now), so it is parsed
		// and advanced in the local zone (F7).
		if firstSync {
			if after, ferr := time.ParseInLocation(searchDateFormat, searchAfter, time.Local); ferr == nil {
				o.firstSyncFrom = after.AddDate(0, 0, 1)
			}
		}
	} else {
		o.searchIncomplete = true
		o.logger.Printf("search sync: pagination incomplete, leaving search_last_date unchanged to avoid data loss")
	}
	// Only a completed search can prove a stored message is gone.
	if completed {
		o.diffLiveWindow(listing)
	}

	// Populate discoveredChannelIDs (namespaced) so the full-sync fallback can skip inactive channels.
	o.discoveredChannelIDs = make(map[string]bool, len(seenChannels))
	for chID := range seenChannels {
		o.discoveredChannelIDs[watchtowerslack.Namespace(o.accountID, chID)] = true
	}

	o.logger.Printf("search sync complete: %d channels, %d messages (query=%q, gap_days=%d)",
		len(seenChannels), totalMessages, query, gapDays)
	return nil
}

// slackSearchRange turns [from, to) into search.messages "after:"/"before:"
// dates. Both operators are exclusive and day-granular, so each side is
// widened by a day to keep both edge days inside; the overlap is harmless
// (messages upsert).
func slackSearchRange(from, to time.Time) (after, before string) {
	return from.UTC().AddDate(0, 0, -1).Format(searchDateFormat), to.UTC().AddDate(0, 0, 1).Format(searchDateFormat)
}

// ErrBackfillIncomplete is BackfillSearch's error when Slack's search did not
// return every page (a rate limit or partial pagination): transient, so the
// caller holds the chunk for a later cycle instead of counting a failure
// (R23).
var ErrBackfillIncomplete = errors.New("slack backfill search incomplete (rate limit or partial pages)")

// BackfillSearch saves every message Slack's search finds in [from, to)
// (widened to whole days; the fetch side of the chunk convention in
// internal/historybackfill/chunk.go) without touching the search watermark, the
// progress heartbeat or the account's auth/error state. An incomplete search
// returns an error wrapping ErrBackfillIncomplete.
func (o *Orchestrator) BackfillSearch(ctx context.Context, from, to time.Time) (int, error) {
	after, before := slackSearchRange(from, to)
	completed, saved, _, err := o.searchAndSave(ctx, fmt.Sprintf("after:%s before:%s", after, before), false, nil)
	if err != nil {
		return saved, err
	}
	if !completed {
		return saved, fmt.Errorf("%w: %s..%s", ErrBackfillIncomplete, after, before)
	}
	return saved, nil
}

// FirstSyncFrom reports whether the last Run was the account's completed
// first search sync and, if so, the first instant it covered: UTC midnight
// of the day after its exclusive "after:" date (R19).
func (o *Orchestrator) FirstSyncFrom() (time.Time, bool) {
	return o.firstSyncFrom, !o.firstSyncFrom.IsZero()
}

// searchAndSave runs search.messages for query page by page and saves every
// match (channels, users, messages) through the search save path; completed
// reports that every page was fetched. live=true is the forward sync: it
// feeds the progress heartbeat and records a page-1 rate limit on the
// Orchestrator (searchRateLimited/searchGapNote). live=false (a history
// backfill) touches neither, and a page-1 rate limit just returns
// completed=false with a nil error. Neither mode writes the search watermark.
// A non-nil listing collects every match's key, the matches received and
// page 1's reported total, for a deletion diff (nil collects nothing).
func (o *Orchestrator) searchAndSave(ctx context.Context, query string, live bool, listing *searchListing) (completed bool, totalMessages int, seenChannels map[string]bool, err error) {
	seenChannels = make(map[string]bool)
	seenUsers := make(map[string]bool)
	page := 1

	for {
		select {
		case <-ctx.Done():
			return false, totalMessages, seenChannels, ctx.Err()
		default:
		}

		result, err := o.slackClient.SearchMessages(ctx, query, page)
		if err != nil {
			if isNonFatalError(err) {
				o.logger.Printf("search sync: non-fatal error on page %d, stopping early: %v", page, err)
				if page == 1 {
					if isRateLimitError(err) {
						if !live {
							break
						}
						// Slack is already throttling this token: nothing was
						// fetched, but unlike a scope/permission problem this
						// is transient. Don't return the error (which would
						// have runSearchSync fall back to the far more
						// expensive full sync — exactly wrong while
						// throttled): just end the cycle with the watermark
						// untouched and let the next cycle retry via search.
						// searchRateLimited also makes runSearchSync return
						// early, skipping the read-state/roster refreshes and
						// reactions sync (more calls against the same
						// throttled token) as well as the separate
						// "zero channels discovered" full-sync fallback.
						o.searchRateLimited = true
						o.searchGapNote = "search sync: rate-limited by Slack; retrying next cycle"
						break
					}
					// The very first page failed for any other non-fatal
					// reason (e.g. the token lacks the search:read scope, or
					// a dead account/channel), so nothing was fetched. Return
					// the error so runSearchSync falls back to full sync
					// instead of reporting a silent success with zero
					// messages and advancing the watermark — unchanged from
					// before the rate-limit carve-out above.
					return false, totalMessages, seenChannels, fmt.Errorf("search sync (page %d): %w", page, err)
				}
				// A later page failed after partial progress: keep what we fetched
				// but leave the watermark untouched (completed stays false) so the
				// next run re-covers the unfetched pages instead of skipping them.
				break
			}
			return false, totalMessages, seenChannels, fmt.Errorf("search sync (page %d): %w", page, err)
		}

		if listing != nil {
			if page == 1 {
				listing.total = result.Total
			}
			listing.matched += len(result.Messages)
		}
		if len(result.Messages) == 0 {
			completed = true
			break
		}

		// Convert search messages to db.Message and collect channel/user info.
		// msg.Channel.ID/msg.User arrive raw from search.messages; seenChannels/
		// seenUsers dedupe on the raw id, but everything written to the DB
		// (EnsureChannel/EnsureUser/db.Message/discoveredChannelIDs) is namespaced.
		dbMsgs := make([]db.Message, 0, len(result.Messages))
		for _, msg := range result.Messages {
			namespacedChannelID := watchtowerslack.Namespace(o.accountID, msg.Channel.ID)
			namespacedUserID := watchtowerslack.Namespace(o.accountID, msg.User)

			// Ensure channel
			if msg.Channel.ID != "" && !seenChannels[msg.Channel.ID] {
				seenChannels[msg.Channel.ID] = true
				chType := searchChannelType(msg.Channel)
				name := msg.Channel.Name
				if name == "" {
					name = msg.Channel.ID
				}
				// For DMs, Slack search returns the user ID as the channel name.
				// Extract it so we can resolve to a display name later.
				var dmUserID string
				if chType == "dm" && strings.HasPrefix(name, "U") {
					dmUserID = watchtowerslack.Namespace(o.accountID, name)
				}
				if err := o.db.EnsureChannel(namespacedChannelID, name, chType, dmUserID); err != nil {
					return false, totalMessages, seenChannels, fmt.Errorf("ensuring channel %s: %w", namespacedChannelID, err)
				}
			}

			// Ensure user
			if msg.User != "" && !seenUsers[msg.User] {
				seenUsers[msg.User] = true
				userName := msg.Username
				if userName == "" {
					userName = msg.User
				}
				if err := o.db.EnsureUser(namespacedUserID, userName); err != nil {
					return false, totalMessages, seenChannels, fmt.Errorf("ensuring user %s: %w", namespacedUserID, err)
				}
			}

			// Convert SearchMessage to db.Message.
			// search.messages doesn't return thread_ts or reply_count,
			// but permalink contains thread_ts for threaded replies:
			//   ...p1234567890123456?thread_ts=1234567890.123456
			threadTS := extractThreadTSFromPermalink(msg.Permalink)
			if listing != nil {
				listing.seen[db.SlackMessageKey{ChannelID: namespacedChannelID, TS: msg.Timestamp}] = struct{}{}
			}

			dbMsgs = append(dbMsgs, db.Message{
				ChannelID:  namespacedChannelID,
				TS:         msg.Timestamp,
				UserID:     namespacedUserID,
				Text:       msg.Text,
				ThreadTS:   threadTS,
				ReplyCount: 0,
				IsEdited:   false,
				IsDeleted:  false,
				Subtype:    "",
				Permalink:  msg.Permalink,
			})
		}

		// Batch upsert messages
		if len(dbMsgs) > 0 {
			count, err := o.upsertSearchPage(dbMsgs)
			if err != nil {
				return false, totalMessages, seenChannels, err
			}
			totalMessages += count
			if live {
				o.progress.AddMessages(count)
			}
		}

		if live {
			o.progress.SetDiscovery(page, result.Pages, len(seenChannels), len(seenUsers))
		}
		o.logger.Printf("search sync: page %d/%d, %d channels, %d users, %d messages",
			page, result.Pages, len(seenChannels), len(seenUsers), totalMessages)

		if page >= result.Pages {
			completed = true
			break
		}
		page++
	}

	if live {
		o.progress.SetDiscovery(page, page, len(seenChannels), len(seenUsers))
	}
	o.logger.Printf("search: %d channels, %d users, %d messages from %d pages (query=%q, completed=%t)",
		len(seenChannels), len(seenUsers), totalMessages, page, query, completed)
	return completed, totalMessages, seenChannels, nil
}

// extractThreadTSFromPermalink parses thread_ts from a Slack permalink URL.
// Permalink format: https://...slack.com/archives/C.../p1234?thread_ts=1234567890.123456
func extractThreadTSFromPermalink(permalink string) sql.NullString {
	const marker = "thread_ts="
	idx := strings.Index(permalink, marker)
	if idx < 0 {
		return sql.NullString{}
	}
	ts := permalink[idx+len(marker):]
	// Trim any trailing query params
	if ampIdx := strings.IndexByte(ts, '&'); ampIdx >= 0 {
		ts = ts[:ampIdx]
	}
	if ts == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: ts, Valid: true}
}

// parseSlackTS parses a Slack message timestamp ("1234567890.123456") into a time.Time.
func parseSlackTS(ts string) (time.Time, error) {
	parts := strings.SplitN(ts, ".", 2)
	if len(parts) == 0 || parts[0] == "" {
		return time.Time{}, fmt.Errorf("invalid slack timestamp: %q", ts)
	}
	sec, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid slack timestamp: %q", ts)
	}
	return time.Unix(sec, 0), nil
}

// upsertSearchPage wraps a batch upsert in its own function scope so that
// defer tx.Rollback() runs per-page rather than accumulating in the caller's loop.
func (o *Orchestrator) upsertSearchPage(msgs []db.Message) (int, error) {
	tx, err := o.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("beginning transaction: %w", err)
	}
	defer tx.Rollback()

	count, err := o.db.UpsertMessageBatch(tx, msgs)
	if err != nil {
		return 0, fmt.Errorf("upserting search messages: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing search messages: %w", err)
	}

	// The search path — not the per-channel history path — is what an ordinary
	// incremental sync runs, so the hook belongs on both or the detector stays
	// dead outside --full/--channels runs.
	o.detectJiraKeys(msgs)
	return count, nil
}
