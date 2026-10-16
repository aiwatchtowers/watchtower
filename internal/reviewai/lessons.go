package reviewai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
)

const (
	lessonsSource    = "workbench.review_lessons"
	houseRulesLens   = "house_rules"
	maxLessons       = 20
	maxLessonRunes   = 300
	maxLessonQuote   = 400
	minLessonSources = 2
)

// Lesson is one proposed house rule and the comments it was distilled from.
type Lesson struct {
	Lens             string  `json:"lens"`
	Text             string  `json:"text"`
	SourceCommentIDs []int64 `json:"source_comment_ids"`
}

// BuildLessonsUser is the data part of the call: the lens ids and every
// comment as "#<id> [<lens>] <path or design>: <body>" with its quote.
func BuildLessonsUser(comments []db.ReviewComment, lenses []reviewdiff.Lens) string {
	var b strings.Builder
	b.WriteString("=== DATA ===\n\n=== LENS IDS ===\n")
	for i, l := range lenses {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(l.ID)
	}
	b.WriteString("\n\n=== COMMENTS ===\n")
	for _, c := range comments {
		where := "design"
		if c.Path.Valid && c.Path.String != "" {
			where = c.Path.String
		}
		fmt.Fprintf(&b, "#%d [%s] %s: %s\n", c.ID, c.Lens, where, oneLine(c.Body))
		if q := oneLine(c.Quote); q != "" {
			fmt.Fprintf(&b, "  quote: %s\n", clipRunes(q, maxLessonQuote))
		}
	}
	return b.String()
}

// cleanLesson: one line, a leading "#" run or "- " stripped.
func cleanLesson(s string) string {
	s = oneLine(s)
	for {
		t := strings.TrimSpace(strings.TrimLeft(s, "#"))
		t = strings.TrimSpace(strings.TrimPrefix(t, "- "))
		if t == s {
			return s
		}
		s = t
	}
}

// ParseLessons validates a reply: a lesson needs at least two distinct source
// ids, all among the input; an unknown lens becomes house_rules; the text is
// one line of 1-300 runes; at most 20 lessons.
func ParseLessons(raw string, inputIDs map[int64]bool, lensIDs []string) ([]Lesson, error) {
	js, err := extractObject(raw)
	if err != nil {
		return nil, fmt.Errorf("lessons reply: %w", err)
	}
	var reply struct {
		Lessons []Lesson `json:"lessons"`
	}
	if err := json.Unmarshal([]byte(js), &reply); err != nil {
		return nil, fmt.Errorf("lessons reply: %w", err)
	}
	lensOK := map[string]bool{}
	for _, id := range lensIDs {
		lensOK[id] = true
	}
	out := []Lesson{}
	for _, l := range reply.Lessons {
		if len(out) >= maxLessons {
			break
		}
		text := cleanLesson(l.Text)
		if n := utf8.RuneCountInString(text); n < 1 || n > maxLessonRunes {
			continue
		}
		seen := map[int64]bool{}
		ids := []int64{}
		known := true
		for _, id := range l.SourceCommentIDs {
			if !inputIDs[id] {
				known = false
				break
			}
			if !seen[id] {
				seen[id] = true
				ids = append(ids, id)
			}
		}
		if !known || len(ids) < minLessonSources {
			continue
		}
		lens := l.Lens
		if !lensOK[lens] {
			lens = houseRulesLens
		}
		out = append(out, Lesson{Lens: lens, Text: text, SourceCommentIDs: ids})
	}
	return out, nil
}

// Lessons runs the strong-tier call over the owner's comments. Callers skip
// it for fewer than two comments.
func (p *Pipeline) Lessons(ctx context.Context, comments []db.ReviewComment, lenses []reviewdiff.Lens) ([]Lesson, error) {
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, lessonsSource), p.getPrompt(prompts.ReviewLessons), BuildLessonsUser(comments, lenses), "")
	if err != nil {
		return nil, err
	}
	ids := make(map[int64]bool, len(comments))
	for _, c := range comments {
		ids[c.ID] = true
	}
	lensIDs := make([]string, 0, len(lenses))
	for _, l := range lenses {
		lensIDs = append(lensIDs, l.ID)
	}
	return ParseLessons(raw, ids, lensIDs)
}
