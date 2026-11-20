// Package secretredact replaces secrets in free text with a mark before the
// text is stored or shown: the watchman's situations and the live line's tool
// summaries both go through Text. It errs towards redacting too much — a
// redacted word costs a summary some meaning, a leaked secret reaches a phone.
package secretredact

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// Mark replaces every redacted secret.
const Mark = "[secret]"

// rule replaces each match of re with what repl returns for its submatches
// (m[0] the whole match, m[1…] the groups; an unmatched group is "").
type rule struct {
	re   *regexp.Regexp
	repl func(m []string) string
}

// Value shapes. A quoted value is taken whole, backslash escapes included
// ("pa\"ss", 'it\'s'), up to its closing quote or the end of the text (a
// summary cut mid-value still loses it).
const (
	quoted = `"(?:[^"\\]|\\[\s\S])*\\?(?:"|$)|'(?:[^'\\]|\\[\s\S])*\\?(?:'|$)`
	// secretName is a name whose value is a secret: FOO_API_KEY, client_secret,
	// db.password, MYSQL_PWD, credentials. A bare "key" (sort-key, monkey) is not.
	secretName = `(?:api[_.-]?key|access[_.-]?key|secret[_.-]?key|private[_.-]?key|auth[_.-]?key|token|secret|password|passwd|pwd|credentials?)`
)

// authSchemes are the Authorization schemes whose next word is the whole
// credential. Any other scheme (Digest's username=, nonce=, response=) loses
// the whole header value.
var authSchemes = regexp.MustCompile(`(?i)^((?:bearer|basic|token|negotiate|ntlm|apikey|key)[ \t]+)(` + quoted + `|[^\s"',;]+)`)

// authHeader is an Authorization header: 1 a quote before the name, 2 the
// name, 3 a quote closing a JSON key, 4 the colon, 5 a quote opening the
// value, 6 the rest of the line. authRepl finds where the value ends.
var authHeader = regexp.MustCompile(`(?i)(["']?)(\b(?:proxy-)?authorization)(["']?)([ \t]*:[ \t]*)(["']?)([^\r\n]*)`)

// authRepl masks an Authorization header's value up to its outer delimiter:
// the value's own quote, else the quote that opened the header (-H "…"),
// else the end of the line. The rest of the line is scanned again.
func authRepl(m []string) string {
	q := m[5]
	if q == "" && m[3] == "" {
		q = m[1]
	}
	value, rest := m[6], ""
	if q != "" {
		if i := unescapedIndex(m[6], q[0]); i >= 0 {
			value, rest = m[6][:i], m[6][i:]
		}
	}
	masked := Mark
	if a := authSchemes.FindStringSubmatchIndex(value); a != nil {
		masked = value[:a[3]] + Mark + value[a[1]:]
	}
	return m[1] + m[2] + m[3] + m[4] + m[5] + masked + replaceAll(authHeader, rest, authRepl)
}

// unescapedIndex is the index of the first q in s not escaped by a
// backslash, or -1.
func unescapedIndex(s string, q byte) int {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case q:
			return i
		}
	}
	return -1
}

// flagWord is the next flag after a --password-style flag: letters and dashes
// only, so "--verbose" stays a flag while "-Xy9" is a value.
var flagWord = regexp.MustCompile(`^--?[A-Za-z][A-Za-z-]*$`)

// shellSyntax starts a word that is never a value: a pipe, redirect or list.
func shellSyntax(v string) bool { return v != "" && strings.ContainsRune("|<>;&", rune(v[0])) }

// numericUserGroup is a uid:gid pair ("docker run -u 1000:1000"), not
// credentials — only after a container run/exec/create.
var numericUserGroup = regexp.MustCompile(`^\d+:\d+$`)

func whole(_ []string) string { return Mark }

// labelled keeps group 1 and replaces group 2 with Mark.
func labelled(m []string) string { return m[1] + Mark }

var rules = []rule{
	// user:pass@ in a URL, first so a password that looks like key=value is
	// taken whole. The password runs to the last "@" before the host; the user
	// may be empty (redis://:pw@host). A bare user@ or host:port stays.
	{regexp.MustCompile(`(\b[A-Za-z][A-Za-z0-9+.-]*://)[^\s/?#@:"'<>]*:[^\s/?#"'<>]*@`),
		func(m []string) string { return m[1] + Mark + "@" }},

	// Vendor token shapes, replaced whole.
	{regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)`), whole},
	{regexp.MustCompile(`xox[abprs]-[A-Za-z0-9-]{8,}`), whole},
	{regexp.MustCompile(`\bxapp-[A-Za-z0-9-]{8,}`), whole},
	{regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}`), whole},
	{regexp.MustCompile(`github_pat_[A-Za-z0-9_]{20,}`), whole},
	{regexp.MustCompile(`\bglpat-[A-Za-z0-9_-]{20,}`), whole},
	{regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{16,}`), whole},
	{regexp.MustCompile(`\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}`), whole},
	{regexp.MustCompile(`\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`), whole},
	{regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}`), whole},
	{regexp.MustCompile(`\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`), whole},

	// Authorization: <scheme> <credential> keeps a one-word scheme and loses
	// the credential; any other value (Digest, unknown schemes) goes whole.
	{authHeader, authRepl},
	// Cookie / Set-Cookie: the whole header value.
	{regexp.MustCompile(`(?i)(\b(?:set-)?cookie["']?[ \t]*:[ \t]*["']?)([^"'\r\n]+)`), labelled},

	// NAME=value: env lines, URL queries, --flag=value.
	{regexp.MustCompile(`(?i)(\b[A-Za-z0-9_.-]*?` + secretName + `=)(` + quoted + `|[^\s&"'<>;|]+)`), labelled},
	// DB_KEY=, SIGNING_KEY=, x.key= and ?key= / &key= in a query. A --flag
	// (--key=path, --sort-key=name) or a word ending in "key" (monkey=) stays:
	// the name must start after a character that is not part of a name.
	{regexp.MustCompile(`(?i)((?:^|[^A-Za-z0-9_.-])([A-Za-z0-9][A-Za-z0-9_.-]*[_.-]key|key)=)(` + quoted + `|[^\s&"'<>;|]+)`),
		func(m []string) string {
			if len(m[2]) == 3 && !strings.ContainsAny(m[1][:1], "?&") {
				return m[0]
			}
			return m[1] + Mark
		}},
	// NAME: value — JSON, YAML, HTTP headers (X-Api-Key, PRIVATE-TOKEN). A
	// value starting with "=" is Go's ":=", not a secret.
	{regexp.MustCompile(`(?i)(\b[A-Za-z0-9_.-]*?` + secretName + `["']?[ \t]*:[ \t]*)(` + quoted + `|[^\s"'=,;{}\[\]][^\s"',;{}]*)`), labelled},

	// -u user:pass, -uuser:pass, --user user:pass, --user=user:pass. A value
	// without a colon (git push -u origin) stays, and so does a uid:gid pair
	// after docker/podman/nerdctl run|exec|create (group 1).
	{regexp.MustCompile(`((?:\b(?:docker|podman|nerdctl)[ \t]+(?:container[ \t]+)?(?:run|exec|create)\b[^\n|;&]*?)?)((?:^|\s)(?:-u[ \t]*|--user(?:[ \t]+|=)))(` + quoted + `|[^\s"']+)`),
		func(m []string) string {
			v := strings.Trim(m[3], `"'`)
			if !strings.Contains(v, ":") || shellSyntax(m[3]) || (m[1] != "" && numericUserGroup.MatchString(v)) {
				return m[0]
			}
			return m[1] + m[2] + Mark
		}},
	// mysql -phunter2: the password attached to -p.
	{regexp.MustCompile(`(\b(?i:mysql|mysqldump|mysqladmin|mariadb)\b[^\n|;&]*?\s-p)(` + quoted + `|[^\s"']+)`), labelled},
	// --password <value>, --api-key <value>: a space-separated value. The next
	// flag (--verbose, -v) or shell syntax (< file, | cmd) is not a value. A
	// "--" word never matches as the value, so in "--password --token X" the
	// --token flag is still there for its own match.
	{regexp.MustCompile(`(?i)(--[A-Za-z0-9-]*?` + secretName + `[ \t]+)(` + quoted + `|(?:[^\s"'-]|-[^\s"'-])[^\s"']*)`),
		func(m []string) string {
			if flagWord.MatchString(m[2]) || shellSyntax(m[2]) {
				return m[0]
			}
			return m[1] + Mark
		}},

	// A bare "Bearer <token>" outside an Authorization header; redacted only
	// when it looks like a token (16+ chars with a digit or mixed case), so
	// prose such as "Bearer authentication" stays.
	{regexp.MustCompile(`(\bBearer\s+)([A-Za-z0-9._~+/=-]{16,})`),
		func(m []string) string {
			if !looksLikeToken(m[2]) {
				return m[0]
			}
			return m[1] + Mark
		}},
}

var (
	hasDigit = regexp.MustCompile(`[0-9]`)
	hasLower = regexp.MustCompile(`[a-z]`)
	hasUpper = regexp.MustCompile(`[A-Z]`)
)

func looksLikeToken(t string) bool {
	return hasDigit.MatchString(t) || (hasLower.MatchString(t) && hasUpper.MatchString(t))
}

// replaceAll replaces each match of re in s with what repl returns for its
// submatches.
func replaceAll(re *regexp.Regexp, s string, repl func(m []string) string) string {
	idx := re.FindAllStringSubmatchIndex(s, -1)
	if idx == nil {
		return s
	}
	var b strings.Builder
	last := 0
	for _, loc := range idx {
		m := make([]string, len(loc)/2)
		for i := range m {
			if loc[2*i] >= 0 {
				m[i] = s[loc[2*i]:loc[2*i+1]]
			}
		}
		b.WriteString(s[last:loc[0]])
		b.WriteString(repl(m))
		last = loc[1]
	}
	b.WriteString(s[last:])
	return b.String()
}

// Text replaces every secret in s with Mark. Labelled secrets (Bearer
// tokens, NAME=value, NAME: value, --password value, -u user:pass, user:pass@
// in URLs) keep their label and lose the value. Its work is linear in len(s);
// a caller that keeps only a short prefix uses TextBounded.
func Text(s string) string {
	for _, r := range rules {
		s = replaceAll(r.re, s, r.repl)
	}
	return s
}

// boundSlack is how far past the kept text TextBounded still reads, so a
// secret straddling the cut is still recognised and redacted.
const boundSlack = 512

// openAuthority is a URL authority running to the end of the text with no
// "@" in it: a cut may have left "scheme://user:pa" without the "@" that
// would have marked it as credentials.
var openAuthority = regexp.MustCompile(`\b[A-Za-z][A-Za-z0-9+.-]*://[^\s/?#@]*$`)

// TextBounded redacts s and keeps at most limit runes of the result. It reads
// at most limit*utf8.UTFMax+boundSlack bytes of s, so its work does not grow
// with s: a multi-megabyte tool argument costs the same as a short one. When
// the text was cut inside a URL authority, everything after its "://" is
// masked.
func TextBounded(s string, limit int) string {
	if limit <= 0 {
		return ""
	}
	cut := false
	if window := limit*utf8.UTFMax + boundSlack; len(s) > window {
		for window > 0 && !utf8.RuneStart(s[window]) {
			window--
		}
		s, cut = s[:window], true
	}
	s = Text(s)
	if utf8.RuneCountInString(s) > limit {
		s, cut = string([]rune(s)[:limit]), true
	}
	if !cut {
		return s
	}
	if loc := openAuthority.FindStringIndex(s); loc != nil {
		s = s[:loc[0]+strings.Index(s[loc[0]:], "://")+3] + Mark
		if utf8.RuneCountInString(s) > limit {
			s = string([]rune(s)[:limit])
		}
	}
	return s
}
