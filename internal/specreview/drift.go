package specreview

import "strings"

// The drift guards of an author loop (spec 2026-11-08-spec-review-discuss-
// design §1): Parse drops a new finding that is about text the author did not
// change, a minor one from round 3, and one that was already decided. Each
// drop is counted in Result.Dropped and, by reason, in Result.DroppedBy.

// Drop reasons of the drift guards (Result.DroppedBy keys).
const (
	DropUnchangedText = "on unchanged text"
	DropMinorLate     = "minor finding after round 2"
	DropDecided       = "already decided"
)

// paragraphs splits doc into its blank-line-separated blocks, each
// normalised; a block with no text is left out.
func paragraphs(doc string) []string {
	var out []string
	var cur []string
	flush := func() {
		if p := Normalize(strings.Join(cur, "\n")); p != "" {
			out = append(out, p)
		}
		cur = cur[:0]
	}
	for _, l := range strings.Split(strings.ReplaceAll(doc, "\r\n", "\n"), "\n") {
		if strings.TrimSpace(l) == "" {
			flush()
			continue
		}
		cur = append(cur, l)
	}
	flush()
	return out
}

func paragraphSet(doc string) map[string]bool {
	set := map[string]bool{}
	for _, p := range paragraphs(doc) {
		set[p] = true
	}
	return set
}

// unchangedIn reports, for a quote of doc, whether it lies wholly in text
// that did not change since prevDoc: inside a paragraph of doc that is also a
// whole paragraph of prevDoc, and in no changed paragraph. A quote spanning
// paragraphs, or found only in a changed one, is changed text.
func unchangedIn(prevDoc, doc string) func(quote string) bool {
	prev := paragraphSet(prevDoc)
	cur := paragraphs(doc)
	return func(quote string) bool {
		q := Normalize(quote)
		if q == "" {
			return false
		}
		found := false
		for _, p := range cur {
			if strings.Contains(p, q) {
				if !prev[p] {
					return false
				}
				found = true
			}
		}
		return found
	}
}

// driftGuard is what the guards of one loop round check against; nil when
// the review is not a loop round.
type driftGuard struct {
	// changedText: the changed-text guard runs (round 2+, or round 1 of a
	// loop that follows the owner's answer).
	changedText bool
	// floor: the rising floor runs (round 3+).
	floor     bool
	unchanged func(quote string) bool
	// changedChapter is the chapter keys holding a changed paragraph.
	changedChapter map[string]bool
	closedKey      map[string]bool
	// closedWhere is kind NUL normalised where-quote of every closed item
	// with an anchor: a reworded repeat matches one.
	closedWhere map[string]bool
}

func closedWhereKey(kind, quote string) string { return kind + "\x00" + Normalize(quote) }

// newDriftGuard builds the guard of src's loop round, nil outside a loop.
func newDriftGuard(src Sources, chapters []Chapter) *driftGuard {
	if src.LoopRound < 1 {
		return nil
	}
	g := &driftGuard{
		changedText: src.LoopRound >= 2 || src.PrevDoc != "",
		floor:       src.LoopRound >= 3,
		closedKey:   map[string]bool{},
		closedWhere: map[string]bool{},
	}
	for _, it := range src.Closed {
		g.closedKey[it.Key] = true
		if Normalize(it.WhereQuote) != "" {
			g.closedWhere[closedWhereKey(it.Kind, it.WhereQuote)] = true
		}
	}
	if g.changedText {
		g.unchanged = unchangedIn(src.PrevDoc, src.Doc)
		prev := paragraphSet(src.PrevDoc)
		g.changedChapter = map[string]bool{}
		for _, c := range chapters {
			for _, p := range paragraphs(src.Doc[c.Start:c.End]) {
				if !prev[p] {
					g.changedChapter[c.Key] = true
					break
				}
			}
		}
	}
	return g
}

// drift is the reason a finding is dropped by the drift guards, "" to keep
// it. kind is an AuthorItem kind; where is nil for a finding with no anchor;
// srcRef is the ref of an agreement's source ("" for other kinds); chapter is
// a check's chapter key. An item still open from the previous round, or
// known along the chain and not closed, is carried and passes untouched.
func (v *validator) drift(kind, key, severity string, where *Anchor, srcRef, chapter string) string {
	g := v.guard
	if g == nil || v.src.PrevOpenKeys[key] {
		return ""
	}
	if g.closedKey[key] {
		return DropDecided
	}
	if v.src.KnownKeys[key] {
		return ""
	}
	if where != nil && g.closedWhere[closedWhereKey(kind, where.Quote)] {
		return DropDecided
	}
	if g.changedText && severity != SeverityBlocker {
		var onChanged bool
		switch {
		case kind == KindCheck:
			onChanged = g.changedChapter[chapter]
		case where != nil:
			onChanged = !g.unchanged(where.Quote)
		default:
			// No where-quote: only a source that is new since the
			// previous round is news (a blind spot has none).
			onChanged = srcRef != "" && v.src.NewRefs[srcRef]
		}
		if !onChanged {
			return DropUnchangedText
		}
	}
	if g.floor && severity != SeverityBlocker && severity != SeverityMajor {
		return DropMinorLate
	}
	return ""
}

// dropFor counts an entry dropped by a drift guard.
func (v *validator) dropFor(reason string) {
	v.drop()
	if v.droppedBy == nil {
		v.droppedBy = map[string]int{}
	}
	v.droppedBy[reason]++
}
