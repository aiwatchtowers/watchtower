package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// asksSource learns from answered owner asks. A review ask is a review_doc
// decision (its verdict, its comments as the owner's words); a question or
// check ask is left unlabelled (Category "") for the runner's labeller. A
// dismissed ask is no decision and is left out; a row that cannot be read
// (payload or answer JSON, a review with no verdict, no answered_at) is
// skipped, logged by id and counted (SkipCounter). The cursor moves past both.
//
// Handover asks (finish_session's handover_ask_id) carry no mark in the
// database: the id is only checked and echoed by finish_session, and the ask
// is an ordinary ask_owner with an agent-written title. They come through as
// questions and are labelled like any other (finish is one of the labels).
type asksSource struct{ skips }

func (*asksSource) Name() string { return SourceAsk }

func (s *asksSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanAskRow, error) {
		return d.AnsweredOwnerAsks(workbenchID, from, older, n)
	}, func(r db.WatchmanAskRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	var out []db.WatchmanPrecedent
	for _, r := range rows {
		p, ok, err := askPrecedent(workbenchID, r)
		if err != nil {
			s.skip(SourceAsk, strconv.FormatInt(r.ID, 10), err)
			continue
		}
		if ok {
			out = append(out, p)
		}
	}
	return out, next, done, nil
}

// askPrecedent maps one ask: ok false for a dismissed ask (no decision), an
// error (log-safe) for a row that cannot be read, which the caller counts.
func askPrecedent(workbenchID int64, r db.WatchmanAskRow) (db.WatchmanPrecedent, bool, error) {
	if r.Mark.At == "" {
		return db.WatchmanPrecedent{}, false, errNoStamp
	}
	at, err := decidedAt(r.Mark)
	if err != nil {
		return db.WatchmanPrecedent{}, false, err
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(r.Payload), &payload); err != nil {
		return db.WatchmanPrecedent{}, false, unreadable("payload", err)
	}
	answer, err := asks.ParseAnswer([]byte(r.Answer))
	if err != nil {
		return db.WatchmanPrecedent{}, false, unreadable("answer", err)
	}
	if answer.Dismissed {
		return db.WatchmanPrecedent{}, false, nil
	}
	p := db.WatchmanPrecedent{
		WorkbenchID: workbenchID, Source: SourceAsk, SourceKey: strconv.FormatInt(r.ID, 10),
		DecidedAt: at, Weight: 1,
	}
	head := joinNonEmpty("\n", r.Title, r.Summary, r.Changes)
	switch r.Kind {
	case asks.KindReview:
		if answer.Verdict == "" {
			return db.WatchmanPrecedent{}, false, errors.New("review answer has no verdict")
		}
		p.Category = CategoryReviewDoc
		doc := "Review of " + r.DocPath
		if r.DocType != "" {
			doc += " (" + r.DocType + ")"
		}
		p.Situation = joinNonEmpty("\n", doc, head, focusText(payload.Focus), r.DocSnapshot)
		p.Choice = answer.Verdict
		p.OwnerWords = joinNonEmpty("\n", answer.Note, commentsText(answer.Comments))
	case asks.KindCheck:
		p.Situation = joinNonEmpty("\n", head, checklistText(payload.Checklist))
		p.Choice, p.OwnerWords = checkChoice(payload.Checklist, answer.Checklist)
		p.OwnerWords = joinNonEmpty("\n", p.OwnerWords, answer.Note)
	default: // question
		p.Situation = joinNonEmpty("\n", head, questionsText(payload.Questions))
		p.Choice, p.OwnerWords = questionChoice(payload.Questions, answer.Answers)
		p.OwnerWords = joinNonEmpty("\n", p.OwnerWords, answer.Note)
	}
	p.Situation, p.Choice, p.OwnerWords = clean(p.Situation), clean(p.Choice), clean(p.OwnerWords)
	return p, true, nil
}

func focusText(fs []asks.Focus) string {
	var b []string
	for _, f := range fs {
		b = append(b, "Focus: "+joinNonEmpty(" — ", f.Heading, f.Text, f.Quote))
	}
	return strings.Join(b, "\n")
}

func commentsText(cs []asks.Comment) string {
	var b []string
	for _, c := range cs {
		q := ""
		if strings.TrimSpace(c.Quote) != "" {
			q = "> " + strings.TrimSpace(c.Quote)
		}
		b = append(b, joinNonEmpty("\n", q, c.Body))
	}
	return strings.Join(b, "\n")
}

func questionsText(qs []asks.Question) string {
	var b []string
	for _, q := range qs {
		b = append(b, q.Question)
		for _, o := range q.Options {
			line := "- " + o.Label
			if o.Recommended {
				line += " (recommended)"
			}
			if o.Description != "" {
				line += ": " + o.Description
			}
			b = append(b, line)
		}
	}
	return strings.Join(b, "\n")
}

// questionChoice is the chosen labels (per question when there are several,
// "free answer" when the owner only wrote one) and the owner's free texts.
func questionChoice(qs []asks.Question, as []asks.QuestionAnswer) (choice, words string) {
	byID := map[string]asks.QuestionAnswer{}
	for _, a := range as {
		byID[a.ID] = a
	}
	var choices, texts []string
	for _, q := range qs {
		a, ok := byID[q.ID]
		if !ok {
			continue
		}
		c := strings.Join(a.Labels, ", ")
		if c == "" && strings.TrimSpace(a.Other) != "" {
			c = "free answer"
		}
		if len(qs) > 1 {
			c = q.Question + ": " + c
		}
		choices = append(choices, c)
		texts = append(texts, strings.TrimSpace(a.Other))
	}
	return strings.Join(choices, "\n"), joinNonEmpty("\n", texts...)
}

func checklistText(items []asks.ChecklistItem) string {
	var b []string
	for _, it := range items {
		b = append(b, "- "+it.Text)
	}
	return strings.Join(b, "\n")
}

// checkChoice is "ok" when every item passed, else the items not ok with
// their state; words are the owner's item notes.
func checkChoice(items []asks.ChecklistItem, marks []asks.CheckAnswer) (choice, words string) {
	text := map[string]string{}
	for _, it := range items {
		text[it.ID] = it.Text
	}
	var bad, notes []string
	for _, m := range marks {
		if m.State != asks.StateOK {
			bad = append(bad, m.State+": "+text[m.ID])
		}
		if n := strings.TrimSpace(m.Note); n != "" {
			notes = append(notes, text[m.ID]+": "+n)
		}
	}
	if len(bad) == 0 {
		return asks.StateOK, strings.Join(notes, "\n")
	}
	return strings.Join(bad, "\n"), strings.Join(notes, "\n")
}
