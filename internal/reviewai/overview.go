package reviewai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
)

const overviewSource = "workbench.review_overview"

// IntentItem is one thing the owner asked the session for.
type IntentItem struct{ Text, Intent, Task string }

// Input is everything the overview call sees.
type Input struct {
	Intent  []IntentItem
	Notes   []db.ReviewNote
	Diff    reviewdiff.Diff
	LensIDs []string
}

type Coverage struct {
	Item   string   `json:"item"`
	Status string   `json:"status"` // done | partial | not_found
	Where  []string `json:"where"`
}

type Risk struct {
	Path  string `json:"path"`
	Level string `json:"level"` // low | medium | high
	Why   string `json:"why"`
}

type Chapter struct {
	Title  string   `json:"title"`
	Paths  []string `json:"paths"`
	Core   bool     `json:"core"`
	Lenses []string `json:"lenses"`
}

type Overview struct {
	Summary    string     `json:"summary"`
	Coverage   []Coverage `json:"coverage"`
	OutOfScope []string   `json:"out_of_scope"`
	Risk       []Risk     `json:"risk"`
	Chapters   []Chapter  `json:"chapters"`
}

// IntentHash identifies the intent the overview was made for: the context
// items plus the agent's notes (a new note re-runs the overview). Row ids and
// tree ids stay out; the cache key carries the tree.
func IntentHash(items []IntentItem, notes []db.ReviewNote) string {
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
	ns := make([]note, 0, len(notes))
	for _, n := range notes {
		ns = append(ns, note{n.Kind, n.Ord, n.Path, n.StartLine, n.EndLine, n.Quote, n.Text, n.Paths, n.Core, n.Why})
	}
	b, _ := json.Marshal(struct {
		Items []IntentItem
		Notes []note
	}{items, ns})
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

// BuildOverviewUser is the data part of the call: intent, the agent's notes,
// the lens ids and the diff, capped by limits.go. A file past a cap, binary
// or collapsed is listed as "<path> (+a −d) — not shown".
func BuildOverviewUser(in Input) string {
	var b strings.Builder
	b.WriteString("=== DATA ===\n\n=== INTENT ===\n")
	if len(in.Intent) == 0 {
		b.WriteString("(none given)\n")
	}
	for i, it := range in.Intent {
		fmt.Fprintf(&b, "%d. %s\n", i+1, oneLine(it.Text))
		if it.Intent != "" {
			fmt.Fprintf(&b, "   Intent: %s\n", oneLine(it.Intent))
		}
		if it.Task != "" {
			fmt.Fprintf(&b, "   Plan task: %s\n", it.Task)
		}
	}
	b.WriteString("\n=== AGENT NOTES ===\n")
	if len(in.Notes) == 0 {
		b.WriteString("(none)\n")
	}
	for _, n := range in.Notes {
		switch n.Kind {
		case "chapter":
			fmt.Fprintf(&b, "chapter %q: %s\n", n.Text, strings.Join(n.Paths, ", "))
		default:
			fmt.Fprintf(&b, "%s:%d-%d: %s\n", n.Path, n.StartLine, n.EndLine, oneLine(n.Text))
		}
	}
	b.WriteString("\n=== LENS IDS ===\n" + strings.Join(in.LensIDs, ", ") + "\n\n=== DIFF ===\n")
	shown := 0
	capped := false
	for _, f := range in.Diff.Files {
		n := fileLines(f)
		if capped || f.Binary || f.CollapsedReason != "" || n > MaxOverviewFileLines || shown+n > MaxOverviewLines {
			if !f.Binary && f.CollapsedReason == "" && n <= MaxOverviewFileLines {
				capped = true // the overall cap is spent: every later file is only listed
			}
			fmt.Fprintf(&b, "%s (+%d −%d) — not shown\n", f.Path, f.Additions, f.Deletions)
			continue
		}
		shown += n
		fmt.Fprintf(&b, "--- %s (%s, +%d −%d)\n", f.Path, f.Status, f.Additions, f.Deletions)
		for _, h := range f.Hunks {
			b.WriteString(h.Header + "\n")
			for _, l := range h.Lines {
				b.WriteString(l + "\n")
			}
		}
	}
	if in.Diff.Truncated {
		b.WriteString("(the diff itself was truncated; more files changed than listed)\n")
	}
	return b.String()
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

// ParseOverview validates a model reply against the input: unknown paths,
// lens ids and enum values are dropped entry by entry; malformed JSON or an
// empty summary fails the whole call.
func ParseOverview(raw string, in Input) (Overview, error) {
	js, err := extractObject(raw)
	if err != nil {
		return Overview{}, fmt.Errorf("overview reply: %w", err)
	}
	var o Overview
	if err := json.Unmarshal([]byte(js), &o); err != nil {
		return Overview{}, fmt.Errorf("overview reply: %w", err)
	}
	o.Summary = clipRunes(strings.TrimSpace(o.Summary), maxSummaryRunes)
	if o.Summary == "" {
		return Overview{}, errors.New("overview reply: empty summary")
	}
	paths := map[string]bool{}
	for _, f := range in.Diff.Files {
		paths[f.Path] = true
	}
	lensOK := map[string]bool{}
	for _, id := range in.LensIDs {
		lensOK[id] = true
	}
	keep := func(ss []string, ok map[string]bool) []string {
		out := []string{}
		for _, s := range ss {
			if ok[s] {
				out = append(out, s)
			}
		}
		return out
	}

	cov := []Coverage{}
	for _, c := range o.Coverage {
		item := clipRunes(strings.TrimSpace(c.Item), maxOverviewFields)
		if item == "" || (c.Status != "done" && c.Status != "partial" && c.Status != "not_found") || len(cov) >= maxCoverage {
			continue
		}
		cov = append(cov, Coverage{Item: item, Status: c.Status, Where: keep(c.Where, paths)})
	}
	o.Coverage = cov
	o.OutOfScope = keep(o.OutOfScope, paths)
	risk := []Risk{}
	for _, r := range o.Risk {
		if !paths[r.Path] || (r.Level != "low" && r.Level != "medium" && r.Level != "high") || len(risk) >= maxRisk {
			continue
		}
		risk = append(risk, Risk{Path: r.Path, Level: r.Level, Why: clipRunes(strings.TrimSpace(r.Why), maxOverviewFields)})
	}
	o.Risk = risk
	chs := []Chapter{}
	for _, c := range o.Chapters {
		ps := keep(c.Paths, paths)
		if len(ps) == 0 || len(chs) >= maxChapters {
			continue
		}
		title := clipRunes(strings.TrimSpace(c.Title), maxOverviewFields)
		if title == "" {
			title = ps[0]
		}
		chs = append(chs, Chapter{Title: title, Paths: ps, Core: c.Core, Lenses: keep(c.Lenses, lensOK)})
	}
	o.Chapters = chs
	return o, nil
}

// Overview runs the strong-tier call and validates the reply. Nothing is
// cached here and no write transaction is open around the call.
func (p *Pipeline) Overview(ctx context.Context, in Input) (Overview, error) {
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, overviewSource), p.getPrompt(prompts.ReviewOverview), BuildOverviewUser(in), "")
	if err != nil {
		return Overview{}, err
	}
	return ParseOverview(raw, in)
}
