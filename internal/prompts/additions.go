package prompts

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// MaxAdditionRunes caps the sum of one prompt's additions, in runes.
const MaxAdditionRunes = 600

// maxAdditionLineRunes caps a single addition.
const maxAdditionLineRunes = 300

// ValidateAddition checks one owner-approved prompt addition: non-empty after
// trimming, one line, at most 300 runes, and no template syntax — templates
// are formatted with fmt verbs, so a `%` or a `{{`/`}}` pair would break or
// hijack the rendering of the prompt it is appended to.
func ValidateAddition(text string) error {
	t := strings.TrimSpace(text)
	switch {
	case t == "":
		return errors.New("addition is empty")
	case strings.ContainsAny(t, "\r\n"):
		return errors.New("addition must be one line")
	case utf8.RuneCountInString(t) > maxAdditionLineRunes:
		return errors.New("addition is longer than 300 characters")
	case strings.Contains(t, "%"):
		return errors.New("addition must not contain %")
	case strings.Contains(t, "{{") || strings.Contains(t, "}}"):
		return errors.New("addition must not contain template braces")
	}
	return nil
}

// WithAdditions appends the owner's approved additions to a template as one
// block. No additions leaves the template byte-identical.
func WithAdditions(tmpl string, adds []string) string {
	if len(adds) == 0 {
		return tmpl
	}
	var b strings.Builder
	b.WriteString(tmpl)
	b.WriteString("\n\n=== OWNER PREFERENCES (approved by the owner) ===\n")
	for _, a := range adds {
		b.WriteString("- " + a + "\n")
	}
	return b.String()
}

// additionsFor reads the additions of a base prompt id. A failed read is
// logged and yields none: a prompt never fails over its additions.
func (s *Store) additionsFor(id string) []string {
	rows, err := s.db.ListPromptAdditions(id)
	if err != nil {
		s.logger.Warn("reading prompt additions", "id", id, "err", err)
		return nil
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.Text)
	}
	return out
}
