package inbox

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

const (
	minEvidence   = 5
	rateThreshold = 0.70
	senderMute    = -0.7
	senderBoost   = 0.7
	channelMute   = -0.5
	muteRateChan  = 0.7
)

type ruleStat struct {
	key      string
	weight   float64
	evidence int
}

// RunImplicitLearner aggregates implicit dismissals from inbox_items and
// explicit ratings from inbox_feedback over the lookback window. It
// produces source_mute / source_boost rules with source='implicit' when
// thresholds are crossed (evidence >= 5, rate > 0.70). user_rule scopes
// are protected by UpsertLearnedRuleImplicit.
func RunImplicitLearner(ctx context.Context, database *db.DB, lookback time.Duration) (int, error) {
	cutoff := time.Now().Add(-lookback).UTC().Format(time.RFC3339)

	var rules []ruleStat

	// Per-sender unified pool.
	senderRows, err := database.Query(`
		WITH events AS (
			SELECT sender_user_id AS sender, -1 AS sign
			  FROM inbox_items
			 WHERE status='dismissed' AND created_at > ?
			UNION ALL
			SELECT i.sender_user_id AS sender, -1 AS sign
			  FROM inbox_feedback f
			  JOIN inbox_items i ON i.id = f.inbox_item_id
			 WHERE f.rating = -1 AND f.reason != 'never_show' AND f.created_at > ?
			UNION ALL
			SELECT i.sender_user_id AS sender, +1 AS sign
			  FROM inbox_feedback f
			  JOIN inbox_items i ON i.id = f.inbox_item_id
			 WHERE f.rating = 1 AND f.created_at > ?
			UNION ALL
			SELECT sender_user_id AS sender, 0 AS sign
			  FROM inbox_items
			 WHERE status != 'dismissed' AND created_at > ?
			   AND id NOT IN (SELECT inbox_item_id FROM inbox_feedback WHERE created_at > ?)
		)
		SELECT sender,
		       COUNT(*) AS total,
		       SUM(CASE WHEN sign = -1 THEN 1 ELSE 0 END) AS negatives,
		       SUM(CASE WHEN sign = +1 THEN 1 ELSE 0 END) AS positives
		FROM events
		GROUP BY sender
		HAVING total >= ?
	`, cutoff, cutoff, cutoff, cutoff, cutoff, minEvidence)
	if err != nil {
		return 0, fmt.Errorf("sender query: %w", err)
	}
	for senderRows.Next() {
		var sender string
		var total, negatives, positives int
		if err := senderRows.Scan(&sender, &total, &negatives, &positives); err != nil {
			senderRows.Close()
			return 0, fmt.Errorf("sender scan: %w", err)
		}
		negRate := float64(negatives) / float64(total)
		posRate := float64(positives) / float64(total)
		switch {
		case negRate > rateThreshold:
			rules = append(rules, ruleStat{key: "sender:" + sender, weight: senderMute, evidence: negatives})
		case posRate > rateThreshold:
			rules = append(rules, ruleStat{key: "sender:" + sender, weight: senderBoost, evidence: positives})
		}
	}
	if err := senderRows.Err(); err != nil {
		senderRows.Close()
		return 0, fmt.Errorf("sender rows: %w", err)
	}
	senderRows.Close()

	// Per-channel unified pool — negatives only (no boost on channel side).
	chanRows, err := database.Query(`
		WITH events AS (
			SELECT channel_id AS ch, -1 AS sign
			  FROM inbox_items
			 WHERE status='dismissed' AND created_at > ?
			UNION ALL
			SELECT i.channel_id AS ch, -1 AS sign
			  FROM inbox_feedback f
			  JOIN inbox_items i ON i.id = f.inbox_item_id
			 WHERE f.rating = -1 AND f.reason != 'never_show' AND f.created_at > ?
			UNION ALL
			SELECT i.channel_id AS ch, 0 AS sign
			  FROM inbox_items i
			 WHERE i.status != 'dismissed' AND i.created_at > ?
			   AND i.id NOT IN (SELECT inbox_item_id FROM inbox_feedback WHERE created_at > ?)
		)
		SELECT ch,
		       COUNT(*) AS total,
		       SUM(CASE WHEN sign = -1 THEN 1 ELSE 0 END) AS negatives
		FROM events
		GROUP BY ch
		HAVING total >= ?
	`, cutoff, cutoff, cutoff, cutoff, minEvidence)
	if err != nil {
		return 0, fmt.Errorf("channel query: %w", err)
	}
	for chanRows.Next() {
		var ch string
		var total, negatives int
		if err := chanRows.Scan(&ch, &total, &negatives); err != nil {
			chanRows.Close()
			return 0, fmt.Errorf("channel scan: %w", err)
		}
		if float64(negatives)/float64(total) > muteRateChan {
			rules = append(rules, ruleStat{key: "channel:" + ch, weight: channelMute, evidence: negatives})
		}
	}
	if err := chanRows.Err(); err != nil {
		chanRows.Close()
		return 0, fmt.Errorf("channel rows: %w", err)
	}
	chanRows.Close()

	// Upsert all collected rules.
	upserted := 0
	for _, r := range rules {
		ruleType := "source_mute"
		if r.weight > 0 {
			ruleType = "source_boost"
		}
		if err := database.UpsertLearnedRuleImplicit(db.InboxLearnedRule{
			RuleType:      ruleType,
			ScopeKey:      r.key,
			Weight:        r.weight,
			EvidenceCount: r.evidence,
		}); err != nil {
			return upserted, err
		}
		upserted++
	}
	return upserted, nil
}
