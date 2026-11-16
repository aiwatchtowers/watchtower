package watchman

import (
	"context"
	"encoding/json"
	"fmt"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// specSource learns from the owner's marks on spec review findings
// (category review_doc): ok, comment (the comment as words) or not_useful
// ("finding not useful"). The situation is the finding as the reviewer put
// it; the ask's verdict is added to the words.
type specSource struct{}

func (specSource) Name() string { return SourceSpec }

func (specSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanSpecMarkRow, error) {
		return d.WatchmanSpecMarks(workbenchID, from, older, n)
	}, func(r db.WatchmanSpecMarkRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	findings := map[int64]map[string]string{} // per ask, parsed once per page
	out := make([]db.WatchmanPrecedent, 0, len(rows))
	for _, r := range rows {
		at, err := decidedAt(r.Mark)
		if err != nil {
			return nil, cur, false, err
		}
		f, ok := findings[r.AskID]
		if !ok {
			f = findingTexts(r.Result)
			findings[r.AskID] = f
		}
		text := f[r.ItemKey]
		if text == "" {
			text = r.About
		}
		choice := r.State
		if r.State == "not_useful" {
			choice = "finding not useful"
		}
		verdict := ""
		if a, err := asks.ParseAnswer([]byte(r.Answer)); err == nil && a.Verdict != "" {
			verdict = "Verdict: " + a.Verdict
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
// text; an unreadable or empty result maps nothing.
func findingTexts(result string) map[string]string {
	out := map[string]string{}
	var r specreview.Result
	if result == "" || json.Unmarshal([]byte(result), &r) != nil {
		return out
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
	return out
}
