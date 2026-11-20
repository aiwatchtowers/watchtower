package watchman

import (
	"strings"

	"watchtower/internal/secretredact"
)

// Redact replaces every secret in s with "[secret]" (secretredact.Text).
func Redact(s string) string { return secretredact.Text(s) }

// Clip cuts s to at most limit runes, ending in "…" when it was cut.
func Clip(s string, limit int) string {
	if limit <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= limit {
		return s
	}
	return strings.TrimRight(string(r[:limit-1]), " ") + "…"
}

// ItemQuestionLimit caps a work item's question (watchman_items.question).
const ItemQuestionLimit = 2048

// ItemQuestion is the question a work item stores for text: secrets
// redacted, at most ItemQuestionLimit runes.
func ItemQuestion(text string) string {
	return Clip(Redact(strings.TrimSpace(text)), ItemQuestionLimit)
}
