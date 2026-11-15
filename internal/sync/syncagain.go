package sync

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	watchtowerslack "watchtower/internal/slack"

	goslack "github.com/slack-go/slack"
)

// syncAgainPagesPerRun caps the conversations.history pages one run spends
// on a Sync again catch-up (replies of threaded parents come on top), so a
// catch-up never competes with the forward search.
const syncAgainPagesPerRun = 5

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

// runSyncAgainCatchups fetches the excluded period of the account's oldest
// pending Sync again catch-up, at most syncAgainPagesPerRun history pages,
// one channel per run. conversations.history returns the newest messages
// first, so the walk goes from the top down with a persisted upper bound,
// never a stored cursor (a cursor can expire and does not survive a
// restart): every page asks for (catchup_from, catchup_to) exclusive, and
// after saving it the bound moves down to the page's oldest ts
// (AdvanceCatchup). Slack ts are unique per channel, so nothing is skipped
// or fetched twice. A page without more ends the catch-up (FinishCatchup).
// Both writes are compare-and-set on the bounds this walk read: one that
// does not apply (a Stop syncing, or a new Sync again, since) ends the walk.
// A rate limit, the deadline or a restart leaves the bound at the last saved
// page. The rows keep their post time as synced_at (backfilling), so they
// never reach the Inbox; mentions of that period were stored while it was
// excluded.
func (o *Orchestrator) runSyncAgainCatchups(ctx context.Context) error {
	pending, err := o.db.PendingCatchups(o.accountID)
	if err != nil || len(pending) == 0 {
		return err
	}
	c := pending[0]
	o.backfilling = true
	defer func() { o.backfilling = false }()

	_, rawID, _ := watchtowerslack.SplitAccountID(c.ChannelID)
	for range syncAgainPagesPerRun {
		if err := ctx.Err(); err != nil {
			return err
		}
		resp, err := o.slackClient.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{
			ChannelID: rawID,
			Oldest:    formatSlackTS(c.From),
			Latest:    formatSlackTS(c.To),
			Limit:     slackPageSize,
		})
		if err != nil {
			if channelUnreadable(err) {
				// The channel itself is gone or left: a retry meets the same
				// answer and would hold every later catch-up.
				o.logger.Printf("sync again catch-up of %s: %v; giving it up", c.ChannelID, err)
				_, ferr := o.db.FinishCatchup(c)
				return ferr
			}
			return fmt.Errorf("sync again catch-up of %s: %w", c.ChannelID, err)
		}
		if len(resp.Messages) == 0 {
			_, err := o.db.FinishCatchup(c)
			return err
		}
		count, err := o.upsertMessagePage(ctx, c.ChannelID, resp.Messages)
		if err != nil {
			return fmt.Errorf("sync again catch-up of %s: %w", c.ChannelID, err)
		}
		o.progress.AddMessages(count)
		oldest := c.To
		for _, m := range resp.Messages {
			if v, perr := strconv.ParseFloat(m.Timestamp, 64); perr == nil && v < oldest {
				oldest = v
			}
			if m.ReplyCount == 0 || !o.config.Sync.SyncThreads {
				continue
			}
			n, err := o.syncThread(ctx, c.ChannelID, m.Timestamp)
			if err != nil {
				if channelUnreadable(err) {
					o.logger.Printf("sync again catch-up of %s: skipping thread %s: %v", c.ChannelID, m.Timestamp, err)
					continue
				}
				// The page stays unadvanced: the next run saves it again
				// (an upsert) and fetches the rest of its threads.
				return fmt.Errorf("sync again catch-up of %s, thread %s: %w", c.ChannelID, m.Timestamp, err)
			}
			o.progress.AddMessages(n)
		}
		if !resp.HasMore {
			_, err := o.db.FinishCatchup(c)
			return err
		}
		if oldest >= c.To {
			// No parseable ts moved the bound: walking on would ask for
			// the same page again.
			return fmt.Errorf("sync again catch-up of %s: page below %s has no older ts", c.ChannelID, formatSlackTS(c.To))
		}
		applied, err := o.db.AdvanceCatchup(c, oldest)
		if err != nil {
			return err
		}
		if !applied {
			o.logger.Printf("sync again catch-up of %s: changed since this run read it; stopping", c.ChannelID)
			return nil
		}
		c.To = oldest
	}
	return nil
}

// channelUnreadableErrors are the Slack error codes that say one channel
// cannot be read (gone, or the user left it). Account-wide answers
// (invalid_auth, account_inactive, access_denied, missing_scope …) are not
// here: they keep the catch-up pending until the account works again.
var channelUnreadableErrors = map[string]bool{
	"channel_not_found": true,
	"not_in_channel":    true,
}

// channelUnreadable reports a structured Slack error naming one of
// channelUnreadableErrors.
func channelUnreadable(err error) bool {
	var slackErr goslack.SlackErrorResponse
	return errors.As(err, &slackErr) && channelUnreadableErrors[slackErr.Err]
}

// formatSlackTS is a unix time as a Slack ts ("1700000000.000100").
func formatSlackTS(v float64) string {
	return strconv.FormatFloat(v, 'f', 6, 64)
}
