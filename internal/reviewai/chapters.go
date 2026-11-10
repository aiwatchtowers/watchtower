package reviewai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewmap"
)

// The ledger purposes of the three calls are their prompt ids.
const (
	overviewSource = prompts.ReviewOverview
	chaptersSource = prompts.ReviewChapters
	summarySource  = prompts.ReviewSummary
)

// ErrParse marks a model reply that could not be read (error class
// "parse"); every parse failure wraps it.
var ErrParse = errors.New("the AI answer could not be read")

// ErrSummary marks a failure of the summary part alone of a full call: its
// chapter descriptions came back with it.
var ErrSummary = errors.New("the summary part failed")

// ChapterDesc is the model's description of one map chapter.
type ChapterDesc struct {
	Key   string `json:"key"`
	What  string `json:"what"`
	Risks []Risk `json:"risks"`
}

// DescribeBatch makes one batch call. With full false it is a batch of a
// multi-batch run: prompt review.chapters, descriptions only, intent
// ignored. With full true it is the one full call of a single-batch run:
// prompt review.overview, which also returns the summary of intent; when
// only its summary part is invalid, the descriptions come back with an
// ErrSummary error and no summary. notes are the agent's notes; only line
// notes on the batch's files are sent. No write transaction is open around
// the call.
func (p *Pipeline) DescribeBatch(ctx context.Context, b Batch, full bool, intent []IntentItem, notes []db.ReviewNote) (map[string]ChapterDesc, *Summary, error) {
	if !full {
		raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, chaptersSource), p.getPrompt(prompts.ReviewChapters), BuildChaptersUser(b, notes), "")
		if err != nil {
			return nil, nil, err
		}
		descs, err := ParseChapters(raw, b)
		if err != nil {
			return nil, nil, err
		}
		return descs, nil, nil
	}
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, overviewSource), p.getPrompt(prompts.ReviewOverview), BuildOverviewUser(b, intent, notes), "")
	if err != nil {
		return nil, nil, err
	}
	descs, sum, err := ParseOverview(raw, b, intent)
	if err != nil {
		return descs, nil, err
	}
	return descs, &sum, nil
}

// BuildChaptersUser is the data of a review.chapters call: the agent's
// notes on the batch's files, its chapters and its diff.
func BuildChaptersUser(b Batch, notes []db.ReviewNote) string {
	var s strings.Builder
	s.WriteString("=== DATA ===\n\n")
	writeBatch(&s, b, notes)
	return s.String()
}

// writeBatch writes the AGENT NOTES, CHAPTERS and DIFF blocks of a batch.
func writeBatch(s *strings.Builder, b Batch, notes []db.ReviewNote) {
	s.WriteString("=== AGENT NOTES ===\n")
	writeBatchNotes(s, b, notes)
	s.WriteString("\n=== CHAPTERS ===\n")
	for _, ch := range b.Chapters {
		writeChapterHead(s, ch)
		s.WriteString("\n")
	}
	s.WriteString("=== DIFF ===\n")
	chapterOf := map[string]string{}
	for _, ch := range b.Chapters {
		for _, p := range ch.Paths {
			chapterOf[p] = ch.Key
		}
	}
	for _, f := range b.Files {
		if fileLines(f) == 0 {
			fmt.Fprintf(s, "%s (+%d −%d) — not shown [chapter %s]\n", f.Path, f.Additions, f.Deletions, chapterOf[f.Path])
			if n := b.omitted[f.Path]; n > 0 {
				fmt.Fprintf(s, "(+%d lines not shown)\n", n)
			}
			continue
		}
		fmt.Fprintf(s, "--- %s (%s, +%d −%d) [chapter %s]\n", f.Path, f.Status, f.Additions, f.Deletions, chapterOf[f.Path])
		for _, h := range f.Hunks {
			s.WriteString(h.Header + "\n")
			for _, l := range h.Lines {
				s.WriteString(l + "\n")
			}
		}
		if n := b.omitted[f.Path]; n > 0 {
			fmt.Fprintf(s, "(+%d lines not shown)\n", n)
		}
	}
}

// writeBatchNotes lists the agent's line notes on the batch's files; its
// chapter notes already shaped the chapters.
func writeBatchNotes(s *strings.Builder, b Batch, notes []db.ReviewNote) {
	in := b.paths()
	n := 0
	for _, note := range notes {
		if note.Kind == "chapter" || !in[note.Path] {
			continue
		}
		fmt.Fprintf(s, "%s:%d-%d: %s\n", note.Path, note.StartLine, note.EndLine, oneLine(note.Text))
		n++
	}
	if n == 0 {
		s.WriteString("(none)\n")
	}
}

// writeChapterHead writes a chapter's key, title, level, signals and files.
func writeChapterHead(s *strings.Builder, ch reviewmap.Chapter) {
	fmt.Fprintf(s, "key: %s\ntitle: %s\nlevel: %s\n", ch.Key, oneLine(ch.Title), ch.Level)
	if len(ch.SignalsSummary) > 0 {
		var sig []string
		for _, id := range slices.Sorted(maps.Keys(ch.SignalsSummary)) {
			sig = append(sig, fmt.Sprintf("%s ×%d", id, ch.SignalsSummary[id]))
		}
		fmt.Fprintf(s, "signals: %s\n", strings.Join(sig, ", "))
	}
	fmt.Fprintf(s, "files: %s\n", strings.Join(ch.Paths, ", "))
}

// ParseChapters validates a review.chapters reply against its batch.
func ParseChapters(raw string, b Batch) (map[string]ChapterDesc, error) {
	var r struct {
		Chapters []ChapterDesc `json:"chapters"`
	}
	if err := decodeReply(raw, "chapters", &r); err != nil {
		return nil, err
	}
	return keepChapters(r.Chapters, b)
}

// decodeReply decodes the JSON object of a model reply into v; a failure
// wraps ErrParse and names the reply.
func decodeReply(raw, label string, v any) error {
	js, err := extractObject(raw)
	if err == nil {
		err = json.Unmarshal([]byte(js), v)
	}
	if err != nil {
		return fmt.Errorf("%s reply: %w: %w", label, ErrParse, err)
	}
	return nil
}

// keepChapters keeps, entry by entry, the descriptions of the batch's own
// chapters (the first per key, with a non-empty what) and their risks on
// the chapter's own paths. A reply that names none of the batch's chapters
// fails with ErrParse.
func keepChapters(in []ChapterDesc, b Batch) (map[string]ChapterDesc, error) {
	paths := map[string]map[string]bool{}
	for _, ch := range b.Chapters {
		ps := map[string]bool{}
		for _, p := range ch.Paths {
			ps[p] = true
		}
		paths[ch.Key] = ps
	}
	out := map[string]ChapterDesc{}
	for _, c := range in {
		ps, ok := paths[c.Key]
		if _, dup := out[c.Key]; !ok || dup {
			continue
		}
		what := clipRunes(strings.TrimSpace(c.What), maxWhatRunes)
		if what == "" {
			continue
		}
		out[c.Key] = ChapterDesc{Key: c.Key, What: what, Risks: parseRisk(c.Risks, ps)}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("chapters reply: %w: it names none of the batch's chapters", ErrParse)
	}
	return out, nil
}
