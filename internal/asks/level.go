package asks

import (
	"fmt"
	"unicode/utf8"
)

// The two ask levels (spec 2026-10-10, Part 3): a Quick ask is answered with
// one tap in the banner, a Full ask in the drawer.
const (
	LevelQuick = "quick"
	LevelFull  = "full"
)

// Who filed an ask: the agent through ask_owner, or Watchtower raising the
// agent's unanswered terminal question.
const (
	OriginAgent = "agent"
	OriginChat  = "chat"
)

// The bounds of a Quick ask's one question.
const (
	MaxQuickOptions          = 3
	MaxQuickLabelRunes       = 40
	MaxQuickDescriptionRunes = 100
)

// Level classifies a validated ask: quick iff LevelNote finds no failed rule.
// Title and summary never affect it.
func Level(kind string, p Payload, origin string) string {
	if LevelNote(kind, p, origin) == "" {
		return LevelQuick
	}
	return LevelFull
}

// LevelNote names the first rule that makes the ask Full, in the order of
// spec 3.2, or returns "" for a Quick ask. ask_owner returns it when the
// agent asked for quick and the shape is not.
func LevelNote(kind string, p Payload, origin string) string {
	switch kind {
	case KindQuestion:
	case KindReview:
		return "a review is always a Full ask"
	case KindCheck:
		return "a check is always a Full ask"
	default:
		return fmt.Sprintf("kind %q: a Quick ask is a question", kind)
	}
	if len(p.Questions) != 1 {
		return fmt.Sprintf("%d questions: a Quick ask has one", len(p.Questions))
	}
	q := p.Questions[0]
	if q.Multi {
		return "a multi-choice question: a Quick ask takes one answer"
	}
	n := len(q.Options)
	switch {
	case n == 0 && origin == OriginChat:
	case n < 2 || n > MaxQuickOptions:
		if origin == OriginChat {
			return fmt.Sprintf("%d options: a Quick ask has 0, 2 or 3", n)
		}
		return fmt.Sprintf("%d options: a Quick ask has 2-3", n)
	}
	for _, o := range q.Options {
		if utf8.RuneCountInString(o.Label) > MaxQuickLabelRunes {
			return fmt.Sprintf("option %q: a Quick ask's labels are at most %d characters", o.Label, MaxQuickLabelRunes)
		}
	}
	for _, o := range q.Options {
		if utf8.RuneCountInString(o.Description) > MaxQuickDescriptionRunes {
			return fmt.Sprintf("option %q description: a Quick ask's descriptions are at most %d characters", o.Label, MaxQuickDescriptionRunes)
		}
	}
	if len(p.Focus) > 0 {
		return "focus points: a Quick ask has none"
	}
	if len(p.Checklist) > 0 {
		return "a checklist: a Quick ask has none"
	}
	return ""
}
