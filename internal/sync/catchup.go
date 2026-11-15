package sync

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	watchtowerslack "watchtower/internal/slack"
)

// catchupPagesPerRun caps the conversations.history pages one run spends on
// a Sync again catch-up (replies of threaded parents come on top), so a
// catch-up never competes with the forward search.
const catchupPagesPerRun = 5

// loadSyncExcluded reads the account's Stop-syncing channels for this pass.
func (o *Orchestrator) loadSyncExcluded() error {
	ids, err := o.db.SyncExcludedChannelIDs(o.accountID)
	if err != nil {
		return err
	}
	o.syncExcluded = ids
	return nil
}

// mentionsOwner reports whether a message text mentions the account's user
// (<@U…> or <@U…|name>): such a message is stored even from an excluded
// channel. False when the account has not resolved its user.
func (o *Orchestrator) mentionsOwner(text string) bool {
	raw, ok := o.ownerRawID()
	if !ok {
		return false
	}
	return strings.Contains(text, "<@"+raw+">") || strings.Contains(text, "<@"+raw+"|")
}

// runCatchups fetches the excluded period of the account's oldest pending
// Sync again catch-up, at most catchupPagesPerRun history pages, one channel
// per run. conversations.history returns the newest messages first, so the
// walk goes from the top down with a persisted upper bound, never a stored
// cursor (a cursor can expire and does not survive a restart): every page
// asks for (catchup_from, catchup_to) exclusive, and after saving it the
// bound moves down to the page's oldest ts (AdvanceCatchup). Slack ts are
// unique per channel, so nothing is skipped or fetched twice. A page without
// more ends the catch-up (FinishCatchup). A rate limit, the deadline or a
// restart leaves the bound at the last saved page. The rows keep their post
// time as synced_at (backfilling), so they never reach the Inbox; mentions
// of that period were stored while it was excluded.
func (o *Orchestrator) runCatchups(ctx context.Context) error {
	pending, err := o.db.PendingCatchups(o.accountID)
	if err != nil || len(pending) == 0 {
		return err
	}
	c := pending[0]
	o.backfilling = true
	defer func() { o.backfilling = false }()

	_, rawID, _ := watchtowerslack.SplitAccountID(c.ChannelID)
	to := c.To
	for range catchupPagesPerRun {
		if err := ctx.Err(); err != nil {
			return err
		}
		resp, err := o.slackClient.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{
			ChannelID: rawID,
			Oldest:    formatSlackTS(c.From),
			Latest:    formatSlackTS(to),
			Limit:     slackPageSize,
		})
		if err != nil {
			if isNonFatalError(err) && !isRateLimitError(err) {
				// The channel cannot be read (gone, left, no scope): a retry
				// meets the same answer and would hold every later catch-up.
				o.logger.Printf("catch-up of %s: %v; giving it up", c.ChannelID, err)
				return o.db.FinishCatchup(c.ChannelID)
			}
			return fmt.Errorf("catch-up of %s: %w", c.ChannelID, err)
		}
		if len(resp.Messages) == 0 {
			return o.db.FinishCatchup(c.ChannelID)
		}
		count, err := o.upsertMessagePage(ctx, c.ChannelID, resp.Messages)
		if err != nil {
			return fmt.Errorf("catch-up of %s: %w", c.ChannelID, err)
		}
		o.progress.AddMessages(count)
		oldest := to
		for _, m := range resp.Messages {
			if v, perr := strconv.ParseFloat(m.Timestamp, 64); perr == nil && v < oldest {
				oldest = v
			}
			if m.ReplyCount == 0 || !o.config.Sync.SyncThreads {
				continue
			}
			n, err := o.syncThread(ctx, c.ChannelID, m.Timestamp)
			if err != nil {
				if isNonFatalError(err) && !isRateLimitError(err) {
					o.logger.Printf("catch-up of %s: skipping thread %s: %v", c.ChannelID, m.Timestamp, err)
					continue
				}
				// The page stays unadvanced: the next run saves it again
				// (an upsert) and fetches the rest of its threads.
				return fmt.Errorf("catch-up of %s, thread %s: %w", c.ChannelID, m.Timestamp, err)
			}
			o.progress.AddMessages(n)
		}
		if !resp.HasMore {
			return o.db.FinishCatchup(c.ChannelID)
		}
		if oldest >= to {
			// No parseable ts moved the bound: walking on would ask for
			// the same page again.
			return fmt.Errorf("catch-up of %s: page below %s has no older ts", c.ChannelID, formatSlackTS(to))
		}
		if err := o.db.AdvanceCatchup(c.ChannelID, oldest); err != nil {
			return err
		}
		to = oldest
	}
	return nil
}

// formatSlackTS is a unix time as a Slack ts ("1700000000.000100").
func formatSlackTS(v float64) string {
	return strconv.FormatFloat(v, 'f', 6, 64)
}
