package inbox

import (
	"context"
	"fmt"
	"log"

	"watchtower/internal/db"
)

// SubmitFeedback writes a feedback row and updates learned rules based on rating/reason.
// rating: -1 negative, +1 positive. reason: one of source_noise, wrong_priority, wrong_class, never_show, ”.
// An optional logger may be passed as the last argument; if omitted, no rule-update log is emitted.
func SubmitFeedback(ctx context.Context, database *db.DB, itemID int64, rating int, reason string, logger ...*log.Logger) error {
	// 1. Write raw feedback row first — audit trail before any side effect.
	if err := database.RecordInboxFeedback(itemID, rating, reason); err != nil {
		return fmt.Errorf("record feedback: %w", err)
	}

	// 2. Load the item for sender/class info.
	item, err := database.GetInboxItem(itemID)
	if err != nil {
		return fmt.Errorf("get item: %w", err)
	}

	// 3. Apply effects per (rating, reason).
	switch {
	case rating == -1 && reason == "never_show":
		// One-click escape hatch — explicit user_rule, instant.
		if err := database.UpsertLearnedRule(db.InboxLearnedRule{
			RuleType:      "source_mute",
			ScopeKey:      "sender:" + item.SenderUserID,
			Weight:        -1.0,
			Source:        "user_rule",
			EvidenceCount: 1,
		}); err == nil && len(logger) > 0 && logger[0] != nil {
			logger[0].Printf("inbox_feedback: item=%d rating=-1 reason=never_show → user_rule source_mute sender:%s weight=-1.0",
				itemID, item.SenderUserID)
		}
	case rating == -1 && reason == "wrong_class":
		// Per-item correction: flip THIS item to ambient. No rule.
		if item.ItemClass == "actionable" {
			_ = database.SetInboxItemClass(itemID, "ambient")
		}
	}
	// All other (rating, reason) combinations: feedback row is the only
	// output. The implicit learner aggregates them on its next cycle.

	return nil
}
