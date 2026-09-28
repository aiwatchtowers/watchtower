package sync

import (
	"context"
	"database/sql"
	"encoding/json"
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

// maxSearchResultPages is Slack's documented practical cap on how many pages
// a single search.messages query serves: 100 pages of 100 results each is
// the ~10k-match ceiling. Past it, page 101 either errors or comes back with
// zero matches even though the response's own "pages" field may still claim
// more exist, so pagination must never be attempted past this cap — a
// window this wide needs splitting instead (runSearchWindow).
const maxSearchResultPages = 100

// maxSearchSplitDepth bounds how many times an over-full window is bisected
// by date before giving up on shrinking it further. search.messages date
// filters ("after:"/"before:") have only day granularity, so bisection stops
// once a window is down to a single day regardless of this cap; the real
// trigger (a first-run or clamped catch-up window, capped at
// maxSearchCatchUpDays = 30 days) resolves in a couple of splits, so this
// floor is a safety net against runaway recursion, not the expected path.
const maxSearchSplitDepth = 10

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
			gapDays = int(now.Sub(candidate).Hours() / 24)
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

// recordUnsplittableSearchGap logs and records (same best-effort shape as
// recordSearchGap) a window that still exceeds maxSearchResultPages after
// bisecting all the way down to a single day — the finest granularity
// search.messages date filters allow. Retrying the same over-full window
// every cycle would burn maxSearchResultPages Tier-2 calls each time for no
// progress, so it is instead accepted as a permanent, logged gap and skipped.
func (o *Orchestrator) recordUnsplittableSearchGap(after, before string) {
	label := before
	if label == "" {
		label = "now"
	}
	msg := fmt.Sprintf("search sync: window %s to %s still exceeds %d search.messages pages even at 1-day granularity; messages in that window were not fetched",
		after, label, maxSearchResultPages)
	o.logger.Printf("warning: %s", msg)
	o.searchGapNote = msg
	if err := o.db.SetSlackAccountError(o.accountID, msg); err != nil {
		o.logger.Printf("search sync: failed to record gap on account %d: %v", o.accountID, err)
	}
}

// searchWindowEnd is the date a fully-completed window reaches: its own
// upper bound, or today when the window was open-ended.
func searchWindowEnd(before string) string {
	if before != "" {
		return before
	}
	return time.Now().Format(searchDateFormat)
}

// bisectSearchDate splits an [after, before) date window (before == "" means
// open-ended through now) at its midpoint. It reports ok=false once the
// window is already down to a single day — search.messages date filters
// have no finer granularity to split with.
func bisectSearchDate(after, before string, now time.Time) (string, bool) {
	a, err := time.Parse(searchDateFormat, after)
	if err != nil {
		return "", false
	}
	end := now
	if before != "" {
		b, err := time.Parse(searchDateFormat, before)
		if err != nil {
			return "", false
		}
		end = b
	}
	days := int(end.Sub(a).Hours() / 24)
	if days < 2 {
		return "", false
	}
	return a.AddDate(0, 0, days/2).Format(searchDateFormat), true
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

// searchSyncState accumulates results across every window a syncViaSearch
// pass pages through — a single top-level window ordinarily, more when
// maxSearchResultPages forces a date-range split (runSearchWindow).
type searchSyncState struct {
	seenChannels  map[string]bool
	seenUsers     map[string]bool
	totalMessages int
	pagesFetched  int
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
	if lastDate != "" {
		if _, err := time.Parse(searchDateFormat, lastDate); err != nil {
			o.logger.Printf("search sync: invalid search_last_date %q, treating as first run", lastDate)
		}
	}

	now := time.Now()
	searchAfter, gapDays, clamped := searchWindow(now, lastDate, o.config.Sync.InitialHistoryDays)
	if clamped {
		unclampedAfter := now.AddDate(0, 0, -gapDays).Format(searchDateFormat)
		o.recordSearchGap(gapDays, unclampedAfter, searchAfter)
	}

	o.progress.SetSearchAfter(searchAfter)

	state := &searchSyncState{
		seenChannels: make(map[string]bool),
		seenUsers:    make(map[string]bool),
	}

	reachedThrough, err := o.runSearchWindow(ctx, state, searchAfter, "", 0)
	if err != nil {
		return err
	}

	// Advance the watermark only as far as fully paged. An incomplete window
	// (partial pagination, or a split window whose newer half never
	// finished) must leave search_last_date unchanged; otherwise the next
	// incremental sync starts after unfetched messages and they are lost
	// forever.
	if reachedThrough != "" {
		if err := o.db.SetSlackAccountSearchWatermark(o.accountID, reachedThrough); err != nil {
			return fmt.Errorf("saving search_last_date: %w", err)
		}
	} else {
		o.logger.Printf("search sync: pagination incomplete, leaving search_last_date unchanged to avoid data loss")
	}

	// Populate discoveredChannelIDs (namespaced) so the full-sync fallback can skip inactive channels.
	o.discoveredChannelIDs = make(map[string]bool, len(state.seenChannels))
	for chID := range state.seenChannels {
		o.discoveredChannelIDs[watchtowerslack.Namespace(o.accountID, chID)] = true
	}

	o.progress.SetDiscovery(state.pagesFetched, state.pagesFetched, len(state.seenChannels), len(state.seenUsers))
	o.logger.Printf("search sync complete: %d channels, %d users, %d messages from %d pages (after=%q, gap_days=%d)",
		len(state.seenChannels), len(state.seenUsers), state.totalMessages, state.pagesFetched, searchAfter, gapDays)
	return nil
}

// runSearchWindow pages one after/before search.messages window ("" before
// means open-ended, through "now") into state. When the window's own page 1
// reports more than maxSearchResultPages pages, it is never paged past page
// 1 at all: instead the window is bisected by date (bisectSearchDate) and
// each half is paged in turn, older half first, so a first run or a
// clamped catch-up spanning more than Slack's ~10k-match search index can
// still make progress instead of looping the same 100 pages forever without
// ever advancing the watermark. It returns the date through which the
// window is now known to be fully covered (empty if nothing new completed),
// so the caller can advance the watermark that far even when only part of a
// split window finished.
func (o *Orchestrator) runSearchWindow(ctx context.Context, state *searchSyncState, after, before string, depth int) (string, error) {
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	default:
	}

	query := "after:" + after
	if before != "" {
		query += " before:" + before
	}
	o.logger.Printf("search sync: query=%q", query)

	result, err := o.slackClient.SearchMessages(ctx, query, 1)
	if err != nil {
		if isNonFatalError(err) {
			o.logger.Printf("search sync: non-fatal error on page 1, stopping early: %v", err)
			if depth == 0 && isScopeError(err) {
				// The very first page of the whole sync failed because the
				// token lacks search access, so nothing was fetched at all.
				// Return the error so runSearchSync falls back to full sync
				// instead of reporting a silent success with zero messages
				// and advancing the watermark.
				return "", fmt.Errorf("search sync (page 1): %w", err)
			}
			// A rate limit (or any other non-fatal error) on this window's
			// first page: nothing new completed here, but this must not
			// trigger the far more expensive full-sync fallback while Slack
			// is already throttling the token, nor abort the sync outright —
			// the next cycle resumes from wherever the watermark stands.
			// searchRateLimited also suppresses runSearchSync's separate
			// "zero channels discovered" fallback for the same reason.
			o.searchRateLimited = true
			return "", nil
		}
		return "", fmt.Errorf("search sync (page 1): %w", err)
	}

	if result.Pages > maxSearchResultPages {
		mid, ok := bisectSearchDate(after, before, time.Now())
		if !ok || depth >= maxSearchSplitDepth {
			o.recordUnsplittableSearchGap(after, before)
			return searchWindowEnd(before), nil
		}
		reached, err := o.runSearchWindow(ctx, state, after, mid, depth+1)
		if err != nil {
			return "", err
		}
		if reached != mid {
			// The older half didn't fully complete: stop here rather than
			// attempt the newer half out of order.
			return reached, nil
		}
		return o.runSearchWindow(ctx, state, mid, before, depth+1)
	}

	completed, err := o.pageSearchWindow(ctx, state, query, result)
	if err != nil {
		return "", err
	}
	if completed {
		return searchWindowEnd(before), nil
	}
	return "", nil
}

// pageSearchWindow pages one window's already-fetched page 1 result (and any
// further pages up to result.Pages, capped at maxSearchResultPages by the
// caller) into state.
func (o *Orchestrator) pageSearchWindow(ctx context.Context, state *searchSyncState, query string, result *watchtowerslack.SearchResult) (bool, error) {
	page := 1
	for {
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		default:
		}

		if page > 1 {
			var err error
			result, err = o.slackClient.SearchMessages(ctx, query, page)
			if err != nil {
				if isNonFatalError(err) {
					o.logger.Printf("search sync: non-fatal error on page %d, stopping early: %v", page, err)
					// A later page failed after partial progress: keep what
					// we fetched but report incomplete so the next run
					// re-covers the unfetched pages instead of skipping them.
					return false, nil
				}
				return false, fmt.Errorf("search sync (page %d): %w", page, err)
			}
		}

		if len(result.Messages) == 0 {
			return true, nil
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
			if msg.Channel.ID != "" && !state.seenChannels[msg.Channel.ID] {
				state.seenChannels[msg.Channel.ID] = true
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
					return false, fmt.Errorf("ensuring channel %s: %w", namespacedChannelID, err)
				}
			}

			// Ensure user
			if msg.User != "" && !state.seenUsers[msg.User] {
				state.seenUsers[msg.User] = true
				userName := msg.Username
				if userName == "" {
					userName = msg.User
				}
				if err := o.db.EnsureUser(namespacedUserID, userName); err != nil {
					return false, fmt.Errorf("ensuring user %s: %w", namespacedUserID, err)
				}
			}

			// Convert SearchMessage to db.Message.
			// search.messages doesn't return thread_ts or reply_count,
			// but permalink contains thread_ts for threaded replies:
			//   ...p1234567890123456?thread_ts=1234567890.123456
			rawJSON, err := json.Marshal(msg)
			if err != nil {
				o.logger.Printf("warning: failed to marshal search message %s: %v", msg.Timestamp, err)
				rawJSON = []byte("{}")
			}

			threadTS := extractThreadTSFromPermalink(msg.Permalink)

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
				RawJSON:    string(rawJSON),
			})
		}

		// Batch upsert messages
		if len(dbMsgs) > 0 {
			count, err := o.upsertSearchPage(dbMsgs)
			if err != nil {
				return false, err
			}
			state.totalMessages += count
			o.progress.AddMessages(count)
		}

		state.pagesFetched = page
		o.progress.SetDiscovery(page, result.Pages, len(state.seenChannels), len(state.seenUsers))
		o.logger.Printf("search sync: page %d/%d, %d channels, %d users, %d messages",
			page, result.Pages, len(state.seenChannels), len(state.seenUsers), state.totalMessages)

		if page >= result.Pages {
			return true, nil
		}
		page++
	}
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
