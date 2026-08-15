package inbox

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// BackfillAccountResult is one connected Slack account's contribution to a
// BackfillMentions run.
type BackfillAccountResult struct {
	AccountID       int64
	CandidatesFound int
	ItemsCreated    int
}

// BackfillMentionsResult totals a BackfillMentions run: per-account and
// overall candidate/created counts, plus the accounts that were skipped for
// having no resolved identity (mirrors detectSlackAccounts' own skip — see
// docs/inventory/inbox-pulse.md INBOX-09's multi-account extension).
type BackfillMentionsResult struct {
	Accounts          []BackfillAccountResult
	SkippedAccountIDs []int64
	TotalCandidates   int
	TotalCreated      int
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
// composed_at IS NULL), so no further step is needed here. The dedup guard
// already in FindPendingMentions (NOT EXISTS against inbox_items) makes
// re-running this any number of times over the same window safe.
//
// Accounts are looped exactly as detectSlackAccounts does: an enabled
// account whose current_user_id is not yet resolved is skipped, not treated
// as an error, and one account's error never stops a sibling account's scan
// within the same call — every per-account error is joined into the
// returned error. dryRun runs every read but skips every write (via
// createItemsFromCandidates' own dryRun path), so the returned counts show
// exactly what a real run would create without creating anything.
func (p *Pipeline) BackfillMentions(_ context.Context, since time.Time, dryRun bool) (BackfillMentionsResult, error) {
	accounts, err := p.db.ListEnabledSlackAccounts()
	if err != nil {
		return BackfillMentionsResult{}, fmt.Errorf("backfill mentions: listing enabled slack accounts: %w", err)
	}

	sinceTS := float64(since.Unix())

	var result BackfillMentionsResult
	var errs []error
	for _, acct := range accounts {
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

		created := p.createItemsFromCandidates(mentions, acct.CurrentUserID, dryRun)

		result.Accounts = append(result.Accounts, BackfillAccountResult{
			AccountID:       acct.ID,
			CandidatesFound: len(mentions),
			ItemsCreated:    created,
		})
		result.TotalCandidates += len(mentions)
		result.TotalCreated += created
	}

	p.logger.Printf("inbox: backfill mentions: since=%s dryRun=%v accounts=%d skipped=%d candidates=%d created=%d",
		since.UTC().Format(time.RFC3339), dryRun, len(result.Accounts), len(result.SkippedAccountIDs), result.TotalCandidates, result.TotalCreated)

	return result, errors.Join(errs...)
}
