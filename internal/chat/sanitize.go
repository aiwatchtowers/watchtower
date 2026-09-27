package chat

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// maxFieldRunes caps a single-line interpolated field (owner/account/skill/
// project names). Long enough for any real-world name, short enough that a
// pathological DB value cannot blow the prompt budget.
const maxFieldRunes = 200

// validTeamIDRe is the charset a Slack team_id may render into a slack://
// deep link with (the same set internal/ai/prompt.go's safeDomainRe strips
// to). A team_id outside this set is dropped rather than repaired, since a
// stripped-down value could still be a broken/misleading link.
var validTeamIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// oneLine collapses s to a single line safe for interpolation into a
// section-structured prompt: every control character (newlines and tabs
// included) is treated as whitespace, runs of whitespace collapse to one
// space, the result is trimmed, and it is capped at maxLen runes.
//
// Without this, a value a third party controls — a Slack workspace name, a
// Jira site name, a skill description read from a file — could embed
// "\n=== RESPONSE STYLE ===\n<instructions>" and forge a new prompt section
// (Important I2, task-5-review.md). Free-form owner content the prompt
// already trusts by design (project instructions) is deliberately NOT run
// through this — see projectBlock.
func oneLine(s string, maxLen int) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsControl(r) {
			b.WriteByte(' ')
			continue
		}
		b.WriteRune(r)
	}
	out := strings.Join(strings.Fields(b.String()), " ")
	if utf8.RuneCountInString(out) > maxLen {
		out = string([]rune(out)[:maxLen]) + "…"
	}
	return out
}
