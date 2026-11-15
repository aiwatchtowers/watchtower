package sync

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"

	goslack "github.com/slack-go/slack"
)

// syncAgainPagesPerRun caps the conversations.history pages one run spends
// on Sync again catch-ups, all of them together (replies of threaded parents
// come on top), so a catch-up never competes with the forward search.
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

// runSyncAgainCatchups fetches the excluded periods of the account's pending
// Sync again catch-ups, the oldest first, spending at most
// syncAgainPagesPerRun history pages in all per run (replies of threaded
// parents come on top). conversations.history returns the newest messages
// first, so each walk goes from the top down with a persisted upper bound,
// never a stored cursor (a cursor can expire and does not survive a
// restart): every page asks for (catchup_from, catchup_to) exclusive, and
// after saving it the bound moves down to the page's oldest ts
// (AdvanceCatchup). Slack ts are unique per channel, so nothing is skipped
// or fetched twice. A page without more ends the catch-up (FinishCatchup).
// Both writes are compare-and-set on the bounds this walk read: one that
// does not apply (a Stop syncing, or a new Sync again, since) ends that walk.
//
// A catch-up that fails for its own reasons (an error of its channel, the
// database) keeps its bound and the run moves on to the next one, so one
// stuck channel never holds the others. A rate limit, the deadline, a
// cancel or an account-wide Slack error ends the whole pass: every other
// catch-up would meet the same answer (the deadline is checked before every
// page). The rows keep their post time as synced_at (backfilling), so they
// never reach the Inbox; mentions of that period were stored while it was
// excluded.
func (o *Orchestrator) runSyncAgainCatchups(ctx context.Context) error {
	pending, err := o.db.PendingCatchups(o.accountID)
	if err != nil || len(pending) == 0 {
		return err
	}
	o.backfilling = true
	defer func() { o.backfilling = false }()

	budget := syncAgainPagesPerRun
	var errs []error
	for _, c := range pending {
		if budget == 0 {
			break
		}
		used, err := o.runCatchup(ctx, c, budget)
		budget -= used
		if err == nil {
			continue
		}
		errs = append(errs, err)
		if ctx.Err() != nil || isRateLimitError(err) || errors.Is(err, watchtowerslack.ErrFetchDeadline) || accountWideSlackError(err) {
			break
		}
	}
	return errors.Join(errs...)
}

// runCatchup walks one catch-up for at most budget history pages and
// returns how many it fetched.
func (o *Orchestrator) runCatchup(ctx context.Context, c db.Catchup, budget int) (pages int, err error) {
	_, rawID, _ := watchtowerslack.SplitAccountID(c.ChannelID)
	for pages < budget {
		if err := ctx.Err(); err != nil {
			return pages, err
		}
		if o.slackClient.DeadlinePassed() {
			return pages, fmt.Errorf("sync again catch-up of %s: %w", c.ChannelID, watchtowerslack.ErrFetchDeadline)
		}
		pages++
		resp, err := o.slackClient.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{
			ChannelID: rawID,
			Oldest:    formatSlackTS(c.From),
			Latest:    formatSlackTS(c.To),
			Limit:     slackPageSize,
		})
		if err != nil {
			if channelUnreadable(err) {
				// The channel itself is gone or left: a retry meets the same
				// answer forever.
				o.logger.Printf("sync again catch-up of %s: %v; giving it up", c.ChannelID, err)
				_, ferr := o.db.FinishCatchup(c)
				return pages, ferr
			}
			return pages, fmt.Errorf("sync again catch-up of %s: %w", c.ChannelID, err)
		}
		if len(resp.Messages) == 0 {
			_, err := o.db.FinishCatchup(c)
			return pages, err
		}
		count, err := o.upsertMessagePage(ctx, c.ChannelID, resp.Messages)
		if err != nil {
			return pages, fmt.Errorf("sync again catch-up of %s: %w", c.ChannelID, err)
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
				if threadScopedError(err) {
					// Slack answered for this thread alone (a deleted
					// parent's thread_not_found …): the same answer would
					// come every run, so the thread is skipped.
					o.logger.Printf("sync again catch-up of %s: skipping thread %s: %v", c.ChannelID, m.Timestamp, err)
					continue
				}
				// The page stays unadvanced: the next run saves it again
				// (an upsert) and fetches the rest of its threads.
				return pages, fmt.Errorf("sync again catch-up of %s, thread %s: %w", c.ChannelID, m.Timestamp, err)
			}
			o.progress.AddMessages(n)
		}
		if !resp.HasMore {
			_, err := o.db.FinishCatchup(c)
			return pages, err
		}
		if oldest >= c.To {
			// No parseable ts moved the bound: walking on would ask for
			// the same page forever. What it held is saved; the rest of
			// the period is given up.
			o.logger.Printf("sync again catch-up of %s: page below %s has no older ts; giving the rest up",
				c.ChannelID, formatSlackTS(c.To))
			_, err := o.db.FinishCatchup(c)
			return pages, err
		}
		applied, err := o.db.AdvanceCatchup(c, oldest)
		if err != nil {
			return pages, err
		}
		if !applied {
			o.logger.Printf("sync again catch-up of %s: changed since this run read it; stopping", c.ChannelID)
			return pages, nil
		}
		c.To = oldest
	}
	return pages, nil
}

// channelUnreadableErrors are the nonFatalSlackErrors codes that say one
// channel cannot be read (gone, or the user left it);
// TestChannelUnreadableErrorsAreNonFatal keeps them a subset.
var channelUnreadableErrors = map[string]bool{
	"channel_not_found": true,
	"not_in_channel":    true,
}

// accountWideSlackErrors are the Slack error codes about the account or its
// token, not one channel or thread: every other call meets them too, so
// they keep a catch-up pending until the account works again.
var accountWideSlackErrors = map[string]bool{
	"account_inactive": true,
	"missing_scope":    true,
	"access_denied":    true,
	"invalid_auth":     true,
	"not_authed":       true,
	"token_revoked":    true,
	"token_expired":    true,
}

// slackErrorCode is the code of a structured Slack error answer ("" when err
// is not one).
func slackErrorCode(err error) string {
	var slackErr goslack.SlackErrorResponse
	if errors.As(err, &slackErr) {
		return slackErr.Err
	}
	return ""
}

// channelUnreadable reports a structured Slack error naming one of
// channelUnreadableErrors.
func channelUnreadable(err error) bool {
	return channelUnreadableErrors[slackErrorCode(err)]
}

// accountWideSlackError reports a structured Slack error naming one of
// accountWideSlackErrors.
func accountWideSlackError(err error) bool {
	return accountWideSlackErrors[slackErrorCode(err)]
}

// threadGoneErrors are the Slack error codes that say one thread is gone
// for good (its parent deleted); with channelUnreadableErrors they are the
// only thread answers a catch-up skips. Any other code (internal_error,
// service_unavailable, an unknown one) may be transient: the page stays
// pending and the next run asks again.
var threadGoneErrors = map[string]bool{
	"thread_not_found":  true,
	"message_not_found": true,
}

// threadScopedError reports a Slack error answer that says this thread (or
// its channel) cannot be read, now or on any retry.
func threadScopedError(err error) bool {
	code := slackErrorCode(err)
	return threadGoneErrors[code] || channelUnreadableErrors[code]
}

// formatSlackTS is a unix time as a Slack ts ("1700000000.000100").
func formatSlackTS(v float64) string {
	return strconv.FormatFloat(v, 'f', 6, 64)
}
