package specreview

import (
	"sort"
	"strings"
	"time"
	"unicode"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// answerFinding is SpecReviewFinding: a result item a mark can comment on.
type answerFinding struct {
	key, chapter, text string
	anchor             *Anchor
}

func answerFindings(r *Result) []answerFinding {
	if r == nil {
		return nil
	}
	var out []answerFinding
	for _, x := range r.Agreements {
		out = append(out, answerFinding{x.Key, x.Chapter, x.Text, x.Where})
	}
	for _, x := range r.DecidedAlone {
		w := x.Where
		out = append(out, answerFinding{x.Key, x.Chapter, x.Text, &w})
	}
	for _, x := range r.BlindSpots {
		out = append(out, answerFinding{x.Key, x.Chapter, x.Text, x.Where})
	}
	for _, x := range r.Checks {
		out = append(out, answerFinding{x.Key, x.Chapter, x.Question, nil})
	}
	return out
}

// TwinMark is the twin's mark on one finding of a spec review: State is ok,
// comment or not_useful, Body the twin's words on a comment.
type TwinMark struct {
	Key, State, Body string
}

// FindingText is a finding a twin mark may name: its key and its text.
type FindingText struct {
	Key, Text string
}

// MarkableFindings lists the findings AnswerMarks accepts marks on, once
// per key: the result's (agreements, decided alone, blind spots, checks),
// then the ledger's keys the result does not have.
func MarkableFindings(result *Result, loop []LedgerEntry) []FindingText {
	seen := map[string]bool{}
	var out []FindingText
	add := func(key, text string) {
		if !seen[key] {
			seen[key] = true
			out = append(out, FindingText{Key: key, Text: text})
		}
	}
	for _, f := range answerFindings(result) {
		add(f.key, f.text)
	}
	for _, e := range loop {
		add(e.Key, e.Text)
	}
	return out
}

// AnswerMarks is what the twin's marks make of a review answer: the marks as
// the Mac would store them (the finding's text kept as About on a comment) and
// the answer, built by BuildAnswer over those marks, so its comments are
// exactly what the Desktop's builder gives for the same marks. A key neither
// the result nor the ledger has is dropped (as an unfound quote is), and so is
// a state no mark has. A nil loop is a review without an author loop; a
// non-nil one, even empty, is a finished loop's ledger. A non-empty verdict
// replaces the base's (here there is none: the twin's own answer).
func AnswerMarks(askID int64, result *Result, loop []LedgerEntry, twin []TwinMark,
	verdict string, snapshot string, at time.Time) (asks.Answer, []db.SpecReviewMark) {
	known := map[string]string{}
	for _, f := range MarkableFindings(result, loop) {
		known[f.Key] = f.Text
	}
	stamp := at.UTC().Format("2006-01-02T15:04:05Z")
	var order []string
	byKey := map[string]db.SpecReviewMark{}
	for _, t := range twin {
		text, ok := known[t.Key]
		if !ok || (t.State != "ok" && t.State != "comment" && t.State != db.SpecReviewMarkNotUseful) {
			continue
		}
		m := db.SpecReviewMark{AskID: askID, ItemKey: t.Key, State: t.State, Body: t.Body, UpdatedAt: stamp}
		if t.State == "comment" {
			m.About = text
		}
		if _, dup := byKey[t.Key]; !dup {
			order = append(order, t.Key)
		}
		byKey[t.Key] = m // the last mark on a key wins, as a second click does
	}
	marks := make([]db.SpecReviewMark, 0, len(order))
	for _, k := range order {
		marks = append(marks, byKey[k])
	}
	return BuildAnswer(result, byKey, loop, asks.Answer{}, verdict, snapshot), marks
}

// keyed is the comment with the finding it is about (item_key).
func keyed(c asks.Comment, key string) asks.Comment {
	c.ItemKey = key
	return c
}

// BuildAnswer is SpecReviewAnswer.build: base with the marks' comments after
// its own, a non-empty verdict replacing the base's; with a finished loop (a
// non-nil, possibly empty ledger), the loop's comments first, then those of
// marks the ledger never carried. Every comment is placed in the rendered
// snapshot (placeComment) and names its finding, as the Desktop's. The Desktop
// pins it on the shared fixture testdata/answer_marks.json. Findings added
// from a Discuss thread are the Desktop's alone (the hub and the twin have
// none).
func BuildAnswer(result *Result, marks map[string]db.SpecReviewMark, loop []LedgerEntry,
	base asks.Answer, verdict string, markdown string) asks.Answer {
	out := base
	if verdict != "" {
		out.Verdict = verdict
	}
	out.Comments = append([]asks.Comment{}, base.Comments...)
	snapshot := &reviewSnapshot{markdown: markdown}
	if loop == nil {
		out.Comments = append(out.Comments, markComments(result, marks, snapshot)...)
		return out
	}
	inLedger := map[string]bool{}
	for _, e := range loop {
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
			for _, f := range answerFindings(result) {
				if f.key == e.Key {
					chapter = f.chapter
					break
				}
			}
			if a, ok := chapterAnchor(result, chapter, snapshot.markdown); ok {
				anchor = a
			} else {
				anchor = firstHeadingAnchor(snapshot.markdown)
			}
		}
		out.Comments = append(out.Comments, keyed(placeComment(anchor[0], anchor[1], loopBody(e, m.Body), snapshot.rendered()), e.Key))
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

// reviewSnapshot is the ask's doc_snapshot, rendered once and only when a
// comment is placed in it.
type reviewSnapshot struct {
	markdown string
	doc      *plainDoc
}

func (s *reviewSnapshot) rendered() *plainDoc {
	if s.doc == nil {
		// cmark (the Desktop's renderer) reads CRLF and CR as line feeds;
		// goldmark keeps the CR in a fenced code line. Chapter offsets
		// were cut from the original text, only the rendering is normalised.
		d := renderDocument(strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(s.markdown))
		s.doc = &d
	}
	return s.doc
}

// loopBody is SpecReviewAnswer.loopBody.
func loopBody(e LedgerEntry, owner string) string {
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
func markComments(result *Result, marks map[string]db.SpecReviewMark, snapshot *reviewSnapshot) []asks.Comment {
	var out []asks.Comment
	known := map[string]bool{}
	for _, f := range answerFindings(result) {
		known[f.key] = true
		m, ok := marks[f.key]
		if !ok || m.State != "comment" {
			continue
		}
		var anchor [2]string
		if f.anchor != nil {
			anchor = [2]string{f.anchor.Heading, f.anchor.Quote}
		} else if a, ok := chapterAnchor(result, f.chapter, snapshot.markdown); ok {
			anchor = a
		} else {
			anchor = firstHeadingAnchor(snapshot.markdown)
		}
		out = append(out, keyed(placeComment(anchor[0], anchor[1], joinBody(f.text, m.Body), snapshot.rendered()), f.key))
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
	anchor := firstHeadingAnchor(snapshot.markdown)
	for _, k := range orphans {
		m := marks[k]
		about := m.Body
		if m.About != "" {
			about = joinBody(m.About, m.Body)
		}
		out = append(out, keyed(placeComment(anchor[0], anchor[1], "From the previous run: "+about, snapshot.rendered()), k))
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
func chapterAnchor(result *Result, key, snapshot string) ([2]string, bool) {
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

// renderedQuote is SpecReviewAnswer.renderedQuote: quote and list markers
// stripped, then the first line of the rest as rendered.
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
	rendered := strings.TrimSpace(renderPlain(text))
	first, _, _ := strings.Cut(rendered, "\n")
	return strings.TrimSpace(first)
}
