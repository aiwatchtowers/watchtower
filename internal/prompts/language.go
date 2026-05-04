package prompts

import (
	"fmt"
	"strings"
)

// DefaultLanguage is the response language used when the workspace has no
// explicit language configured. Mirrors config.DefaultDigestLang —
// duplicated here to keep the prompts package free of a config import
// (prompts is imported by many packages that also depend on config).
const DefaultLanguage = "Russian"

// directiveMarker is the stable phrase that identifies a Directive-produced
// instruction inside a system prompt. Used by HasDirective and tests to
// enforce that every AI prompt carries a language directive.
const directiveMarker = "Respond ONLY in "

// Directive returns a non-empty response-language instruction for an AI
// system prompt. Empty or whitespace-only input falls back to
// DefaultLanguage, so callers always receive a usable directive.
//
// Every pipeline that builds a system prompt MUST call this helper and
// inject the result into its template. Skipping it allows the AI to
// silently default to English regardless of the user's configured language.
func Directive(lang string) string {
	lang = strings.TrimSpace(lang)
	if lang == "" {
		lang = DefaultLanguage
	}
	return fmt.Sprintf(
		"IMPORTANT: Respond ONLY in %s. All text output MUST be in %s, regardless of the language of the input messages.",
		lang, lang,
	)
}

// HasDirective reports whether s already contains a language directive
// produced by Directive. Used by tests and runtime guards to verify that
// a system prompt does not silently omit the language instruction.
func HasDirective(s string) bool {
	return strings.Contains(s, directiveMarker)
}
