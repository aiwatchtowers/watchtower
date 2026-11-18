package watchman

import (
	"context"
	"strconv"

	"watchtower/internal/db"
)

// Journal precedent weights: an owner's correction teaches more than an OK.
const (
	journalOKWeight        = 1
	journalCorrectedWeight = 3
)

// journalSource learns from the morning journal: a twin decision the owner
// marked OK becomes a precedent with the twin's choice, one he corrected
// becomes a precedent with his own words. An item with no feedback is never
// read, so the twin's own write cannot reinforce itself (WATCHMAN-03).
type journalSource struct{ skips }

func (*journalSource) Name() string { return SourceJournal }

func (s *journalSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanJournalRow, error) {
		return d.WatchmanJournalFeedback(workbenchID, from, older, n)
	}, func(r db.WatchmanJournalRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	out := make([]db.WatchmanPrecedent, 0, len(rows))
	for _, r := range rows {
		if r.Mark.At == "" {
			s.skip(SourceJournal, strconv.FormatInt(r.ID, 10), errNoStamp)
			continue
		}
		at, err := decidedAt(r.Mark)
		if err != nil {
			return nil, cur, false, err
		}
		choice, weight := r.Choice, float64(journalOKWeight)
		if r.Feedback == "corrected" {
			choice, weight = r.FeedbackText, journalCorrectedWeight
		}
		yes := true
		out = append(out, db.WatchmanPrecedent{
			WorkbenchID: workbenchID, Source: SourceJournal, SourceKey: strconv.FormatInt(r.ID, 10),
			Category: r.Category, Situation: clean(r.Question), Choice: clean(choice),
			DecidedAt: at, Weight: weight, IsDecision: &yes,
		})
	}
	return out, next, done, nil
}
