package specreview

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/prompts"
)

// Normalize collapses every run of whitespace to one space and trims the ends.
func Normalize(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// contains reports whether needle occurs in hay after both are normalised.
// A needle under minQuoteRunes runes is too weak to anchor anything.
func contains(hay, needle string) bool {
	return containsNorm(Normalize(hay), needle)
}

// containsNorm is contains for a hay that is already normalised.
func containsNorm(normHay, needle string) bool {
	n := Normalize(needle)
	r := utf8.RuneCountInString(n)
	return r >= minQuoteRunes && r <= maxQuoteRunes && strings.Contains(normHay, n)
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

func field(s string) string { return strings.TrimSpace(clip(s, maxFieldRunes)) }

// itemKey is the kind prefix + the first 12 hex digits of
// sha256(normalised text, NUL, normalised anchor quote).
func itemKey(prefix, text, anchorQuote string) string {
	sum := sha256.Sum256([]byte(Normalize(text) + "\x00" + Normalize(anchorQuote)))
	return prefix + hex.EncodeToString(sum[:])[:keyHexDigits]
}

// validator holds what the entries are checked against.
type validator struct {
	src      Sources
	chapters []Chapter
	norm     []string // normalised text of each chapter
	docNorm  string
	root     *os.Root // nil when Folder is unset or unopenable
	dropped  int
}

// normHeading is a heading as compared: leading # and case stripped.
func normHeading(h string) string {
	return strings.ToLower(Normalize(strings.TrimLeft(strings.TrimSpace(h), "# ")))
}

// anchor checks a where-anchor and returns the key of the chapter it lives in.
// The quote must occur in a chapter with the named heading; when no chapter
// has that heading, a quote that occurs in exactly one chapter re-homes there.
func (v *validator) anchor(a Anchor) (key, heading string, ok bool) {
	want := normHeading(a.Heading)
	known := false
	for i, c := range v.chapters {
		if normHeading(c.Heading) != want {
			continue
		}
		known = true
		if containsNorm(v.norm[i], a.Quote) {
			return c.Key, c.Heading, true
		}
	}
	if known {
		return "", "", false
	}
	if n := Normalize(a.Quote); !containsNorm(v.docNorm, n) || strings.Count(v.docNorm, n) != 1 {
		return "", "", false // absent or ambiguous
	}
	hit := -1
	for i := range v.chapters {
		if containsNorm(v.norm[i], a.Quote) {
			if hit >= 0 {
				return "", "", false // more than one place: ambiguous
			}
			hit = i
		}
	}
	if hit < 0 {
		return "", "", false
	}
	return v.chapters[hit].Key, v.chapters[hit].Heading, true
}

// source checks a source: the ref must exist for its kind and the quote must
// occur in the text under it. speaker is who said the quote: the owner only
// when it occurs in one of the owner's own pieces of that ref (OwnerWords);
// the target, the Decisions section and the spec are the author's side.
func (v *validator) source(s Source) (speaker string, ok bool) {
	var text string
	var found bool
	switch s.Kind {
	case "conversation":
		text, found = v.src.Conversation[s.Ref]
	case "ask":
		text, found = v.src.Asks[s.Ref]
	case "comment":
		text, found = v.src.Comments[s.Ref]
	case "target":
		text, found = v.src.Target, v.src.Target != ""
	case "decisions":
		text, found = v.decisionsText()
	case "spec":
		text, found = v.src.Spec, v.src.Spec != ""
	}
	if !found || !contains(text, s.Quote) {
		return "", false
	}
	switch s.Kind {
	case "conversation", "ask", "comment":
		for _, w := range v.src.OwnerWords[s.Ref] {
			if contains(w, s.Quote) {
				return SpeakerOwner, true
			}
		}
	}
	return SpeakerAgent, true
}

// authorSide is a source kind an agreement may cite without the owner's
// words: the document's own Decisions section, the spec a plan implements and
// the board target.
func authorSide(kind string) bool {
	return kind == "decisions" || kind == "spec" || kind == "target"
}

// isDecisionsHeading reports whether a chapter heading (a "## " heading of a
// spec) is the Decisions section: its text starts with the word "Decisions",
// any case, as in "Decisions (owner-approved)". The Desktop's
// SpecReviewDecisions applies the same rule.
func isDecisionsHeading(h string) bool {
	rest, ok := strings.CutPrefix(normHeading(h), "decisions")
	if !ok {
		return false
	}
	r, _ := utf8.DecodeRuneInString(rest)
	return rest == "" || !(unicode.IsLetter(r) || unicode.IsDigit(r))
}

// decisionsText is the text of the Decisions chapter (the first one).
func (v *validator) decisionsText() (string, bool) {
	for i, c := range v.chapters {
		if isDecisionsHeading(c.Heading) {
			return v.norm[i], true
		}
	}
	return "", false
}

// evidenceOK reports whether e names a regular file under the folder.
func (v *validator) evidenceOK(e Evidence) bool {
	if v.root == nil || e.Path == "" || filepath.IsAbs(e.Path) || e.Line < 0 {
		return false
	}
	// Stat, never Open: opening a FIFO would block Parse forever. os.Root
	// refuses ".." and links that leave the folder.
	st, err := v.root.Stat(filepath.Clean(e.Path))
	return err == nil && st.Mode().IsRegular()
}

func (v *validator) chapterKeyFor(ref string) (string, bool) {
	r := strings.TrimSpace(ref)
	for _, c := range v.chapters {
		if c.Key == r || normHeading(c.Heading) == normHeading(r) {
			return c.Key, true
		}
	}
	return "", false
}

// unanchoredChapter is the chapter the reviewer named (key or heading) for a
// finding with no where-quote, kept only when it is one of the document's
// chapters; "" (the Desktop's Other) otherwise.
func (v *validator) unanchoredChapter(ref string) string {
	if strings.TrimSpace(ref) == "" {
		return ""
	}
	key, _ := v.chapterKeyFor(ref)
	return key
}

// Parse validates a reviewer reply against what it may quote. A wrong enum, a
// missing or unfound anchor, an unknown source ref, an unreadable evidence
// path, a duplicate or an entry over the cap drops that entry (counted in
// Dropped); malformed JSON or an empty summary fails the whole call.
func Parse(raw string, src Sources, t DocType) (Result, error) {
	js, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return Result{}, fmt.Errorf("spec review reply: %w", err)
	}
	if head := strings.TrimLeft(strings.TrimPrefix(strings.TrimSpace(raw), "```json"), " \n\r\t`"); strings.HasPrefix(head, "[") {
		return Result{}, errors.New("spec review reply: the reply is an array, not an object")
	}
	var in Result
	if err := json.Unmarshal([]byte(js), &in); err != nil {
		return Result{}, fmt.Errorf("spec review reply: %w", err)
	}
	summary := clip(in.Summary, maxSummaryRunes)
	if summary == "" {
		return Result{}, errors.New("spec review reply: empty summary")
	}

	v := &validator{src: src, chapters: Chapters(src.Doc, t), docNorm: Normalize(src.Doc)}
	for _, c := range v.chapters {
		v.norm = append(v.norm, Normalize(src.Doc[c.Start:c.End]))
	}
	if src.Folder != "" {
		if r, err := os.OpenRoot(src.Folder); err == nil {
			v.root = r
			defer func() { _ = r.Close() }()
		}
	}

	out := Result{
		Summary:      summary,
		Chapters:     v.chapters,
		CodeRead:     in.CodeRead,
		Agreements:   v.agreements(in.Agreements),
		DecidedAlone: v.decidedAlone(in.DecidedAlone),
		BlindSpots:   v.blindSpots(in.BlindSpots),
		Checks:       v.checks(in.Checks),
		Resolved:     v.resolved(in.Resolved),
		Idea:         v.idea(in.Idea),
		Notes:        []string{},
	}
	for _, n := range in.Notes {
		if n = field(n); n != "" && len(out.Notes) < maxNotes {
			out.Notes = append(out.Notes, n)
		}
	}
	out.Dropped = v.dropped
	return out, nil
}

// drop counts a rejected entry.
func (v *validator) drop() { v.dropped++ }

func (v *validator) agreements(in []Agreement) []Agreement {
	out := []Agreement{}
	seen := map[string]bool{}
	for _, a := range in {
		a.Text, a.Note = field(a.Text), field(a.Note)
		speaker, srcOK := v.source(a.Source)
		// An agreement quoting the agent's words in the conversation, an
		// ask or a comment is not something the owner agreed.
		srcOK = srcOK && (speaker == SpeakerOwner || authorSide(a.Source.Kind))
		if a.Text == "" || !(a.Status == "as_agreed" || a.Status == "differs" || a.Status == "missing") ||
			!srcOK || len(out) >= maxAgreements {
			v.drop()
			continue
		}
		a.Source.Speaker = speaker
		anchorQuote := ""
		if a.Where != nil {
			ch, h, ok := v.anchor(*a.Where)
			if !ok {
				v.drop()
				continue
			}
			a.Chapter, a.Where.Heading, anchorQuote = ch, h, a.Where.Quote
		} else {
			a.Chapter = v.unanchoredChapter(a.Chapter)
		}
		a.Key = itemKey("ag:", a.Text, anchorQuote)
		if seen[a.Key] {
			v.drop()
			continue
		}
		seen[a.Key] = true
		out = append(out, a)
	}
	return out
}

func (v *validator) decidedAlone(in []DecidedAlone) []DecidedAlone {
	out := []DecidedAlone{}
	seen := map[string]bool{}
	for _, d := range in {
		d.Text, d.Note = field(d.Text), field(d.Note)
		ch, h, ok := v.anchor(d.Where)
		if d.Text == "" || !ok || len(out) >= maxDecidedAlone {
			v.drop()
			continue
		}
		d.Chapter, d.Where.Heading = ch, h
		d.Key = itemKey("da:", d.Text, d.Where.Quote)
		if seen[d.Key] {
			v.drop()
			continue
		}
		seen[d.Key] = true
		out = append(out, d)
	}
	return out
}

func (v *validator) blindSpots(in []BlindSpot) []BlindSpot {
	out := []BlindSpot{}
	seen := map[string]bool{}
	for _, b := range in {
		b.Text, b.Why = field(b.Text), field(b.Why)
		if b.Text == "" || len(out) >= maxBlindSpots {
			v.drop()
			continue
		}
		anchorQuote, bad := "", false
		b.Chapter = v.unanchoredChapter(b.Chapter)
		if b.Where != nil {
			ch, h, ok := v.anchor(*b.Where)
			bad = !ok
			b.Chapter, b.Where.Heading, anchorQuote = ch, h, b.Where.Quote
		}
		if b.Evidence != nil && !v.evidenceOK(*b.Evidence) {
			bad = true
		}
		b.Key = itemKey("bs:", b.Text, anchorQuote)
		if bad || seen[b.Key] {
			v.drop()
			continue
		}
		seen[b.Key] = true
		out = append(out, b)
	}
	return out
}

func (v *validator) checks(in []Check) []Check {
	out := []Check{}
	seen := map[string]bool{}
	for _, c := range in {
		c.Lens, c.Question, c.Note = field(c.Lens), field(c.Question), field(c.Note)
		key, ok := v.chapterKeyFor(c.Chapter)
		if !ok || c.Lens == "" || c.Question == "" || !(c.Answer == "ok" || c.Answer == "concern" || c.Answer == "n/a") || len(out) >= maxChecks {
			v.drop()
			continue
		}
		c.Chapter = key
		c.Key = itemKey("ck:", c.Lens+"\x00"+c.Question, key)
		if seen[c.Key] {
			v.drop()
			continue
		}
		seen[c.Key] = true
		out = append(out, c)
	}
	return out
}

func (v *validator) resolved(in []Resolved) []Resolved {
	out := []Resolved{}
	for _, r := range in {
		r.Note = field(r.Note)
		known := false
		for _, p := range v.src.PrevComments {
			if contains(p, r.CommentQuote) {
				known = true
				break
			}
		}
		if !known || !(r.Status == "resolved" || r.Status == "open") || len(out) >= maxResolved {
			v.drop()
			continue
		}
		out = append(out, r)
	}
	return out
}

// idea keeps the verdict only when its quotes are real and owner_source is the
// owner's own words; otherwise it is nil (and counted), unless the model gave
// none at all.
func (v *validator) idea(in *Idea) *Idea {
	if in == nil || *in == (Idea{}) {
		return nil
	}
	i := *in
	i.Note = field(i.Note)
	if i.OwnerSource.Quote == "" {
		i.OwnerSource.Quote = i.OwnerQuote
	}
	speaker, srcOK := v.source(i.OwnerSource)
	ok := (i.Verdict == "matches" || i.Verdict == "narrowed" || i.Verdict == "differs") &&
		contains(v.src.Doc, i.GoalQuote) && contains(i.OwnerSource.Quote, i.OwnerQuote) &&
		srcOK && speaker == SpeakerOwner
	if !ok {
		v.drop()
		return nil
	}
	i.OwnerSource.Speaker = speaker
	return &i
}
