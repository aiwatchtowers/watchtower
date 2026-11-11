package gmail

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"

	"watchtower/internal/config"
)

// sentCatchUpMaxAttempts is how many CatchUpSent passes per account and
// process may fail on a message with a non-transient error before the pass
// stamps anyway, so one bad message never re-downloads the week every cycle.
const sentCatchUpMaxAttempts = 3

// CatchUpSent lists the owner's sent mail of the initial history window once
// for an account that synced before Sync listed sent mail, and stores it
// with each row's own date as synced_at (so the inbox detector never sees
// it as new). It is a no-op (0, nil) when the account's sent catch-up is
// already stamped or the account has not synced yet (watermark 0: its first
// Sync lists sent mail and stamps). It writes no watermark and no auth state.
//
// A message deleted between the listing and the fetch (404) is skipped. Any
// other error stops the pass, wrapped, and stamps nothing, so the next cycle
// retries; after sentCatchUpMaxAttempts passes that failed with a
// non-transient error (catchUpCountsFailure) it stamps now anyway. A pass in
// which every listed message was stored or skipped stamps now. Returns the
// count of stored messages.
func (s *Syncer) CatchUpSent(ctx context.Context, now time.Time) (int, error) {
	stamp, err := s.db.GmailSentCatchUpAt(s.accountID)
	if err != nil {
		return 0, err
	}
	if stamp != "" {
		return 0, nil
	}
	watermark, err := s.db.GetGmailAccountWatermark(s.accountID)
	if err != nil {
		return 0, fmt.Errorf("reading gmail watermark: %w", err)
	}
	if watermark == 0 {
		return 0, nil
	}

	days := s.cfg.Gmail.InitialHistoryDays
	if days <= 0 {
		days = config.DefaultGmailInitialHistoryDays
	}
	from := now.Add(-time.Duration(days) * 24 * time.Hour)
	query := fmt.Sprintf("in:sent after:%d", from.Unix())
	ids, err := s.client.ListInboxMessageIDs(ctx, query, 0)
	if err != nil {
		// A failed listing (offline, revoked) is transient: never counted.
		return 0, fmt.Errorf("listing gmail sent messages: %w", err)
	}

	maxBody := s.maxBodyBytes()
	ownDate := func(internalDate string) string { return backfillSyncedAt(internalDate, from) }
	count := 0
	for _, id := range ids {
		stored, _, err := s.storeMessage(ctx, id, ownDate, maxBody, 0)
		if err != nil {
			if isNotFound(err) {
				continue // deleted between the listing and the fetch
			}
			return count, s.catchUpFailed(now, err)
		}
		if stored {
			count++
		}
	}
	s.stampSentCatchUp(now)
	return count, nil
}

// catchUpFailed counts a failed pass and, when it counts, stamps now on the
// sentCatchUpMaxAttempts-th such failure. The error goes back unwrapped: the
// daemon's log line already names the sent catch-up.
func (s *Syncer) catchUpFailed(now time.Time, err error) error {
	if !catchUpCountsFailure(err) {
		return err
	}
	s.catchUpFailures++
	if s.catchUpFailures >= sentCatchUpMaxAttempts {
		s.logger.Printf("gmail: sent catch-up for account %d gave up after %d attempts: %v", s.accountID, sentCatchUpMaxAttempts, err)
		s.stampSentCatchUp(now)
	}
	return err
}

// stampSentCatchUp marks the account's sent catch-up done; a failed write is
// logged and the next cycle runs the pass again.
func (s *Syncer) stampSentCatchUp(now time.Time) {
	if err := s.db.SetGmailSentCatchUpAt(s.accountID, now); err != nil {
		s.logger.Printf("gmail: stamping the sent catch-up for account %d: %v", s.accountID, err)
	}
}

// isNotFound reports a Gmail 404 reply.
func isNotFound(err error) bool {
	var se *StatusError
	return errors.As(err, &se) && se.Code == http.StatusNotFound
}

// catchUpCountsFailure reports whether a failed catch-up pass counts toward
// sentCatchUpMaxAttempts: only a non-transient failure does. A transient one
// (rate limit or server error, a network error, a cancelled or expired
// context, revoked access) says nothing about the message and is retried
// without limit.
func catchUpCountsFailure(err error) bool {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, ErrAuthRevoked) {
		return false
	}
	var se *StatusError
	if errors.As(err, &se) {
		return !se.Transient()
	}
	var ue *url.Error
	if errors.As(err, &ue) {
		return false
	}
	var ne net.Error
	return !errors.As(err, &ne)
}
