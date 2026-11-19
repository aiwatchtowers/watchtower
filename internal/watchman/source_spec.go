package watchman

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// specSource learns from the owner's marks on spec review findings
// (category review_doc): ok, comment (the comment as words) or not_useful
// ("finding not useful"). The situation is the finding as the reviewer put
// it; the ask's verdict is added to the words. A mark whose ask answer does
// not parse is skipped; one whose review result does not parse keeps its
// about text. Both are logged by ask id and counted (SkipCounter).
type specSource struct{ skips }

func (*specSource) Name() string { return SourceSpec }

func (s *specSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanSpecMarkRow, error) {
		return d.WatchmanSpecMarks(workbenchID, from, older, n)
	}, func(r db.WatchmanSpecMarkRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	type parsed struct {
		texts map[string]string
		err   error
	}
	findings := map[int64]parsed{} // per ask, parsed once per page
	out := make([]db.WatchmanPrecedent, 0, len(rows))
	for _, r := range rows {
		id := strconv.FormatInt(r.AskID, 10)
		if r.Mark.At == "" {
			s.skip(SourceSpec, "mark of ask "+id, errNoStamp)
			continue
		}
		at, err := decidedAt(r.Mark)
		if err != nil {
			return nil, cur, false, err
		}
		answer, err := asks.ParseAnswer([]byte(r.Answer))
		if err != nil {
			s.skip(SourceSpec, "mark of ask "+id, unreadable("answer", err))
			continue
		}
		f, ok := findings[r.AskID]
		if !ok {
			f.texts, f.err = findingTexts(r.Result)
			findings[r.AskID] = f
		}
		text := f.texts[r.ItemKey]
		if f.err != nil {
			// The mark is kept with its own about text; the unreadable
			// result is still counted, once per mark it leaves without one.
			s.skip(SourceSpec, "finding text of ask "+id, f.err)
		}
		if text == "" {
			text = r.About
		}
		choice := r.State
		if r.State == "not_useful" {
			choice = "finding not useful"
		}
		verdict := ""
		if answer.Verdict != "" {
			verdict = "Verdict: " + answer.Verdict
		}
		doc := "Spec review of " + r.DocPath
		if r.DocType != "" {
			doc += " (" + r.DocType + ")"
		}
		out = append(out, db.WatchmanPrecedent{
			WorkbenchID: workbenchID, Source: SourceSpec, SourceKey: fmt.Sprintf("%d:%s", r.AskID, r.ItemKey),
			Category:   CategoryReviewDoc,
			Situation:  clean(joinNonEmpty("\n", doc, r.Title, "Finding: "+text)),
			Choice:     clean(choice),
			OwnerWords: clean(joinNonEmpty("\n", r.Body, verdict)),
			DecidedAt:  at, Weight: 1,
		})
	}
	return out, next, done, nil
}

// findingTexts maps each item key of a stored spec review result to its
// text. No result (no review ran) maps nothing; an unreadable one maps
// nothing and returns its log-safe error.
func findingTexts(result string) (map[string]string, error) {
	out := map[string]string{}
	if result == "" {
		return out, nil
	}
	var r specreview.Result
	if err := json.Unmarshal([]byte(result), &r); err != nil {
		return out, unreadable("spec review result", err)
	}
	for _, a := range r.Agreements {
		out[a.Key] = joinNonEmpty(" — ", a.Text, a.Status, a.Note)
	}
	for _, x := range r.DecidedAlone {
		out[x.Key] = joinNonEmpty(" — ", x.Text, x.Note)
	}
	for _, b := range r.BlindSpots {
		out[b.Key] = joinNonEmpty(" — ", b.Text, b.Why)
	}
	for _, c := range r.Checks {
		out[c.Key] = joinNonEmpty(" — ", c.Question, c.Answer, c.Note)
	}
	for _, t := range r.Theses {
		out[t.Key] = joinNonEmpty(" — ", t.Kind, t.Text)
	}
	return out, nil
}
