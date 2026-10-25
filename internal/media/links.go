// Package media turns images and web links into knowledge. This file holds the
// link rules: which URLs are extracted from text, how they are normalized, and
// which ones Watchtower must never fetch.
package media

import (
	"net"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"golang.org/x/net/idna"
)

// SecretPathSegments are path words that mark a capability URL (one whose
// possession is the credential).
var SecretPathSegments = []string{
	"invite", "reset", "verify", "confirm", "unsubscribe", "magic",
	"login", "signin", "activate", "approve", "oauth", "callback",
}

// SecretParams are query/fragment keys (case-insensitive) that mark a URL as
// carrying a credential. Keys with prefix x-amz- or x-goog- and the CloudFront
// pair Expires + Key-Pair-Id are handled in code.
var SecretParams = []string{
	"token", "access_token", "id_token", "refresh_token", "auth", "authorization",
	"code", "key", "api_key", "apikey", "secret", "client_secret", "sig", "signature",
	"session", "sessionid", "sid", "password", "pwd", "otp", "ticket", "jwt", "hash", "credential",
}

// SyncedHosts are hosts of sources Watchtower already syncs through their own
// connectors; their links are never fetched anonymously. Subdomains match too.
var SyncedHosts = []string{
	"slack.com", "slack-edge.com", "slack-files.com", "atlassian.net", "linear.app",
	"mail.google.com", "docs.google.com", "drive.google.com", "calendar.google.com",
}

var (
	secretParamSet   = toSet(stripSeps(SecretParams))
	secretSegmentSet = toSet(SecretPathSegments)
	slackAngleRe     = regexp.MustCompile(`<([^<>]+)>`)
	textLinkRe       = regexp.MustCompile(`(?i)https?://[^\s<>]+`)
)

// stripSeps lowercases each word and removes its -/_/. separators.
func stripSeps(l []string) []string {
	out := make([]string, len(l))
	for i, s := range l {
		out[i] = strings.ToLower(strings.Join(splitWords(s), ""))
	}
	return out
}

func toSet(l []string) map[string]bool {
	m := make(map[string]bool, len(l))
	for _, s := range l {
		m[s] = true
	}
	return m
}

func isHTTP(s string) bool {
	l := strings.ToLower(s)
	return strings.HasPrefix(l, "http://") || strings.HasPrefix(l, "https://")
}

// SlackLinks returns the http(s) URLs of Slack mrkdwn `<url>` / `<url|label>`
// tokens. Mentions, channel and special references and mailto: are skipped.
func SlackLinks(text string) []string {
	var out []string
	for _, m := range slackAngleRe.FindAllStringSubmatch(text, -1) {
		u := m[1]
		if i := strings.IndexByte(u, '|'); i >= 0 {
			u = u[:i]
		}
		if !isHTTP(u) {
			continue
		}
		u = strings.NewReplacer("&amp;", "&", "&lt;", "<", "&gt;", ">").Replace(u)
		out = append(out, u)
	}
	return out
}

// TextLinks returns bare http(s) URLs of plain text, with trailing
// punctuation trimmed (a closing parenthesis stays when balanced).
func TextLinks(text string) []string {
	var out []string
	for _, m := range textLinkRe.FindAllString(text, -1) {
		for m != "" {
			last := m[len(m)-1]
			if strings.IndexByte(".,;:!?]}>'\"", last) >= 0 {
				m = m[:len(m)-1]
				continue
			}
			if last == ')' && strings.Count(m, "(") < strings.Count(m, ")") {
				m = m[:len(m)-1]
				continue
			}
			break
		}
		if i := strings.Index(m, "://"); isHTTP(m) && len(m) > i+3 {
			out = append(out, m)
		}
	}
	return out
}

// asciiHost lowercases and IDNA-converts a host (ideographic full stops count
// as dots), drops every trailing dot, and refuses an empty host or label.
func asciiHost(h string) (string, bool) {
	a, err := idna.Lookup.ToASCII(strings.ToLower(h))
	if err != nil {
		return "", false
	}
	a = strings.TrimRight(strings.ToLower(a), ".")
	if a == "" {
		return "", false
	}
	for _, l := range strings.Split(a, ".") {
		if l == "" {
			return "", false
		}
	}
	return a, true
}

// NormalizeHostSet builds the refusedHosts set Fetchable expects: lowercase,
// IDNA ASCII, no trailing dot. Hosts that do not normalize are dropped.
func NormalizeHostSet(hosts []string) map[string]bool {
	m := make(map[string]bool, len(hosts))
	for _, h := range hosts {
		if n, ok := asciiHost(strings.TrimSpace(h)); ok {
			m[n] = true
		}
	}
	return m
}

func isTrackingKey(k string) bool {
	k = strings.ToLower(k)
	return strings.HasPrefix(k, "utm_") || k == "fbclid" || k == "gclid" || k == "mc_cid" || k == "mc_eid"
}

// NormalizeURL canonicalizes an http(s) URL: lowercase scheme and host, IDNA
// ASCII host, default port and fragment dropped, tracking parameters dropped,
// remaining query pairs sorted, empty path becomes "/". IP-literal hosts are
// normalized like any other (Fetchable refuses them). It reports false for unparseable input.
func NormalizeURL(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", false
	}
	host, ok := asciiHost(u.Hostname())
	if !ok {
		return "", false
	}
	port := u.Port()
	if (scheme == "http" && port == "80") || (scheme == "https" && port == "443") {
		port = ""
	}
	hostport := host
	if strings.Contains(host, ":") {
		hostport = "[" + host + "]"
	}
	if port != "" {
		hostport += ":" + port
	}
	var pairs []string
	if u.RawQuery != "" {
		for _, p := range strings.Split(u.RawQuery, "&") {
			if p == "" {
				continue
			}
			k := p
			if i := strings.IndexByte(p, '='); i >= 0 {
				k = p[:i]
			}
			if dk, err := url.QueryUnescape(k); err == nil {
				k = dk
			}
			if isTrackingKey(k) {
				continue
			}
			pairs = append(pairs, p)
		}
		sort.Strings(pairs)
	}
	var b strings.Builder
	b.WriteString(scheme + "://" + hostport)
	if p := u.EscapedPath(); p != "" {
		b.WriteString(p)
	} else {
		b.WriteString("/")
	}
	if len(pairs) > 0 {
		b.WriteString("?" + strings.Join(pairs, "&"))
	}
	return b.String(), true
}

// decodeStable percent-decodes s until it stops changing (at most 3 rounds),
// so double-encoded words are seen as the fetcher's server would see them.
func decodeStable(s string, dec func(string) (string, error)) string {
	for i := 0; i < 3; i++ {
		d, err := dec(s)
		if err != nil || d == s {
			return s
		}
		s = d
	}
	return s
}

// paramKeys lists the lowercased, decoded keys of a k=v string separated by
// "&" or ";", with a trailing array suffix ("[]", "[0]") removed.
func paramKeys(s string) []string {
	var keys []string
	for _, p := range strings.FieldsFunc(s, func(r rune) bool { return r == '&' || r == ';' }) {
		if i := strings.IndexByte(p, '='); i >= 0 {
			p = p[:i]
		}
		p = decodeStable(p, url.QueryUnescape)
		// "a[b][c]" yields the outer key and every inner name.
		for _, part := range strings.FieldsFunc(p, func(r rune) bool { return r == '[' || r == ']' }) {
			if part != "" {
				keys = append(keys, part)
			}
		}
	}
	return keys
}

// splitWords splits at -/_/. and at camelCase and letter/digit boundaries
// ("accessToken" -> access, Token), keeping the original case.
func splitWords(s string) []string {
	var words []string
	var cur []rune
	var prev rune
	rs := []rune(s)
	flush := func() {
		if len(cur) > 0 {
			words = append(words, string(cur))
			cur = cur[:0]
		}
	}
	for i, r := range rs {
		if r == '-' || r == '_' || r == '.' {
			flush()
			prev = 0
			continue
		}
		if prev != 0 && ((unicode.IsLower(prev) && unicode.IsUpper(r)) ||
			(unicode.IsDigit(prev) != unicode.IsDigit(r)) ||
			// "CSRFToken": split before the last capital of a run.
			(unicode.IsUpper(prev) && unicode.IsUpper(r) && i+1 < len(rs) && unicode.IsLower(rs[i+1]))) {
			flush()
		}
		cur = append(cur, r)
		prev = r
	}
	flush()
	return words
}

// wordsSecret reports whether any word of s, or the words joined, is in set
// (whose entries have their separators removed).
func wordsSecret(s string, set map[string]bool) bool {
	words := splitWords(s)
	for i := range words {
		words[i] = strings.ToLower(words[i])
		if set[words[i]] {
			return true
		}
	}
	return set[strings.Join(words, "")]
}

func keySecret(k string) bool {
	l := strings.ToLower(k)
	return strings.HasPrefix(l, "x-amz-") || strings.HasPrefix(l, "x-goog-") || wordsSecret(k, secretParamSet)
}

func hasSecretParam(u *url.URL) bool {
	keys := paramKeys(u.RawQuery)
	frag := u.EscapedFragment()
	route, qs := frag, ""
	if i := strings.IndexByte(frag, '?'); i >= 0 {
		route, qs = frag[:i], frag[i+1:]
	}
	keys = append(keys, paramKeys(qs)...)
	keys = append(keys, paramKeys(route)...)
	var expires, keyPair bool
	for _, k := range keys {
		switch {
		case keySecret(k):
			return true
		case strings.EqualFold(k, "expires"):
			expires = true
		case strings.EqualFold(k, "key-pair-id"):
			keyPair = true
		}
	}
	return expires && keyPair
}

func segmentIsSecret(seg string) bool {
	head, tail, hasParams := strings.Cut(seg, ";")
	if wordsSecret(head, secretSegmentSet) {
		return true
	}
	if hasParams {
		for _, k := range paramKeys(tail) {
			if keySecret(k) {
				return true
			}
		}
	}
	return false
}

// pathSecret checks every segment of an escaped path (or fragment route).
func pathSecret(escaped string) bool {
	for _, raw := range strings.Split(escaped, "/") {
		seg := decodeStable(raw, url.PathUnescape)
		// An encoded slash splits into further segments.
		for _, s := range strings.Split(seg, "/") {
			if s != "" && segmentIsSecret(s) {
				return true
			}
		}
	}
	return false
}

func hasSecretPath(u *url.URL) bool {
	route, _, _ := strings.Cut(u.EscapedFragment(), "?")
	return pathSecret(u.EscapedPath()) || pathSecret(route)
}

// hostRefused matches host (already normalized) and each parent domain
// against SyncedHosts and refused. The keys of refused must be normalized
// (lowercase, IDNA ASCII, no trailing dot): build the set with NormalizeHostSet.
func hostRefused(host string, refused map[string]bool) bool {
	for h := host; h != ""; {
		if refused[h] {
			return true
		}
		for _, s := range SyncedHosts {
			if h == s {
				return true
			}
		}
		i := strings.IndexByte(h, '.')
		if i < 0 {
			break
		}
		h = h[i+1:]
	}
	return false
}

// isIPLiteral reports a host that is an IP address, including the numeric
// shorthand forms resolvers accept (a purely numeric last label, "0x…").
func isIPLiteral(host string) bool {
	if net.ParseIP(host) != nil {
		return true
	}
	labels := strings.Split(host, ".")
	last := labels[len(labels)-1]
	if strings.HasPrefix(last, "0x") {
		return true
	}
	for _, r := range last {
		if r < '0' || r > '9' {
			return false
		}
	}
	return last != ""
}

// Fetchable reports whether Watchtower may ever fetch raw, and returns its
// normalized form. It refuses non-http(s) schemes, ports other than 80/443,
// userinfo, secret-looking parameters (query, fragment, ";" path parameters)
// or path segments (also in a fragment route), IP-literal hosts (the fetcher's
// connect-time address check is the real gate), and hosts that are synced
// sources or in refusedHosts (exact or subdomain; build it with NormalizeHostSet). The web fetcher
// runs it again on every redirect hop.
func Fetchable(raw string, refusedHosts map[string]bool) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.User != nil || u.Opaque != "" {
		return "", false
	}
	if p := u.Port(); p != "" && p != "80" && p != "443" {
		return "", false
	}
	if hasSecretParam(u) || hasSecretPath(u) {
		return "", false
	}
	norm, ok := NormalizeURL(raw)
	if !ok {
		return "", false
	}
	host, ok := asciiHost(u.Hostname())
	if !ok || isIPLiteral(host) || hostRefused(host, refusedHosts) {
		return "", false
	}
	return norm, true
}
