package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// specReviewAnswer is OwnerAsksViewModel.specReviewAnswer: a review ask's
// answer (not a dismissal) gets its spec review's comment marks, read from
// the database now, so the phone's answer sends them as the Mac's does (F5).
// A finished author loop sends the loop's comments.
func (h *Handlers) specReviewAnswer(ask *db.OwnerAsk, a asks.Answer) (asks.Answer, error) {
	if ask.Kind != asks.KindReview || a.Dismissed {
		return a, nil
	}
	row, err := h.d.DB.GetSpecReview(ask.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		row, err = nil, nil
	}
	if err != nil {
		return a, err
	}
	marks, err := h.d.DB.ListSpecReviewMarks(ask.ID)
	if err != nil {
		return a, err
	}
	var result *specreview.Result
	var ledger []specreview.LedgerEntry
	if row != nil {
		if strings.TrimSpace(row.Result) != "" {
			var r specreview.Result
			if json.Unmarshal([]byte(row.Result), &r) == nil {
				result = &r
			}
		}
		if row.Loop == "owner" {
			// A finished loop is a non-nil ledger, empty or not.
			ledger = []specreview.LedgerEntry{}
			// An unreadable ledger is an error, never "no loop": the loop's
			// comments would be sent as plain review comments.
			if strings.TrimSpace(row.Ledger) != "" {
				if err := json.Unmarshal([]byte(row.Ledger), &ledger); err != nil {
					return a, fmt.Errorf("the author loop's ledger is unreadable")
				}
				if ledger == nil { // "null": still a finished loop
					ledger = []specreview.LedgerEntry{}
				}
			}
		}
	}
	hasComment := false
	for _, m := range marks {
		if m.State == "comment" {
			hasComment = true
		}
	}
	if ledger == nil && !hasComment {
		return a, nil
	}
	return specreview.BuildAnswer(result, marks, ledger, a, "", ask.DocSnapshot), nil
}
