package inbox

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// BackfillAccountResult is one connected Slack account's contribution to a
// BackfillMentions run. Every candidate FindPendingMentions returns lands in
// exactly one of Created/AlreadyAnswered/EmptySnippet/CreateErrors (unless
// the run was interrupted by context cancellation partway through this
// account — see BackfillMentions), so CandidatesFound always equals their
// sum on a completed run and a --dry-run envelope needs no DB query to be
// legible.
type BackfillAccountResult struct {
	AccountID       int64
	CandidatesFound int
	Created         int
	AlreadyAnswered int // owner reacted to or replied after the mention — CheckUserReplied, handled in Slack already
	EmptySnippet    int // enrichSnippet produced nothing worth surfacing (markup-only message)
	CreateErrors    int // CreateInboxItem failed for a reason other than the benign UNIQUE dedup race
}

// BackfillMentionsResult totals a BackfillMentions run across every account.
type BackfillMentionsResult struct {
	Accounts             []BackfillAccountResult
	SkippedAccountIDs    []int64
	TotalCandidates      int
	TotalCreated         int
	TotalAlreadyAnswered int
	TotalEmptySnippet    int
	TotalCreateErrors    int
}

// BackfillMentions recovers @mentions that a broken or newly-connected
// detector never turned into inbox items, without reading or writing
// inbox_last_processed_ts. Unlike Run/RunFastDetection, which always scan
// forward from the shared watermark across every trigger type, this scans
// only mentions, only from the explicit `since` argument: recovering a known
// dead window must never re-process the DMs, thread replies and ordinary
// channel traffic that window also contains, and must never touch the
// cursor every detector and triage share (INBOX-09).
//
// It makes no AI call. Items are created untriaged, landing in the
// conservative 'actionable' default class — INBOX-01 lets triage only
// downgrade a trigger item's class, never upgrade one, so an untriaged item
// is the safe default. The next daemon cycle's composer picks them up by
// status, not by watermark (ListUncomposedSignals selects on
// composed_at IS NULL), so no further step is needed here.
//
// This path deliberately does NOT reuse createItemsFromCandidates (the
// per-cycle detectSlackTriggers path) — see backfillAccountMentions' doc
// comment for why the two are not interchangeable over a multi-week window.
// It creates exactly one item per candidate, never groups, and never folds
// into an existing item, so the dedup guard already in FindPendingMentions
// (NOT EXISTS against inbox_items, keyed on channel_id+message_ts) is on its
// own sufficient to make re-running this any number of times over the same
// window genuinely idempotent — every recovered candidate becomes its own
// row instead of being merged away.
//
// Accounts are looped exactly as detectSlackAccounts does: an enabled
// account whose current_user_id is not yet resolved is skipped, not treated
// as an error, and one account's error never stops a sibling account's scan
// within the same call — every per-account error is joined into the
// returned error. dryRun runs every read but skips only the final
// CreateInboxItem write, so the returned counts show exactly what a real
// run would do without creating anything.
//
// ctx is checked for cancellation between accounts and between candidates
// within an account (not mid-candidate): a cancelled run stops promptly
// rather than draining the entire window, at the cost of leaving whatever
// candidates it never reached uncounted in any bucket for the account it was
// working on when cancelled — a partial report, not a wrong one, since
// ctx.Err() is always joined into the returned error so the caller can tell
// the run didn't finish.
func (p *Pipeline) BackfillMentions(ctx context.Context, since time.Time, dryRun bool) (BackfillMentionsResult, error) {
	accounts, err := p.db.ListEnabledSlackAccounts()
	if err != nil {
		return BackfillMentionsResult{}, fmt.Errorf("backfill mentions: listing enabled slack accounts: %w", err)
	}

	sinceTS := float64(since.Unix())

	var result BackfillMentionsResult
	var errs []error
	for _, acct := range accounts {
		if ctx.Err() != nil {
			break
		}
		if acct.CurrentUserID == "" {
			p.logger.Printf("inbox: backfill mentions: account %d: current_user_id not yet resolved, skipping", acct.ID)
			result.SkippedAccountIDs = append(result.SkippedAccountIDs, acct.ID)
			continue
		}

		mentions, err := p.db.FindPendingMentions(acct.ID, acct.CurrentUserID, sinceTS)
		if err != nil {
			errs = append(errs, fmt.Errorf("account %d: finding mentions: %w", acct.ID, err))
			continue
		}

		acctResult := p.backfillAccountMentions(ctx, acct.ID, acct.CurrentUserID, mentions, dryRun)
		result.Accounts = append(result.Accounts, acctResult)
		result.TotalCandidates += acctResult.CandidatesFound
		result.TotalCreated += acctResult.Created
		result.TotalAlreadyAnswered += acctResult.AlreadyAnswered
		result.TotalEmptySnippet += acctResult.EmptySnippet
		result.TotalCreateErrors += acctResult.CreateErrors
	}
	if err := ctx.Err(); err != nil {
		errs = append(errs, fmt.Errorf("backfill mentions: %w", err))
	}

	p.logger.Printf("inbox: backfill mentions: since=%s dryRun=%v accounts=%d skipped=%d candidates=%d created=%d already_answered=%d empty_snippet=%d create_errors=%d",
		since.UTC().Format(time.RFC3339), dryRun, len(result.Accounts), len(result.SkippedAccountIDs),
		result.TotalCandidates, result.TotalCreated, result.TotalAlreadyAnswered, result.TotalEmptySnippet, result.TotalCreateErrors)

	return result, errors.Join(errs...)
}

// backfillAccountMentions creates one inbox item per mention candidate for a
// single account — deliberately NOT the grouped/fold-capable path
// createItemsFromCandidates uses for the live per-cycle detector. That path
// was designed for a window of minutes and two of its semantics invert over
// a multi-week backfill window:
//
//   - Grouping by (channel, thread) keeps only the LATEST message per group
//     and creates one item for the group. A non-threaded message's thread
//     key is always "" (FindPendingMentions COALESCEs thread_ts), so
//     grouping would collapse every plain channel mention across the whole
//     backfill window into a single item per channel — recovering roughly
//     one mention out of however many actually went missing.
//   - Folding into "any pending item on the thread" doesn't check the
//     item's age. Over a live per-cycle window the existing pending item is
//     always about the same conversation the new candidate belongs to; over
//     a multi-week window it can just as easily be a different, currently
//     live conversation that happens to share a thread — folding would
//     silently rewrite that item's message_ts backwards and, via
//     UpdateInboxItemSnippet, reset its ai_reason/read_at and risk pulling a
//     composed situation back through a strong-tier re-compose.
//
// So: no grouping, no fold, and UpdateInboxItemSnippet/MergeWaitingUserIDs
// are never called from this path — every candidate becomes its own
// CreateInboxItem call (or is skipped and counted, see below). An existing
// pending item that happens to share a thread with a recovered candidate is
// left completely untouched.
//
// Each candidate is classified in order:
//  1. the owner already reacted to the mention, or replied in the
//     thread/channel after it (CheckUserReplied — the same "handled in
//     Slack already" check autoResolveSlack uses for INBOX-02, deliberately
//     NOT CheckUserRepliedBefore: that function tests for a prior message
//     BEFORE the given timestamp, the closing-signal pre-filter's question
//     ["did the owner already answer whatever this trailing 'thanks' is
//     acknowledging"] — applied to the mention's own timestamp instead, it
//     would ask "did the owner post anything in this channel before being
//     mentioned," which for an active channel the owner already posts in is
//     true almost by default and would wrongly suppress most plain-channel
//     recoveries) — a true result means it was handled in Slack without
//     Watchtower's help, so it is skipped and counted AlreadyAnswered.
//  2. enrichSnippet produces an empty snippet (markup-only message) — skipped
//     and counted EmptySnippet.
//  3. otherwise, one CreateInboxItem call. A UNIQUE(channel_id, message_ts)
//     collision here — only reachable via a race against a concurrently
//     running detector inserting the identical message between this
//     account's FindPendingMentions read and this write — counts as
//     Created rather than CreateErrors: an inbox item for this candidate
//     exists either way, which is what Created promises to every reader of
//     the envelope (CandidatesFound always equals the other three buckets'
//     sum, see BackfillAccountResult); any other create error is logged and
//     counted CreateErrors.
//
// dryRun runs classification steps 1 and 2 for real (both are reads) but
// skips the CreateInboxItem call in step 3, counting Created exactly as a
// real run would.
func (p *Pipeline) backfillAccountMentions(ctx context.Context, accountID int64, currentUserID string, mentions []db.InboxCandidate, dryRun bool) BackfillAccountResult {
	result := BackfillAccountResult{AccountID: accountID, CandidatesFound: len(mentions)}

	for _, c := range mentions {
		if ctx.Err() != nil {
			break
		}

		replied, _ := p.db.CheckUserReplied(currentUserID, c.ChannelID, c.MessageTS, c.ThreadTS)
		if replied {
			result.AlreadyAnswered++
			continue
		}

		snippet := enrichSnippet(c.Text, p.db)
		if snippet == "" {
			result.EmptySnippet++
			continue
		}
		snippet = truncateRunes(snippet, 500)

		if dryRun {
			result.Created++
			continue
		}

		itemCtx := p.loadContext(c.ChannelID, c.MessageTS, c.ThreadTS)
		_, err := p.db.CreateInboxItem(db.InboxItem{
			ChannelID:      c.ChannelID,
			MessageTS:      c.MessageTS,
			ThreadTS:       c.ThreadTS,
			SenderUserID:   c.SenderUserID,
			TriggerType:    c.TriggerType,
			Snippet:        snippet,
			Context:        itemCtx,
			RawText:        c.Text,
			Permalink:      c.Permalink,
			WaitingUserIDs: toWaitingJSON([]string{c.SenderUserID}),
		})
		if err != nil {
			if strings.Contains(err.Error(), "UNIQUE") {
				// Someone else (a concurrently running detector) already
				// recovered this exact message — the row exists either way,
				// so this counts as Created, not an error.
				result.Created++
				continue
			}
			p.logger.Printf("inbox: backfill mentions: account %d: error creating item for %s/%s: %v", accountID, c.ChannelID, c.MessageTS, err)
			result.CreateErrors++
			continue
		}
		result.Created++
	}

	return result
}
