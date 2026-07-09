package gmail

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Syncer fetches Gmail inbox messages and stores them.
type Syncer struct {
	client *Client
	db     *db.DB
	cfg    *config.Config
	logger *log.Logger
}

// NewSyncer creates a Gmail syncer.
// If logger is nil, a no-op logger is used.
func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger) *Syncer {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Syncer{client: client, db: database, cfg: cfg, logger: logger}
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

	watermark, err := s.db.GetGmailLastInternalDate()
	if err != nil {
		return 0, fmt.Errorf("reading gmail watermark: %w", err)
	}
	query := fmt.Sprintf("in:inbox newer_than:%dd", days) // initial backfill window; watermark filters below

	ids, err := s.client.ListInboxMessageIDs(ctx, query, maxMsgs)
	if err != nil {
		s.recordAuthResult(err)
		if errors.Is(err, ErrAuthRevoked) {
			return 0, err
		}
		return 0, fmt.Errorf("listing gmail messages: %w", err)
	}
	s.recordAuthResult(nil)

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
		if msgUnix > maxSeen {
			maxSeen = msgUnix
		}
		body := m.BodyText
		if len(body) > maxBody {
			body = body[:maxBody]
		}
		toJSON, _ := json.Marshal(m.To)
		ccJSON, _ := json.Marshal(m.Cc)
		labelsJSON, _ := json.Marshal(m.Labels)
		row := db.GmailMessage{
			ID: m.ID, ThreadID: m.ThreadID, FromEmail: m.FromEmail, FromName: m.FromName,
			ToJSON: string(toJSON), CcJSON: string(ccJSON), Subject: m.Subject, Snippet: m.Snippet,
			BodyText: body, InternalDate: m.InternalDate, LabelsJSON: string(labelsJSON),
			IsUnread: m.IsUnread, Permalink: m.Permalink,
		}
		if err := s.db.UpsertGmailMessage(row, syncedAt); err != nil {
			s.logger.Printf("gmail: upsert %s: %v", m.ID, err)
			continue
		}
		count++
	}

	if maxSeen > watermark {
		if err := s.db.SetGmailLastInternalDate(maxSeen); err != nil {
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
		if dbErr := s.db.SetGmailAuthState("ok", ""); dbErr != nil {
			s.logger.Printf("gmail: clear auth state: %v", dbErr)
		}
		return
	}
	status := "error"
	if errors.Is(err, ErrAuthRevoked) {
		status = "revoked"
	}
	if dbErr := s.db.SetGmailAuthState(status, err.Error()); dbErr != nil {
		s.logger.Printf("gmail: record auth state: %v", dbErr)
	}
}

// isoToUnix converts an RFC3339 timestamp to unix seconds (0 on parse failure).
func isoToUnix(iso string) float64 {
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return 0
	}
	return float64(t.Unix())
}
