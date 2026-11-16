package watchman

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// reviewSource learns from the diff review (category review_code): a comment
// of a sent round (choice "comment", the body as words), each sent round's
// outcome (approve or changes), an undone hunk (weight 2) and a decided
// review lesson (accepted or dismissed).
type reviewSource struct{ skips }

func (*reviewSource) Name() string { return SourceReview }

func (s *reviewSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanReviewRow, error) {
		return d.WatchmanReviewComments(workbenchID, from, older, n)
	}, func(r db.WatchmanReviewRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	out := make([]db.WatchmanPrecedent, 0, len(rows))
	for _, r := range rows {
		if r.Mark.At == "" {
			s.skip(SourceReview, fmt.Sprintf("%s:%d", r.Kind, r.ID), errNoStamp)
			continue
		}
		at, err := decidedAt(r.Mark)
		if err != nil {
			return nil, cur, false, err
		}
		p := db.WatchmanPrecedent{
			WorkbenchID: workbenchID, Source: SourceReview, SourceKey: fmt.Sprintf("%s:%d", r.Kind, r.ID),
			Category: CategoryReviewCode, DecidedAt: at, Weight: 1,
		}
		switch r.Kind {
		case db.WatchmanReviewComment:
			p.Situation = joinNonEmpty("\n", r.Path, lensLine(r.Lens), r.Quote)
			p.Choice, p.OwnerWords = "comment", r.Body
		case db.WatchmanReviewRound:
			p.Situation = joinNonEmpty("\n", "Review round of "+r.Ref,
				fmt.Sprintf("%d comments", r.Comments), filesLine(r.Path))
			p.Choice, p.OwnerWords = roundChoice(r.Outcome), r.Body
		case db.WatchmanReviewRevert:
			p.Situation = joinNonEmpty("\n", r.Path, r.Header, r.Patch)
			p.Choice, p.Weight = "undid hunk", 2
		case db.WatchmanReviewLesson:
			p.Situation = joinNonEmpty("\n", lensLine(r.Lens), r.Body)
			p.Choice = r.Status
		default:
			return nil, cur, false, fmt.Errorf("watchman review row: unknown kind %q", r.Kind)
		}
		p.Situation, p.Choice, p.OwnerWords = clean(p.Situation), clean(p.Choice), clean(p.OwnerWords)
		out = append(out, p)
	}
	return out, next, done, nil
}

func lensLine(lens string) string {
	if strings.TrimSpace(lens) == "" {
		return ""
	}
	return "Lens: " + lens
}

func filesLine(paths string) string {
	if paths == "" {
		return ""
	}
	return "Files: " + strings.ReplaceAll(paths, ",", ", ")
}

// roundChoice maps a round's stored outcome to the decision's choice.
func roundChoice(outcome string) string {
	if outcome == db.ReviewOutcomeApproved {
		return "approve"
	}
	return "changes"
}
