package handlers

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"unicode"

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
	loop := false
	if row != nil {
		if strings.TrimSpace(row.Result) != "" {
			var r specreview.Result
			if json.Unmarshal([]byte(row.Result), &r) == nil {
				result = &r
			}
		}
		if row.Loop == "owner" {
			loop = true
			_ = json.Unmarshal([]byte(row.Ledger), &ledger)
		}
	}
	hasComment := false
	for _, m := range marks {
		if m.State == "comment" {
			hasComment = true
		}
	}
	if !loop && !hasComment {
		return a, nil
	}
	return buildSpecReviewAnswer(result, marks, ledger, loop, a, ask.DocSnapshot), nil
}

// finding is SpecReviewFinding: a result item a mark can comment on.
type finding struct {
	key, chapter, text string
	anchor             *specreview.Anchor
}

func findings(r *specreview.Result) []finding {
	if r == nil {
		return nil
	}
	var out []finding
	for _, x := range r.Agreements {
		out = append(out, finding{x.Key, x.Chapter, x.Text, x.Where})
	}
	for _, x := range r.DecidedAlone {
		w := x.Where
		out = append(out, finding{x.Key, x.Chapter, x.Text, &w})
	}
	for _, x := range r.BlindSpots {
		out = append(out, finding{x.Key, x.Chapter, x.Text, x.Where})
	}
	for _, x := range r.Checks {
		out = append(out, finding{x.Key, x.Chapter, x.Question, nil})
	}
	return out
}

// buildSpecReviewAnswer is SpecReviewAnswer.build: base with the marks'
// comments after its own; with a finished loop, the loop's comments first,
// then those of marks the ledger never carried.
//
// Known divergence: Swift re-locates each quote in the rendered snapshot
// (DocumentRendering) to fill prefix and suffix; Go has no markdown renderer,
// so a comment carries the heading and quote with empty context.
func buildSpecReviewAnswer(result *specreview.Result, marks map[string]db.SpecReviewMark,
	ledger []specreview.LedgerEntry, loop bool, base asks.Answer, snapshot string) asks.Answer {
	out := base
	out.Comments = append([]asks.Comment{}, base.Comments...)
	if !loop {
		out.Comments = append(out.Comments, markComments(result, marks, snapshot)...)
		return out
	}
	inLedger := map[string]bool{}
	for _, e := range ledger {
		inLedger[e.Key] = true
		m, ok := marks[e.Key]
		if !ok || m.State != "comment" {
			continue
		}
		var anchor [2]string
		switch {
		case e.Where != nil && e.Where.Quote != "":
			anchor = [2]string{e.Where.Heading, e.Where.Quote}
		default:
			chapter := ""
			for _, f := range findings(result) {
				if f.key == e.Key {
					chapter = f.chapter
					break
				}
			}
			if a, ok := chapterAnchor(result, chapter, snapshot); ok {
				anchor = a
			} else {
				anchor = firstHeadingAnchor(snapshot)
			}
		}
		out.Comments = append(out.Comments, asks.Comment{Heading: anchor[0], Quote: anchor[1], Body: loopBody(e, m.Body)})
	}
	rest := map[string]db.SpecReviewMark{}
	for k, m := range marks {
		if !inLedger[k] {
			rest[k] = m
		}
	}
	out.Comments = append(out.Comments, markComments(result, rest, snapshot)...)
	return out
}

// loopBody is SpecReviewAnswer.loopBody.
func loopBody(e specreview.LedgerEntry, owner string) string {
	var head string
	if e.Verdict == "resolved" {
		head = "Reopened: " + e.Text
	} else {
		reason := ""
		if e.Reply != nil {
			reason = strings.TrimSpace(e.Reply.Note)
		}
		note := strings.TrimSpace(e.VerdictNote)
		disagree := e.Reply != nil && e.Reply.Reply == "disagree"
		if e.Verdict == "unsettled" && note != "" && (note == reason || !disagree) {
			note = strings.TrimSpace(e.Note)
		}
		head = "Reviewer is right: " + e.Text
		if note != "" {
			head += " — " + note
		}
	}
	if o := strings.TrimSpace(owner); o != "" {
		return head + "\n\n" + o
	}
	return head
}

// markComments is SpecReviewAnswer.comments: the comment marks in findings
// order, then the marks whose finding the result no longer has (no result:
// every comment mark), as "From the previous run".
func markComments(result *specreview.Result, marks map[string]db.SpecReviewMark, snapshot string) []asks.Comment {
	var out []asks.Comment
	known := map[string]bool{}
	for _, f := range findings(result) {
		known[f.key] = true
		m, ok := marks[f.key]
		if !ok || m.State != "comment" {
			continue
		}
		var anchor [2]string
		if f.anchor != nil {
			anchor = [2]string{f.anchor.Heading, f.anchor.Quote}
		} else if a, ok := chapterAnchor(result, f.chapter, snapshot); ok {
			anchor = a
		} else {
			anchor = firstHeadingAnchor(snapshot)
		}
		out = append(out, asks.Comment{Heading: anchor[0], Quote: anchor[1], Body: joinBody(f.text, m.Body)})
	}
	var orphans []string
	for k, m := range marks {
		if m.State == "comment" && !known[k] {
			orphans = append(orphans, k)
		}
	}
	sort.Strings(orphans)
	if len(orphans) == 0 {
		return out
	}
	anchor := firstHeadingAnchor(snapshot)
	for _, k := range orphans {
		m := marks[k]
		about := m.Body
		if m.About != "" {
			about = joinBody(m.About, m.Body)
		}
		out = append(out, asks.Comment{Heading: anchor[0], Quote: anchor[1], Body: "From the previous run: " + about})
	}
	return out
}

func joinBody(text, body string) string {
	if o := strings.TrimSpace(body); o != "" {
		return text + " — " + o
	}
	return text
}

// chapterAnchor is the chapter heading with the chapter's first body line as
// the quote; offsets are UTF-8 bytes, an unknown chapter or bad range is false.
func chapterAnchor(result *specreview.Result, key, snapshot string) ([2]string, bool) {
	if result == nil {
		return [2]string{}, false
	}
	for _, c := range result.Chapters {
		if c.Key != key {
			continue
		}
		if c.Start < 0 || c.Start > c.End || c.End > len(snapshot) {
			return [2]string{}, false
		}
		return headingAndQuote(snapshot[c.Start:c.End], c.Heading), true
	}
	return [2]string{}, false
}

// firstHeadingAnchor is the document's first heading and that section's
// first body line; with no heading, the document's first body line.
func firstHeadingAnchor(snapshot string) [2]string {
	inFence := false
	offset := 0
	for _, line := range strings.Split(snapshot, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			inFence = !inFence
		}
		if !inFence && headingTitle(trimmed) != "" {
			return headingAndQuote(snapshot[offset:], "")
		}
		offset += len(line) + 1
	}
	return headingAndQuote(snapshot, "")
}

// headingAndQuote: the heading is its title and the quote the first body line
// (heading lines and fenced code skipped), leading list and quote markers
// rendered away; a section with no body line quotes its title.
func headingAndQuote(slice, fallback string) [2]string {
	heading := ""
	inFence := false
	for _, line := range strings.Split(slice, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			inFence = !inFence
			continue
		}
		if inFence || trimmed == "" {
			continue
		}
		if title := headingTitle(trimmed); title != "" {
			if heading == "" {
				heading = title
			}
			continue
		}
		if quote := renderedQuote(trimmed); quote != "" {
			if heading == "" {
				heading = plainTitle(fallback)
			}
			return [2]string{heading, quote}
		}
	}
	if heading == "" {
		heading = plainTitle(fallback)
	}
	return [2]string{heading, heading}
}

func plainTitle(h string) string {
	return strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(h), "#"))
}

// headingTitle is an ATX heading line's title ("## Title"); "" otherwise.
func headingTitle(line string) string {
	n := len(line) - len(strings.TrimLeft(line, "#"))
	if n < 1 || n > 6 || len(line) == n || (line[n] != ' ' && line[n] != '\t') {
		return ""
	}
	return strings.TrimSpace(line[n:])
}

// renderedQuote strips quote and list markers and the inline emphasis and
// code markers (an approximation of Swift's DocumentRendering).
func renderedQuote(line string) string {
	text := strings.TrimLeft(line, "> ")
	switch {
	case len(text) > 1 && strings.ContainsRune("-*+", rune(text[0])) && text[1] == ' ':
		text = text[2:]
	default:
		if dot := strings.IndexByte(text, '.'); dot > 0 && dot+1 < len(text) && text[dot+1] == ' ' &&
			strings.IndexFunc(text[:dot], func(r rune) bool { return !unicode.IsDigit(r) }) < 0 {
			text = text[dot+2:]
		}
	}
	text = strings.NewReplacer("**", "", "__", "", "`", "").Replace(text)
	return strings.TrimSpace(text)
}
