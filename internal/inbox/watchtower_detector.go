package inbox

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// wtExistsInboxItem returns true if an inbox_items row already exists for the
// given (channel_id, message_ts, trigger_type) triple. Uses a package-local
// name to avoid collisions with helpers in other detector files.
func wtExistsInboxItem(database *db.DB, channelID, messageTS, triggerType string) bool {
	var n int
	database.QueryRow( //nolint:errcheck
		`SELECT COUNT(*) FROM inbox_items WHERE channel_id=? AND message_ts=? AND trigger_type=?`,
		channelID, messageTS, triggerType,
	).Scan(&n) //nolint:errcheck
	return n > 0
}

// pendingBriefing holds data for a newly detected briefing.
type pendingBriefing struct {
	msgTS string
	date  string
}

// DetectWatchtowerInternal scans briefings created after sinceTS and creates a
// briefing_ready inbox item for each new one.
//
// Returns the number of new inbox items created.
func DetectWatchtowerInternal(_ context.Context, database *db.DB, sinceTS time.Time) (int, error) {
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	// Phase 1: collect new briefings. We fully consume the rows cursor before
	// doing any further DB calls to avoid connection exhaustion on
	// single-connection (in-memory) DBs.
	var briefings []pendingBriefing
	rows, err := database.Query(
		`SELECT id, date FROM briefings WHERE created_at > ?`,
		sinceISO,
	)
	if err != nil {
		return 0, fmt.Errorf("watchtower detector query briefings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var briefingID int64
		var date string
		if err := rows.Scan(&briefingID, &date); err != nil {
			continue
		}
		briefings = append(briefings, pendingBriefing{
			msgTS: fmt.Sprintf("briefing:%d", briefingID),
			date:  date,
		})
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("watchtower detector iterate briefings: %w", err)
	}

	// Phase 2: dedup-check and create inbox items (rows fully closed above).
	created := 0
	for _, b := range briefings {
		if wtExistsInboxItem(database, "briefing", b.msgTS, "briefing_ready") {
			continue
		}
		now := time.Now().UTC().Format(time.RFC3339)
		item := db.InboxItem{
			ChannelID:    "briefing",
			MessageTS:    b.msgTS,
			SenderUserID: "watchtower",
			TriggerType:  "briefing_ready",
			Snippet:      "Daily briefing ready for " + b.date,
			ItemClass:    DefaultItemClass("briefing_ready"),
			Status:       "pending",
			Priority:     "low",
			CreatedAt:    now,
			UpdatedAt:    now,
		}
		if _, err := database.CreateInboxItem(item); err == nil {
			created++
		}
	}
	return created, nil
}
