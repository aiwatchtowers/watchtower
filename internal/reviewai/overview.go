package reviewai

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
)

// Intent item sources: the session's own items, and one item per lane
// ticket of the branch (tech spec §3.1). Empty reads as session.
const (
	SourceSession = "session"
	SourceLane    = "lane"
)

// IntentItem is one thing the owner asked for: a session context item, or
// a lane's ticket (Source "lane").
type IntentItem struct{ Text, Intent, Task, Source string }

func (it IntentItem) source() string {
	if it.Source == SourceLane {
		return SourceLane
	}
	return SourceSession
}

// Input is the session's side of an overview: the intent items and the
// agent's notes.
type Input struct {
	Intent []IntentItem
	Notes  []db.ReviewNote
}

// Coverage is the model's verdict on one intent item. Index is the item's
// 1-based number in the INTENT block: the Desktop keys the Wrap-up mark to
// that item, never to the model's wording. Source is the item's.
type Coverage struct {
	Index  int      `json:"index"`
	Item   string   `json:"item"`
	Status string   `json:"status"` // done | partial | not_found
	Where  []string `json:"where"`
	Source string   `json:"source"` // session | lane
}

type Risk struct {
	Path  string `json:"path"`
	Level string `json:"level"` // low | medium | high
	Why   string `json:"why"`
}

// Chapter is one map chapter of the assembled overview with its
// description ("" when it has none: collapsed, or listed in Incomplete).
// Level is the map's level name (breaking | significant | normal).
type Chapter struct {
	Key   string   `json:"key"`
	Title string   `json:"title"`
	Level string   `json:"level"`
	Paths []string `json:"paths"`
	Core  bool     `json:"core"`
	What  string   `json:"what"`
}

// Overview is the assembled overview (tech spec §3.4): the summary part,
// the union of the chapters' risks, the map's chapters and the chapters the
// summary could not see (Incomplete, never nil).
type Overview struct {
	Summary    string     `json:"summary"`
	Coverage   []Coverage `json:"coverage"`
	OutOfScope []string   `json:"out_of_scope"`
	Risk       []Risk     `json:"risk"`
	Chapters   []Chapter  `json:"chapters"`
	Incomplete []string   `json:"incomplete"`
}

// IntentHash identifies the intent the overview is cached under: the
// session's items and the agent's notes (a new note re-runs the overview).
// Lane items are left out: they reach the model and the assembled overview,
// but a lane ticket edited at its source never invalidates the overview
// (the finish gate reads it without building the map). The bytes hashed are
// the ones hashed before lane items existed, so cached overviews stay valid.
// Row ids and tree ids stay out; the cache key carries the tree.
func IntentHash(items []IntentItem, notes []db.ReviewNote) string {
	type item struct{ Text, Intent, Task string }
	type note struct {
		Kind               string
		Ord                int
		Path               string
		StartLine, EndLine int
		Quote, Text        string
		Paths              []string
		Core               bool
		Why                string
	}
	var session []item // none stays "null", as before
	for _, it := range items {
		if it.source() == SourceSession {
			session = append(session, item{it.Text, it.Intent, it.Task})
		}
	}
	ns := make([]note, 0, len(notes))
	for _, n := range notes {
		ns = append(ns, note{n.Kind, n.Ord, n.Path, n.StartLine, n.EndLine, n.Quote, n.Text, n.Paths, n.Core, n.Why})
	}
	b, _ := json.Marshal(struct {
		Items []item
		Notes []note
	}{session, ns})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func fileLines(f reviewdiff.File) int {
	n := 0
	for _, h := range f.Hunks {
		n += len(h.Lines)
	}
	return n
}

// BuildOverviewUser is the data of the one full call (review.overview):
// the intent, the batch as review.chapters sees it, then the changed files
// of the chapters left out of the batch, by name.
func BuildOverviewUser(b Batch, intent []IntentItem, notes []db.ReviewNote) string {
	var s strings.Builder
	s.WriteString("=== DATA ===\n\n=== INTENT ===\n")
	writeOverviewIntent(&s, intent)
	s.WriteString("\n")
	writeBatch(&s, b, notes)
	if len(b.others) > 0 {
		s.WriteString("\n=== OTHER CHANGED FILES (not shown) ===\n")
		for _, f := range b.others {
			fmt.Fprintf(&s, "%s (+%d −%d) — not shown\n", f.Path, f.Additions, f.Deletions)
		}
	}
	if b.truncated {
		s.WriteString("(the diff itself was truncated; more files changed than listed)\n")
	}
	return s.String()
}

// writeOverviewIntent lists the intent items, numbered from 1; a lane
// ticket says so.
func writeOverviewIntent(b *strings.Builder, items []IntentItem) {
	if len(items) == 0 {
		b.WriteString("(none given)\n")
	}
	for i, it := range items {
		fmt.Fprintf(b, "%d. %s\n", i+1, oneLine(it.Text))
		if it.Intent != "" {
			fmt.Fprintf(b, "   Intent: %s\n", oneLine(it.Intent))
		}
		if it.Task != "" {
			fmt.Fprintf(b, "   Plan task: %s\n", it.Task)
		}
		if it.source() == SourceLane {
			b.WriteString("   From: the ticket of a lane merged into the branch\n")
		}
	}
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// extractObject is prompts.ExtractJSONObject that refuses an array root (the
// object it would find inside one is not the reply).
func extractObject(raw string) (string, error) {
	js, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return "", err
	}
	head := strings.TrimSpace(raw)
	head = strings.TrimSpace(strings.TrimPrefix(head, "```json"))
	head = strings.TrimSpace(strings.TrimPrefix(head, "```"))
	if strings.HasPrefix(head, "[") {
		return "", errors.New("the reply is an array, not an object")
	}
	return js, nil
}

// ParseOverview validates a review.overview reply against its batch and
// intent: the chapter descriptions as ParseChapters keeps them, the summary
// part as ParseSummary does. A reply that cannot be decoded or names none
// of the batch's chapters fails with ErrParse and no descriptions. A reply
// whose summary part is invalid keeps its chapter descriptions: they come
// back with an error wrapping ErrParse and ErrSummary. NotCovered is always
// empty: the one call sees every chapter.
func ParseOverview(raw string, b Batch, intent []IntentItem) (map[string]ChapterDesc, Summary, error) {
	var r struct {
		Summary
		Chapters []ChapterDesc `json:"chapters"`
	}
	if err := decodeReply(raw, "overview", &r); err != nil {
		return nil, Summary{}, err
	}
	descs, err := keepChapters(r.Chapters, b)
	if err != nil {
		return nil, Summary{}, err
	}
	sum, err := checkSummary("overview", r.Summary, intent, b.changedPaths())
	if err != nil {
		return descs, Summary{}, fmt.Errorf("%w: %w", ErrSummary, err)
	}
	sum.NotCovered = []string{}
	return descs, sum, nil
}

// keepKnown keeps the entries of ss that ok knows, in order (never nil).
func keepKnown(ss []string, ok map[string]bool) []string {
	out := []string{}
	for _, s := range ss {
		if ok[s] {
			out = append(out, s)
		}
	}
	return out
}

// parseCoverage keeps the coverage entries with an item, a known status and
// an index among the given intent items not already covered, up to
// maxCoverage; each carries its item's source.
func parseCoverage(in []Coverage, intent []IntentItem, paths map[string]bool) []Coverage {
	cov := []Coverage{}
	seenIndex := map[int]bool{}
	for _, c := range in {
		item := clipRunes(strings.TrimSpace(c.Item), maxOverviewFields)
		if item == "" || (c.Status != "done" && c.Status != "partial" && c.Status != "not_found") || len(cov) >= maxCoverage {
			continue
		}
		if c.Index < 1 || c.Index > len(intent) || seenIndex[c.Index] {
			continue // not one of the given items, or one already covered
		}
		seenIndex[c.Index] = true
		cov = append(cov, Coverage{Index: c.Index, Item: item, Status: c.Status, Where: keepKnown(c.Where, paths),
			Source: intent[c.Index-1].source()})
	}
	return cov
}

// parseRisk keeps the risk entries on a known path with a known level, up to
// maxRisk.
func parseRisk(in []Risk, paths map[string]bool) []Risk {
	risk := []Risk{}
	for _, r := range in {
		if !paths[r.Path] || (r.Level != "low" && r.Level != "medium" && r.Level != "high") || len(risk) >= maxRisk {
			continue
		}
		risk = append(risk, Risk{Path: r.Path, Level: r.Level, Why: clipRunes(strings.TrimSpace(r.Why), maxOverviewFields)})
	}
	return risk
}
