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
	// shellWord is an assignment's whole value: unquoted text, "…" and '…'
	// segments and backslash escapes, run together (pre"a b"'c'). It stops at
	// whitespace, & (the next query parameter) and shell syntax.
	shellWord = `(?:"(?:[^"\\]|\\[\s\S])*\\?(?:"|$)|'(?:[^'\\]|\\[\s\S])*\\?(?:'|$)|\\[\s\S]|\\$|[^\s"'&<>;|\\])+`
	// secretName is a name whose value is a secret: FOO_API_KEY, client_secret,
	// db.password, MYSQL_PWD, credentials. A bare "key" (sort-key, monkey) is not.
	secretName = `(?:api[_.-]?key|access[_.-]?key|secret[_.-]?key|private[_.-]?key|auth[_.-]?key|token|secret|password|passwd|pwd|credentials?)`
)

// authSchemes are the Authorization schemes whose next word is the whole
// credential. Any other scheme (Digest's username=, nonce=, response=) loses
// the whole header value.
var authSchemes = regexp.MustCompile(`(?i)^((?:bearer|basic|token|negotiate|ntlm|apikey|key)[ \t]+)(` + quoted + `|[^\s"',;]+)`)

// header is an Authorization or Cookie header up to its value: 1 a quote
// before the name, 2 the name, 3 a quote closing a JSON key, 4 the colon, 5 a
// quote opening the value.
var header = regexp.MustCompile(`(?i)(["']?)(\b(?:proxy-authorization|authorization|set-cookie|cookie))(["']?)([ \t]*:[ \t]*)(["']?)`)

// redactHeaders masks each Authorization and Cookie header value up to its
// outer delimiter: the value's own quote, else the quote that opened the
// header (-H "…"), else the end of the line; escaped quotes do not end it.
// An Authorization value with a one-word scheme (Bearer, Basic) keeps the
// scheme and loses the credential; any other value (Digest, cookies) goes
// whole. One forward pass: each search starts where the last value ended.
func redactHeaders(s string) string {
	var b strings.Builder
	pos := 0
	for pos < len(s) {
		loc := header.FindStringSubmatchIndex(s[pos:])
		if loc == nil {
			break
		}
		group := func(i int) string { return s[pos+loc[2*i] : pos+loc[2*i+1]] }
		q := group(5)
		if q == "" && group(3) == "" {
			q = group(1)
		}
		start := pos + loc[1]
		end := valueEnd(s, start, q)
		masked := Mark
		if value := s[start:end]; !strings.Contains(strings.ToLower(group(2)), "cookie") {
			if a := authSchemes.FindStringSubmatchIndex(value); a != nil {
				masked = value[:a[3]] + Mark + value[a[1]:]
			}
		}
		b.WriteString(s[pos:start])
		b.WriteString(masked)
		pos = end
	}
	if pos == 0 {
		return s
	}
	b.WriteString(s[pos:])
	return b.String()
}

// valueEnd is where a header value starting at start ends: the first
// unescaped q (when q is a quote), else the end of the line or of s.
func valueEnd(s string, start int, q string) int {
	for i := start; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\r' || c == '\n':
			return i
		case c == '\\':
			i++
		case q != "" && c == q[0]:
			return i
		}
	}
	return len(s)
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

// tokenRules run first: credentials in URLs and vendor token shapes.
var tokenRules = []rule{
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
}

// labelRules run after the headers; each keeps a label and loses its value.
var labelRules = []rule{
	// NAME=value: env lines, URL queries, --flag=value.
	{regexp.MustCompile(`(?i)(\b[A-Za-z0-9_.-]*?` + secretName + `=)(` + shellWord + `)`), labelled},
	// DB_KEY=, SIGNING_KEY=, x.key= and ?key= / &key= in a query. A --flag
	// (--key=path, --sort-key=name) or a word ending in "key" (monkey=) stays:
	// the name must start after a character that is not part of a name.
	{regexp.MustCompile(`(?i)((?:^|[^A-Za-z0-9_.-])([A-Za-z0-9][A-Za-z0-9_.-]*[_.-]key|key)=)(` + shellWord + `)`),
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

	// A bare "Bearer <token>" outside an Authorization header: the next word
	// is masked unless it is plain prose (looksLikeToken), so "Bearer
	// authentication" and "Bearer of news" stay.
	{regexp.MustCompile(`(\bBearer[ \t]+)([A-Za-z0-9._~+/=-]+)`),
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

// looksLikeToken: the word after a bare "Bearer" is a credential unless it
// is prose — all lowercase letters (token, authentication), or a short
// all-capitals word (JWT). A digit, a ".", "-", "_" or other token
// punctuation, mixed case, or 8+ capitals marks a credential.
func looksLikeToken(t string) bool {
	switch {
	case hasDigit.MatchString(t) || strings.ContainsAny(t, "._~+/=-"):
		return true
	case hasLower.MatchString(t) && hasUpper.MatchString(t):
		return true
	case hasUpper.MatchString(t):
		return len(t) >= 8
	}
	return false
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
	for _, r := range tokenRules {
		s = replaceAll(r.re, s, r.repl)
	}
	s = redactHeaders(s)
	for _, r := range labelRules {
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

// partialToken is a vendor token prefix running to the end of a cut text
// without the shape its rule needs (a JWT short of its second dot, a ghp_
// short of 20 characters): the cut may have hidden the rest.
var partialToken = regexp.MustCompile(`(?:\beyJ[A-Za-z0-9_.-]*|gh[pousr]_[A-Za-z0-9]*|github_pat_[A-Za-z0-9_]*|xox[abprs]-[A-Za-z0-9-]*|\bxapp-[A-Za-z0-9-]*|\bsk-[A-Za-z0-9_-]*|\b[rs]k_(?:live|test)_[A-Za-z0-9]*|\bglpat-[A-Za-z0-9_-]*|\bAIza[0-9A-Za-z_-]*|\b(?:AKIA|ASIA)[0-9A-Z]*)$`)

// maskCutTail masks what a cut may have left of a secret at the end of s:
// everything after the "://" of an open URL authority, else a vendor token
// prefix.
func maskCutTail(s string) string {
	if loc := openAuthority.FindStringIndex(s); loc != nil {
		return s[:loc[0]+strings.Index(s[loc[0]:], "://")+3] + Mark
	}
	if loc := partialToken.FindStringIndex(s); loc != nil {
		return s[:loc[0]] + Mark
	}
	return s
}

// TextWithin redacts the first maxBytes bytes of s (cut back to a rune
// start) and drops the rest, so its work is bounded by maxBytes. When s was
// cut, a URL authority or a vendor token prefix running into the cut is
// masked to the end (maskCutTail).
func TextWithin(s string, maxBytes int) string {
	if maxBytes <= 0 {
		return ""
	}
	if len(s) <= maxBytes {
		return Text(s)
	}
	for maxBytes > 0 && !utf8.RuneStart(s[maxBytes]) {
		maxBytes--
	}
	return maskCutTail(Text(s[:maxBytes]))
}

// TextBounded redacts s and keeps at most limit runes of the result. It reads
// at most limit*utf8.UTFMax+boundSlack bytes of s (TextWithin), so its work
// does not grow with s: a multi-megabyte tool argument costs the same as a
// short one. When the text was cut inside a URL authority, everything after
// its "://" is masked; a vendor token prefix running into a cut is masked
// whole.
func TextBounded(s string, limit int) string {
	if limit <= 0 {
		return ""
	}
	s = TextWithin(s, limit*utf8.UTFMax+boundSlack)
	if utf8.RuneCountInString(s) > limit {
		s = maskCutTail(string([]rune(s)[:limit]))
		if utf8.RuneCountInString(s) > limit {
			s = string([]rune(s)[:limit])
		}
	}
	return s
}
