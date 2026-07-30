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
	days := s.cfg.Gmail.InitialHistoryDays
	if days <= 0 {
		days = config.DefaultGmailInitialHistoryDays
	}
	maxMsgs := s.cfg.Gmail.MaxMessagesPerSync
	if maxMsgs <= 0 {
		maxMsgs = config.DefaultGmailMaxMessagesPerSync
	}
	maxBody := s.cfg.Gmail.MaxBodyBytes
	if maxBody <= 0 {
		maxBody = config.DefaultGmailMaxBodyBytes
	}

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
	ids, err := s.client.ListInboxMessageIDs(ctx, query, 0)
	if err != nil {
		s.recordAuthResult(err)
		if errors.Is(err, ErrAuthRevoked) {
			return 0, err
		}
		return 0, fmt.Errorf("listing gmail messages: %w", err)
	}
	s.recordAuthResult(nil)

	// Gmail returns newest-first; reverse so we process oldest-first. This
	// matters when we're capped below: the watermark then advances only to
	// the oldest batch processed, so the next cycle's after:<watermark>
	// query picks up whatever we didn't get to — nothing is skipped.
	for i, j := 0, len(ids)-1; i < j; i, j = i+1, j-1 {
		ids[i], ids[j] = ids[j], ids[i]
	}
	if len(ids) > maxMsgs {
		s.logger.Printf("gmail: %d messages exceed cap %d, processing oldest %d; remainder next cycle", len(ids), maxMsgs, maxMsgs)
		ids = ids[:maxMsgs]
	}

	now := time.Now().UTC()
	syncedAt := now.Format(time.RFC3339)
	count := 0
	maxSeen := watermark

	for _, id := range ids {
		m, err := s.client.GetMessage(ctx, id)
		if err != nil {
			s.logger.Printf("gmail: fetch message %s: %v", id, err)
			continue
		}
		// Noise filter (before storage/AI).
		skip := false
		for _, l := range m.Labels {
			if noiseLabels[l] {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		// Watermark filter: skip already-seen messages (internalDate <= watermark).
		msgUnix := isoToUnix(m.InternalDate)
		if watermark > 0 && msgUnix <= watermark {
			continue
		}
		body := truncateUTF8(m.BodyText, maxBody)
		toJSON, _ := json.Marshal(m.To)
		ccJSON, _ := json.Marshal(m.Cc)
		labelsJSON, _ := json.Marshal(m.Labels)
		row := db.GmailMessage{
			ID: m.ID, ThreadID: m.ThreadID, FromEmail: m.FromEmail, FromName: m.FromName,
			ToJSON: string(toJSON), CcJSON: string(ccJSON), Subject: m.Subject, Snippet: m.Snippet,
			BodyText: body, InternalDate: m.InternalDate, LabelsJSON: string(labelsJSON),
			IsUnread: m.IsUnread, Permalink: m.Permalink,
		}
		row.SyncedAt = syncedAt
		if err := s.db.UpsertGmailMessage(s.accountID, row); err != nil {
			s.logger.Printf("gmail: upsert %s: %v", m.ID, err)
			continue
		}
		if msgUnix > maxSeen {
			maxSeen = msgUnix
		}
		count++
	}

	if maxSeen > watermark {
		if err := s.db.SetGmailAccountWatermark(s.accountID, maxSeen); err != nil {
			s.logger.Printf("gmail: advancing watermark: %v", err)
		}
	}
	return count, nil
}

// recordAuthResult persists the gmail auth state. Pass err=nil to mark auth as healthy.
// Errors writing to the DB are logged but not returned — auth state is best-effort telemetry.
func (s *Syncer) recordAuthResult(err error) {
	if s.db == nil {
		return
	}
	if err == nil {
		if dbErr := s.db.SetGoogleAccountAuthState(s.accountID, "ok", ""); dbErr != nil {
			s.logger.Printf("gmail: clear auth state: %v", dbErr)
		}
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
