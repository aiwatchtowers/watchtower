package reviewai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
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

// Input is everything the overview sees.
type Input struct {
	Intent []IntentItem
	Notes  []db.ReviewNote
	Diff   reviewdiff.Diff
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

type Chapter struct {
	Title string   `json:"title"`
	Paths []string `json:"paths"`
	Core  bool     `json:"core"`
}

type Overview struct {
	Summary    string     `json:"summary"`
	Coverage   []Coverage `json:"coverage"`
	OutOfScope []string   `json:"out_of_scope"`
	Risk       []Risk     `json:"risk"`
	Chapters   []Chapter  `json:"chapters"`
}

// IntentHash identifies the intent the overview was made for: the session's
// items, the lane items and the agent's notes (a new note re-runs the
// overview). Row ids and tree ids stay out; the cache key carries the tree.
// With no lane items the bytes hashed are the same as before lane items
// existed, so overviews cached for session-only intent stay valid.
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
	var session, lanes []item
	if items != nil { // nil stays "null", as before: cached hashes still match
		session = make([]item, 0, len(items))
	}
	for _, it := range items {
		if it.source() == SourceLane {
			lanes = append(lanes, item{it.Text, it.Intent, it.Task})
		} else {
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
		Lanes []item `json:",omitempty"`
	}{session, ns, lanes})
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
// part as ParseSummary does. A reply without a summary or naming none of
// the batch's chapters fails with ErrParse. NotCovered is always empty:
// the one call sees every chapter.
func ParseOverview(raw string, b Batch, intent []IntentItem) (map[string]ChapterDesc, Summary, error) {
	var r struct {
		Summary
		Chapters []ChapterDesc `json:"chapters"`
	}
	if err := decodeReply(raw, "overview", &r); err != nil {
		return nil, Summary{}, err
	}
	sum, err := checkSummary("overview", r.Summary, intent, b.changedPaths())
	if err != nil {
		return nil, Summary{}, err
	}
	sum.NotCovered = []string{}
	descs, err := keepChapters(r.Chapters, b)
	if err != nil {
		return nil, Summary{}, err
	}
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

// Overview describes the whole diff in one go: the map's chapters packed
// into batches (one batch = the one full call; more = a call per batch, in
// turn, then the summary), assembled into the overview. Any failed call
// fails it. This is the pre-stream path; the run orchestrator replaces it.
func (p *Pipeline) Overview(ctx context.Context, in Input) (Overview, error) {
	m := reviewmap.Build(reviewmap.Input{Diff: in.Diff, AgentChapters: in.Notes})
	batches := Pack(m, in.Diff, nil)
	if len(batches) == 0 {
		return Overview{}, errors.New("no chapter has a diff the AI can read")
	}
	descs := NotShown(m, in.Diff)
	var sum Summary
	if len(batches) == 1 {
		d, s, err := p.DescribeBatch(ctx, batches[0], true, in.Intent, in.Notes)
		if err != nil {
			return Overview{}, err
		}
		maps.Copy(descs, d)
		sum = *s
	} else {
		for _, b := range batches {
			d, _, err := p.DescribeBatch(ctx, b, false, nil, in.Notes)
			if err != nil {
				return Overview{}, err
			}
			maps.Copy(descs, d)
		}
		var err error
		if sum, err = p.Summarize(ctx, SummaryInput{Intent: in.Intent, Map: m, Described: descs}); err != nil {
			return Overview{}, err
		}
	}
	o := Overview{Summary: sum.Summary, Coverage: sum.Coverage, OutOfScope: sum.OutOfScope, Risk: []Risk{}, Chapters: []Chapter{}}
	for _, ch := range m.Chapters {
		o.Chapters = append(o.Chapters, Chapter{Title: ch.Title, Paths: ch.Paths, Core: ch.Core})
		o.Risk = append(o.Risk, descs[ch.Key].Risks...)
	}
	return o, nil
}
