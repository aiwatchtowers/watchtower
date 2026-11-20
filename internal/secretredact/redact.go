// Package secretredact replaces secrets in free text with a mark before the
// text is stored or shown: the watchman's situations and the live line's tool
// summaries both go through Text.
package secretredact

import "regexp"

// Mark replaces every redacted secret.
const Mark = "[secret]"

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

// labelled keep their label (group 1) and replace only the value with repl.
var labelled = []struct {
	re   *regexp.Regexp
	repl string
}{
	// key|token|secret|password=<value>, in env lines, URL queries and --flag=value.
	{regexp.MustCompile(`(?i)(\b[A-Za-z0-9_.-]*(?:key|token|secret|password|passwd)=)[^\s&"'<>]+`), "${1}" + Mark},
	// user:pass@ in a URL; a bare user@ or host:port stays.
	{regexp.MustCompile(`(\b[A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]+:[^\s/@?#]+@`), "${1}" + Mark + "@"},
	// curl -u user:pass / --user user:pass.
	{regexp.MustCompile(`((?:^|\s)(?:-u|--user)\s+)[^\s:]+:\S+`), "${1}" + Mark},
	// --password <value>, --api-token <value>: a space-separated value that is
	// not the next flag.
	{regexp.MustCompile(`(?i)(--[a-z0-9-]*(?:password|passwd|token|secret)\s+)[^\s-]\S*`), "${1}" + Mark},
}

// bearer matches "Bearer <token>"; the token is redacted only when it looks
// like one (16+ chars with a digit or mixed case), so prose such as
// "Bearer authentication" stays.
var bearer = regexp.MustCompile(`(\bBearer\s+)([A-Za-z0-9._~+/=-]{16,})`)

var (
	hasDigit = regexp.MustCompile(`[0-9]`)
	hasLower = regexp.MustCompile(`[a-z]`)
	hasUpper = regexp.MustCompile(`[A-Z]`)
)

func looksLikeToken(t string) bool {
	return hasDigit.MatchString(t) || (hasLower.MatchString(t) && hasUpper.MatchString(t))
}

// Text replaces every secret in s with Mark. Labelled secrets (Bearer
// tokens, key|token|secret|password=<value>, --password <value>, -u
// user:pass, user:pass@ in URLs) keep their label and lose the value.
func Text(s string) string {
	for _, re := range wholeSecrets {
		s = re.ReplaceAllString(s, Mark)
	}
	for _, l := range labelled {
		s = l.re.ReplaceAllString(s, l.repl)
	}
	return bearer.ReplaceAllStringFunc(s, func(m string) string {
		g := bearer.FindStringSubmatch(m)
		if !looksLikeToken(g[2]) {
			return m
		}
		return g[1] + Mark
	})
}
