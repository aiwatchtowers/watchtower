package gmail

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/sourcediff"
)

const deletionsInterval = 24 * time.Hour

// CheckDeletions removes stored messages that the source no longer lists
// (deleted, trashed or spam), at most once a day. Archived mail stays: the
// listing covers all mail except trash and spam. The stored set is read
// before the listing, so mail that arrives meanwhile is never a candidate.
// An incomplete listing (any API error) deletes nothing and leaves no stamp,
// so the next cycle retries.
func (s *Syncer) CheckDeletions(ctx context.Context, now time.Time) (removed int, err error) {
	last, err := s.db.GmailDeletionsCheckedAt(s.accountID)
	if err != nil {
		return 0, err
	}
	if now.Sub(last) < deletionsInterval {
		return 0, nil
	}
	stored, oldest, err := s.db.GmailStoredIDs(s.accountID)
	if err != nil {
		return 0, err
	}
	if len(stored) == 0 {
		return 0, s.db.SetGmailDeletionsCheckedAt(s.accountID, now)
	}
	query := fmt.Sprintf("after:%d -in:trash -in:spam", int64(oldest)-86400)
	listed, err := s.client.ListInboxMessageIDs(ctx, query, 0)
	if err != nil {
		return 0, fmt.Errorf("listing gmail ids for deletions check (account %d): %w", s.accountID, err)
	}
	missing := missingIDs(stored, listed)
	// ok == false with an empty reason means nothing is missing.
	ok, reason := sourcediff.Check(len(stored), len(stored)-len(missing), len(missing), sourcediff.MailFloors)
	if !ok && reason != "" {
		if s.logger != nil {
			s.logger.Printf("gmail deletions: account %d, query %q: skipped, %s", s.accountID, query, reason)
		}
		return 0, s.db.SetGmailDeletionsCheckedAt(s.accountID, now)
	}
	if ok {
		if removed, err = s.db.DeleteGmailMessages(s.accountID, missing); err != nil {
			return 0, err
		}
	}
	if err := s.db.SetGmailDeletionsCheckedAt(s.accountID, now); err != nil {
		if s.logger != nil {
			s.logger.Printf("gmail deletions: account %d: removed %d messages but stamping failed", s.accountID, removed)
		}
		return removed, err
	}
	return removed, nil
}

// missingIDs returns the stored ids the listing does not contain.
func missingIDs(stored, listed []string) []string {
	inListing := make(map[string]struct{}, len(listed))
	for _, id := range listed {
		inListing[id] = struct{}{}
	}
	var missing []string
	for _, id := range stored {
		if _, ok := inListing[id]; !ok {
			missing = append(missing, id)
		}
	}
	return missing
}
