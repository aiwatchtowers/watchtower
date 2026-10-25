// Package media turns images and web links into knowledge. This file holds the
// link rules: which URLs are extracted from text, how they are normalized, and
// which ones Watchtower must never fetch.
package media

import (
	"net/url"
	"regexp"
	"sort"
	"strings"

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
	secretParamSet   = toSet(SecretParams)
	secretSegmentSet = toSet(SecretPathSegments)
	slackAngleRe     = regexp.MustCompile(`<([^<>]+)>`)
	textLinkRe       = regexp.MustCompile(`(?i)https?://[^\s<>]+`)
)

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
		if isHTTP(m) && len(m) > len("https://") {
			out = append(out, m)
		}
	}
	return out
}

func asciiHost(h string) (string, bool) {
	h = strings.TrimSuffix(strings.ToLower(h), ".")
	if h == "" {
		return "", false
	}
	a, err := idna.Lookup.ToASCII(h)
	if err != nil || a == "" {
		return "", false
	}
	return strings.ToLower(a), true
}

func isTrackingKey(k string) bool {
	k = strings.ToLower(k)
	return strings.HasPrefix(k, "utm_") || k == "fbclid" || k == "gclid" || k == "mc_cid" || k == "mc_eid"
}

// NormalizeURL canonicalizes an http(s) URL: lowercase scheme and host, IDNA
// ASCII host, default port and fragment dropped, tracking parameters dropped,
// remaining query pairs sorted. It reports false for unparseable input.
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
	} else if len(pairs) > 0 {
		b.WriteString("/")
	}
	if len(pairs) > 0 {
		b.WriteString("?" + strings.Join(pairs, "&"))
	}
	return b.String(), true
}

// paramKeys lists the lowercased, unescaped keys of a k=v&k=v string.
func paramKeys(s string) []string {
	var keys []string
	for _, p := range strings.Split(s, "&") {
		if i := strings.IndexByte(p, '='); i >= 0 {
			p = p[:i]
		}
		if p == "" {
			continue
		}
		if dk, err := url.QueryUnescape(p); err == nil {
			p = dk
		}
		keys = append(keys, strings.ToLower(p))
	}
	return keys
}

func hasSecretParam(u *url.URL) bool {
	keys := append(paramKeys(u.RawQuery), paramKeys(u.EscapedFragment())...)
	var expires, keyPair bool
	for _, k := range keys {
		switch {
		case secretParamSet[k], strings.HasPrefix(k, "x-amz-"), strings.HasPrefix(k, "x-goog-"):
			return true
		case k == "expires":
			expires = true
		case k == "key-pair-id":
			keyPair = true
		}
	}
	return expires && keyPair
}

func segmentIsSecret(seg string) bool {
	seg = strings.ToLower(seg)
	tokens := strings.FieldsFunc(seg, func(r rune) bool { return r == '-' || r == '_' || r == '.' })
	for _, t := range tokens {
		if secretSegmentSet[t] {
			return true
		}
	}
	return secretSegmentSet[strings.Join(tokens, "")]
}

func hasSecretPath(u *url.URL) bool {
	for _, raw := range strings.Split(u.EscapedPath(), "/") {
		seg, err := url.PathUnescape(raw)
		if err != nil {
			seg = raw
		}
		// An encoded slash splits into further segments.
		for _, s := range strings.Split(seg, "/") {
			if s != "" && segmentIsSecret(s) {
				return true
			}
		}
	}
	return false
}

func hostRefused(host string, refused map[string]bool) bool {
	match := func(set func(string) bool) bool {
		for h := host; h != ""; {
			if set(h) {
				return true
			}
			i := strings.IndexByte(h, '.')
			if i < 0 {
				break
			}
			h = h[i+1:]
		}
		return false
	}
	if match(func(h string) bool {
		for _, s := range SyncedHosts {
			if h == s {
				return true
			}
		}
		return false
	}) {
		return true
	}
	return match(func(h string) bool {
		if refused[h] {
			return true
		}
		for k, v := range refused {
			if v && strings.EqualFold(strings.TrimSuffix(k, "."), h) {
				return true
			}
		}
		return false
	})
}

// Fetchable reports whether Watchtower may ever fetch raw, and returns its
// normalized form. It refuses non-http(s) schemes, ports other than 80/443,
// userinfo, secret-looking parameters or path segments, and hosts that are
// synced sources or in refusedHosts (exact or subdomain). The web fetcher
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
	host, _ := asciiHost(u.Hostname())
	if hostRefused(host, refusedHosts) {
		return "", false
	}
	return norm, true
}
