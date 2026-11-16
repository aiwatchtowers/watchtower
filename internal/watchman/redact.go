package watchman

import (
	"regexp"
	"strings"
)

const secretMark = "[secret]"

// wholeSecrets match a secret in full; the whole match is replaced.
var wholeSecrets = []*regexp.Regexp{
	regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)`),
	regexp.MustCompile(`xox[abprs]-[A-Za-z0-9-]{8,}`),
	regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}`),
	regexp.MustCompile(`github_pat_[A-Za-z0-9_]{20,}`),
	regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{16,}`),
	regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`),
	regexp.MustCompile(`\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`),
}

// prefixedSecrets keep their label (group 1) and replace only the value.
var prefixedSecrets = []*regexp.Regexp{
	regexp.MustCompile(`(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}`),
	regexp.MustCompile(`(?i)(\b(?:api[_-]?key|key|token|secret|password)=)[^\s&"'<>]+`),
}

// Redact replaces every secret in s with "[secret]". Bearer tokens and
// key|token|secret|password=<value> pairs keep their label and lose the value.
func Redact(s string) string {
	for _, re := range wholeSecrets {
		s = re.ReplaceAllString(s, secretMark)
	}
	for _, re := range prefixedSecrets {
		s = re.ReplaceAllString(s, "${1}"+secretMark)
	}
	return s
}

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
