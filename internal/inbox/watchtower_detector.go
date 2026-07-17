package inbox

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// digestSituation is a minimal representation of a situation JSON entry used for
// decision detection. Only the fields relevant to this detector are decoded.
type digestSituation struct {
	Type       string `json:"type"`
	Topic      string `json:"topic"`
	Importance string `json:"importance"`
}

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

// pendingDecision holds data for a high-importance decision extracted from a digest.
type pendingDecision struct {
	channelID string
	msgTS     string
	topic     string
}

// pendingBriefing holds data for a newly detected briefing.
type pendingBriefing struct {
	msgTS string
	date  string
}

// DetectWatchtowerInternal scans digests and briefings created after sinceTS
// and creates inbox items for:
//   - decision_made  — digest situations of type="decision" with importance="high"
//   - briefing_ready — any new briefing row
//
// Returns the number of new inbox items created.
func DetectWatchtowerInternal(_ context.Context, database *db.DB, sinceTS time.Time) (int, error) {
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	// Phase 1: collect high-importance decisions from digests.
	// We fully consume the rows cursor before doing any further DB calls to
	// avoid connection exhaustion on single-connection (in-memory) DBs.
	var decisions []pendingDecision
	rows, err := database.Query(
		`SELECT id, channel_id, situations FROM digests
		 WHERE created_at > ? AND situations IS NOT NULL AND situations != '' AND situations != '[]'`,
		sinceISO,
	)
	if err != nil {
		return 0, fmt.Errorf("watchtower detector query digests: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var digestID int64
		var channelID, situations string
		if err := rows.Scan(&digestID, &channelID, &situations); err != nil {
			continue
		}
		var list []digestSituation
		if err := json.Unmarshal([]byte(situations), &list); err != nil {
			continue
		}
		for idx, s := range list {
			if s.Type == "decision" && s.Importance == "high" {
				decisions = append(decisions, pendingDecision{
					channelID: channelID,
					msgTS:     fmt.Sprintf("digest:%d:%d", digestID, idx),
					topic:     s.Topic,
				})
			}
		}
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("watchtower detector iterate digests: %w", err)
	}

	// Phase 2: collect new briefings.
	var briefings []pendingBriefing
	rows, err = database.Query(
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

	// Phase 3: dedup-check and create inbox items (rows fully closed above).
	created := 0
	for _, d := range decisions {
		if wtExistsInboxItem(database, d.channelID, d.msgTS, "decision_made") {
			continue
		}
		now := time.Now().UTC().Format(time.RFC3339)
		item := db.InboxItem{
			ChannelID:    d.channelID,
			MessageTS:    d.msgTS,
			SenderUserID: "watchtower",
			TriggerType:  "decision_made",
			Snippet:      d.topic,
			ItemClass:    DefaultItemClass("decision_made"),
			Status:       "pending",
			Priority:     "medium",
			CreatedAt:    now,
			UpdatedAt:    now,
		}
		if _, err := database.CreateInboxItem(item); err == nil {
			created++
		}
	}
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

// memoryDisputeCap bounds how many dispute_pending beliefs the detector turns
// into trigger items per cycle. Uncapped, a large backlog of freshly-flagged
// beliefs would flood the dashboard in a single run; the survivors carry over
// to the next cycle (their flags stay set).
const memoryDisputeCap = 2

// detectMemoryDisputes surfaces the memory pipeline's dispute_pending beliefs
// (a serious belief disagreement — "the arguing secretary") as ordinary
// watchtower trigger items. Each flagged belief becomes one decision_made item
// (channel_id="memory", message_ts="dispute:<belief_id>") whose flag is cleared
// in the SAME transaction that mints the item, so a dispute is surfaced exactly
// once even if the process dies mid-cycle. From there the standard pipeline
// owns it: triage may rank/downgrade but never drops it (INBOX-01), and compose
// merges it into a dashboard situation (DASH-01).
//
// MEM-05/MEM-10: the inbox package legitimately owns inbox_items and reads/clears
// the flag; the memory package never touches inbox tables. INBOX-09 is untouched
// — this is an ordinary detector called before triage, so a returned error
// freezes the watermark exactly like any other detector failure (see detectAll).
//
// The gate (memory.surfaces.disputes) is passed as enabled: when off, this is a
// pure no-op — no reads, no writes, flags untouched.
func detectMemoryDisputes(database *db.DB, enabled bool) (int, error) {
	if !enabled {
		return 0, nil
	}
	beliefs, err := database.ListDisputePendingBeliefs(memoryDisputeCap)
	if err != nil {
		return 0, fmt.Errorf("watchtower detector list disputes: %w", err)
	}

	created := 0
	for _, b := range beliefs {
		minted, err := mintDisputeItem(database, b.ID, b.Title)
		if err != nil {
			return created, fmt.Errorf("watchtower detector mint dispute %s: %w", b.ID, err)
		}
		if minted {
			created++
		}
	}
	return created, nil
}

// mintDisputeItem surfaces a dispute trigger item for a belief and clears its
// dispute flag in a single transaction. Dedup keys only on LIVE prior items
// (archived_at IS NULL AND status NOT IN ('resolved','dismissed') — the same
// liveness predicate ListInboxFeed uses): a still-open dispute item for this
// belief blocks a duplicate (minted=false), but an item the owner already
// archived or resolved never blocks a fresh re-dispute — otherwise the very
// first dispute would suppress the belief forever once its item aged out.
//
// The message_ts is the stable dispute:<belief_id> identity (MEM-10), so a
// re-dispute cannot INSERT a second row past the UNIQUE(channel_id, message_ts)
// index; instead a dead prior row is REVIVED in place back to a fresh pending
// item (new snippet/timestamps, card + composed state reset so the dashboard
// re-composes it). The flag is always cleared so a re-flagged belief whose item
// is still live does not loop. Any DB error rolls the whole unit back: neither
// the item nor the flag change commits, so the dispute survives for a later
// cycle rather than being lost.
//
// The inserts/updates run on tx directly (not db.CreateInboxItem) because that
// helper has no transaction-scoped variant — the mint and the same-tx flag
// clear must be atomic (MEM-10 "surfaced exactly once").
func mintDisputeItem(database *db.DB, beliefID, statement string) (bool, error) {
	messageTS := "dispute:" + beliefID
	snippet := statement + " — evidence conflicts [[" + beliefID + "]]"

	tx, err := database.Begin()
	if err != nil {
		return false, fmt.Errorf("beginning dispute tx: %w", err)
	}
	defer tx.Rollback()

	// Look up any prior decision_made dispute row for this belief and whether it
	// is still live. Other trigger types at the same (channel_id, message_ts) are
	// intentionally ignored here: they still collide on the UNIQUE index at INSERT.
	var status, archivedAt sql.NullString
	err = tx.QueryRow(
		`SELECT status, archived_at FROM inbox_items
		 WHERE channel_id='memory' AND message_ts=? AND trigger_type='decision_made'`,
		messageTS,
	).Scan(&status, &archivedAt)
	switch {
	case err == sql.ErrNoRows:
		// No prior dispute item — insert a fresh one below.
	case err != nil:
		return false, fmt.Errorf("dispute dedup check: %w", err)
	default:
		archived := archivedAt.Valid && archivedAt.String != ""
		live := !archived && status.String != "resolved" && status.String != "dismissed"
		if live {
			// Already surfaced and still open: no duplicate, just clear the flag.
			if _, err := tx.Exec(`DELETE FROM memory_dispute_flags WHERE node_id = ?`, beliefID); err != nil {
				return false, fmt.Errorf("clearing dispute flag %s: %w", beliefID, err)
			}
			if err := tx.Commit(); err != nil {
				return false, fmt.Errorf("committing dispute tx %s: %w", beliefID, err)
			}
			return false, nil
		}
		// A dead (archived/resolved/dismissed) prior item: revive it in place so
		// the re-dispute surfaces again without breaking the UNIQUE identity.
		now := time.Now().UTC().Format(time.RFC3339)
		if _, err := tx.Exec(`UPDATE inbox_items
			SET snippet=?, status='pending', priority='medium', item_class=?,
			    archived_at=NULL, archive_reason='', read_at=NULL,
			    card_status='none', composed_at=NULL, created_at=?, updated_at=?
			WHERE channel_id='memory' AND message_ts=? AND trigger_type='decision_made'`,
			snippet, DefaultItemClass("decision_made"), now, now, messageTS,
		); err != nil {
			return false, fmt.Errorf("reviving dispute item: %w", err)
		}
		if _, err := tx.Exec(`DELETE FROM memory_dispute_flags WHERE node_id = ?`, beliefID); err != nil {
			return false, fmt.Errorf("clearing dispute flag %s: %w", beliefID, err)
		}
		if err := tx.Commit(); err != nil {
			return false, fmt.Errorf("committing dispute tx %s: %w", beliefID, err)
		}
		return true, nil
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := tx.Exec(`INSERT INTO inbox_items
		(channel_id, message_ts, sender_user_id, trigger_type, snippet, status, priority, item_class, created_at, updated_at)
		VALUES ('memory', ?, 'watchtower', 'decision_made', ?, 'pending', 'medium', ?, ?, ?)`,
		messageTS, snippet, DefaultItemClass("decision_made"), now, now,
	); err != nil {
		return false, fmt.Errorf("inserting dispute item: %w", err)
	}

	// Clear the flag in the SAME tx as the mint — atomic, so the dispute is
	// surfaced exactly once (or, on rollback, not at all — never half-done).
	if _, err := tx.Exec(`DELETE FROM memory_dispute_flags WHERE node_id = ?`, beliefID); err != nil {
		return false, fmt.Errorf("clearing dispute flag %s: %w", beliefID, err)
	}

	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("committing dispute tx %s: %w", beliefID, err)
	}
	return true, nil
}
