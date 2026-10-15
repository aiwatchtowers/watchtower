package gmail

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"time"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Syncer fetches Gmail inbox messages and stores them.
type Syncer struct {
	client    *Client
	db        *db.DB
	cfg       *config.Config
	logger    *log.Logger
	accountID int64

	// firstSyncFrom is the window start of the last Sync when it was the
	// account's first (watermark 0) and its ID list succeeded; zero
	// otherwise. Sync resets it; the daemon reads it via FirstSyncFrom to
	// start a history backfill.
	firstSyncFrom time.Time
}

// AccountID returns the google_accounts row this syncer serves.
func (s *Syncer) AccountID() int64 { return s.accountID }

// FirstSyncFrom reports whether the last Sync was the account's first
// (watermark 0, ID list succeeded and non-empty) and, if so, the start of
// its newer_than window.
func (s *Syncer) FirstSyncFrom() (time.Time, bool) {
	return s.firstSyncFrom, !s.firstSyncFrom.IsZero()
}

// NewSyncer creates a Gmail syncer for the connected google_accounts row
// accountID.
// If logger is nil, a no-op logger is used.
func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger, accountID int64) *Syncer {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Syncer{client: client, db: database, cfg: cfg, logger: logger, accountID: accountID}
}

// noiseLabels are Gmail categories we skip before AI ever sees them.
var noiseLabels = map[string]bool{"CATEGORY_PROMOTIONS": true, "CATEGORY_SOCIAL": true}

// Sync pulls inbox messages newer than the watermark, stores them, and advances
// the watermark. Returns the count of stored messages.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
	s.firstSyncFrom = time.Time{}
	days := s.cfg.Gmail.InitialHistoryDays
	if days <= 0 {
		days = config.DefaultGmailInitialHistoryDays
	}
	maxMsgs := s.cfg.Gmail.MaxMessagesPerSync
	if maxMsgs <= 0 {
		maxMsgs = config.DefaultGmailMaxMessagesPerSync
	}
	maxBody := s.maxBodyBytes()

	watermark, err := s.db.GetGmailAccountWatermark(s.accountID)
	if err != nil {
		return 0, fmt.Errorf("reading gmail watermark: %w", err)
	}
	var query string
	if watermark > 0 {
		// Narrow the server-side window to strictly-new mail. Gmail's after:
		// operator accepts unix seconds.
		query = fmt.Sprintf("in:inbox after:%d", int64(watermark))
	} else {
		query = fmt.Sprintf("in:inbox newer_than:%dd", days) // initial backfill window
	}

	// List the whole query window uncapped: messages.list pagination is cheap
	// quota-wise, and any cap here risks Gmail's newest-first ordering hiding
	// an older backlog tail behind the cap (data loss once the watermark
	// advances past it). MaxMessagesPerSync is applied below, only to the
	// processing phase (GetMessage/upsert), after sorting oldest-first.
	listedAt := time.Now().UTC()
	ids, err := s.client.ListInboxMessageIDs(ctx, query, 0)
	if err != nil {
		s.recordAuthResult(ctx, err)
		if errors.Is(err, ErrAuthRevoked) {
			return 0, err
		}
		return 0, fmt.Errorf("listing gmail messages: %w", err)
	}
	s.recordAuthResult(ctx, nil)
	if watermark == 0 && len(ids) > 0 { // an empty inbox has nothing to backfill (R25)
		s.firstSyncFrom = listedAt.AddDate(0, 0, -days)
	}

	// Gmail returns newest-first; reverse so we process oldest-first. This
	// matters when we're capped below: the watermark then advances only to
	// the oldest batch processed, so the next cycle's after:<watermark>
	// query picks up whatever we didn't get to — nothing is skipped.
	for i, j := 0, len(ids)-1; i < j; i, j = i+1, j-1 {
		ids[i], ids[j] = ids[j], ids[i]
	}
	capped := len(ids) > maxMsgs
	var cutUnix int64
	var cutErr error
	if capped {
		s.logger.Printf("gmail: %d messages exceed cap %d, processing oldest %d; remainder next cycle", len(ids), maxMsgs, maxMsgs)
		cutUnix, cutErr = s.client.GetMessageUnix(ctx, ids[maxMsgs])
		if cutErr != nil {
			s.logger.Printf("gmail: reading the date of the first message past the cap (%s): %v; holding the watermark a second below the last processed message", ids[maxMsgs], cutErr)
		}
		ids = ids[:maxMsgs]
	}

	now := time.Now().UTC()
	syncedAt := now.Format(time.RFC3339)
	count := 0
	maxSeen := watermark
	stalled := false // set once a message is lost, so maxSeen stops advancing past the gap

	for _, id := range ids {
		stored, msgUnix, err := s.storeMessage(ctx, id, func(string) string { return syncedAt }, maxBody, watermark)
		if err != nil {
			s.logger.Printf("gmail: %v", err)
			if msgUnix == 0 {
				// The lost message's date is unknown (the fetch failed), but
				// oldest-first order puts it at or after the last second the
				// pass advanced to — a noise skip or a stored message in that
				// same second must not leave the watermark on it.
				if !stalled { // later losses sit at or after the first one
					maxSeen = holdBelowLoss(maxSeen, watermark, maxSeen)
				}
			} else {
				maxSeen = holdBelowLoss(maxSeen, watermark, msgUnix)
			}
			stalled = true
			continue
		}
		if !stored {
			// A noise skip is deliberate non-storage, not a loss: move the
			// watermark past it (unless an earlier message was lost), or every
			// promo/social message newer than the last stored one is re-fetched
			// each cycle — and a capped window of pure noise never advances.
			// (An already-seen skip sits at or below the watermark, so this
			// is a no-op for it.)
			if !stalled && msgUnix > maxSeen {
				maxSeen = msgUnix
			}
			continue
		}
		count++
		// Messages are processed oldest-first, so once any message has been lost
		// (fetch or upsert failure — not the deliberate noise/already-seen skips
		// above) the watermark must stop advancing past that gap: a later
		// message's success must not let SetGmailAccountWatermark commit a value
		// past a message that was never stored, or that message becomes
		// permanently unreachable (the next cycle's after:<watermark> query and
		// the already-seen filter both exclude it).
		if stalled {
			continue
		}
		if msgUnix > maxSeen {
			maxSeen = msgUnix
		}
	}

	if capped {
		unclamped := maxSeen
		maxSeen = clampBelowCut(maxSeen, cutUnix, cutErr)
		if unclamped > watermark && maxSeen <= watermark {
			s.logger.Printf("gmail: all %d processed messages share the cap cut-off's second; the watermark cannot advance past it", maxMsgs)
		}
	}
	if maxSeen > watermark {
		if err := s.db.SetGmailAccountWatermark(s.accountID, maxSeen); err != nil {
			s.logger.Printf("gmail: advancing watermark: %v", err)
		}
	}
	return count, nil
}

// FetchRange stores every non-noise inbox message received in [from, to),
// ignoring MaxMessagesPerSync. It writes no watermark and no auth state, and
// each row's synced_at is the message's own date, so the inbox detector never
// sees backfilled mail as new. The first error stops it (wrapped, so
// ErrAuthRevoked stays matchable).
func (s *Syncer) FetchRange(ctx context.Context, from, to time.Time) (int, error) {
	query := fmt.Sprintf("in:inbox after:%d before:%d", from.Unix(), to.Unix())
	ids, err := s.client.ListInboxMessageIDs(ctx, query, 0)
	if err != nil {
		return 0, fmt.Errorf("listing gmail messages %q: %w", query, err)
	}
	maxBody := s.maxBodyBytes()
	ownDate := func(internalDate string) string { return backfillSyncedAt(internalDate, from) }
	count := 0
	for _, id := range ids {
		stored, _, err := s.storeMessage(ctx, id, ownDate, maxBody, 0)
		if err != nil {
			return count, err
		}
		if stored {
			count++
		}
	}
	return count, nil
}

// storeMessage fetches message id and upserts it unless it carries a noise
// label or its internalDate is at or below skipAtOrBelow (0 = no filter).
// msgUnix is the message's date (0 when the fetch failed or the date did not
// parse); stored=false with a nil error is a deliberate skip. syncedAt maps
// the message's internal date to the row's synced_at.
func (s *Syncer) storeMessage(ctx context.Context, id string, syncedAt func(internalDate string) string, maxBody int, skipAtOrBelow float64) (stored bool, msgUnix float64, err error) {
	m, err := s.client.GetMessage(ctx, id)
	if err != nil {
		return false, 0, fmt.Errorf("fetch message %s: %w", id, err)
	}
	msgUnix = isoToUnix(m.InternalDate)
	// Noise filter (before storage/AI).
	for _, l := range m.Labels {
		if noiseLabels[l] {
			return false, msgUnix, nil
		}
	}
	// Watermark filter: skip already-seen messages.
	if skipAtOrBelow > 0 && msgUnix <= skipAtOrBelow {
		return false, msgUnix, nil
	}
	toJSON, _ := json.Marshal(m.To)
	ccJSON, _ := json.Marshal(m.Cc)
	labelsJSON, _ := json.Marshal(m.Labels)
	row := db.GmailMessage{
		ID: m.ID, ThreadID: m.ThreadID, FromEmail: m.FromEmail, FromName: m.FromName,
		ToJSON: string(toJSON), CcJSON: string(ccJSON), Subject: m.Subject, Snippet: m.Snippet,
		BodyText: truncateUTF8(m.BodyText, maxBody), InternalDate: m.InternalDate, LabelsJSON: string(labelsJSON),
		IsUnread: m.IsUnread, Permalink: m.Permalink,
	}
	row.SyncedAt = syncedAt(m.InternalDate)
	if err := s.db.UpsertGmailMessage(s.accountID, row); err != nil {
		return false, msgUnix, fmt.Errorf("upsert %s: %w", m.ID, err)
	}
	return true, msgUnix, nil
}

// backfillSyncedAt is a backfilled row's synced_at: the message's own date
// (UTC RFC3339), or from when that is missing or unparseable. The inbox
// detector reads synced_at as "arrived since my cursor", so a backfilled row
// stamped now would surface weeks-old mail as new.
func backfillSyncedAt(internalDate string, from time.Time) string {
	if t, err := time.Parse(time.RFC3339, internalDate); err == nil {
		return t.UTC().Format(time.RFC3339)
	}
	return from.UTC().Format(time.RFC3339)
}

func (s *Syncer) maxBodyBytes() int {
	if s.cfg.Gmail.MaxBodyBytes > 0 {
		return s.cfg.Gmail.MaxBodyBytes
	}
	return config.DefaultGmailMaxBodyBytes
}

// holdBelowLoss keeps the watermark strictly below the second of a lost
// message (lostUnix): everything at or below the watermark is excluded next
// cycle, so a noise skip or stored message that already advanced maxSeen onto
// that second would otherwise strand the lost one for good. It never goes
// below the pass's starting watermark.
func holdBelowLoss(maxSeen, watermark, lostUnix float64) float64 {
	if lostUnix <= maxSeen {
		maxSeen = max(lostUnix-1, watermark)
	}
	return maxSeen
}

// clampBelowCut keeps a capped pass's watermark strictly below the second of
// the first message the cap cut off (cutUnix). The watermark has whole-second
// resolution and both the next cycle's after:<watermark> query and the
// already-seen filter exclude everything at or below it, so a processed
// message (stored or noise) sharing that second would otherwise push the
// watermark onto it and lose the cut-off message for good. When the cut-off
// date could not be read (cutErr), the conservative bound is one second below
// the last processed message: the cut-off message is never older than it
// (oldest-first order), and re-listing that second only re-upserts what is
// already stored. Accepted limit: more than MaxMessagesPerSync messages in a
// single second can never advance the watermark (logged by Sync).
func clampBelowCut(maxSeen float64, cutUnix int64, cutErr error) float64 {
	limit := maxSeen - 1
	if cutErr == nil {
		limit = float64(cutUnix - 1)
	}
	return min(maxSeen, limit)
}

// recordAuthResult persists the gmail auth state. Pass err=nil to mark auth as healthy.
// Errors writing to the DB are logged but not returned — auth state is best-effort telemetry.
// A cancelled ctx means daemon shutdown, not an auth problem, so the state is left untouched —
// the guard is ctx-based because Go's signal-cancel cause does not unwrap to context.Canceled.
func (s *Syncer) recordAuthResult(ctx context.Context, err error) {
	if s.db == nil {
		return
	}
	if err == nil {
		if dbErr := s.db.SetGoogleAccountAuthState(s.accountID, "ok", ""); dbErr != nil {
			s.logger.Printf("gmail: clear auth state: %v", dbErr)
		}
		return
	}
	if ctx.Err() != nil {
		s.logger.Printf("gmail: sync cancelled, leaving auth state untouched: %v", err)
		return
	}
	status := "error"
	if errors.Is(err, ErrAuthRevoked) {
		status = "revoked"
	}
	if dbErr := s.db.SetGoogleAccountAuthState(s.accountID, status, err.Error()); dbErr != nil {
		s.logger.Printf("gmail: record auth state: %v", dbErr)
	}
}

// truncateUTF8 cuts body to at most maxBytes bytes, backing off to the last
// valid rune boundary instead of slicing mid-rune — a plain body[:maxBytes]
// can split a multibyte UTF-8 sequence and leave an invalid trailing partial
// rune in the stored body_text.
func truncateUTF8(body string, maxBytes int) string {
	if len(body) <= maxBytes {
		return body
	}
	cut := maxBytes
	for cut > 0 && !utf8.RuneStart(body[cut]) {
		cut--
	}
	return body[:cut]
}

// isoToUnix converts an RFC3339 timestamp to unix seconds (0 on parse failure).
func isoToUnix(iso string) float64 {
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return 0
	}
	return float64(t.Unix())
}
