// Package companybundle is the company bundle format (company setup spec §1):
// one versioned JSON object naming a company's own OAuth apps, carried by a
// connect link, an MDM key or a pasted code as base64url without padding.
// Parse fails closed: unknown or miscased fields, wrong types, a non-https
// site and malformed ids are refused, never repaired. It is pure (no I/O); the
// store lives in internal/company. The Swift twin is
// WatchtowerCore/Models/CompanyBundle.swift; both run
// testdata/bundle_cases.json.
package companybundle

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Version is the only bundle version this build reads.
const Version = 1

// MaxEncodedLen caps the wire form (Slack's long_description holds 4,000).
const MaxEncodedLen = 3000

// maxCompanyBytes caps the company name in UTF-8 bytes.
const maxCompanyBytes = 200

// maxSlugLen caps a slug; it names a file.
const maxSlugLen = 64

// Origin says where a bundle came from; only a stored file (OriginLocal) may
// carry `personal`.
type Origin int

const (
	OriginLink Origin = iota
	OriginMDM
	OriginCode
	OriginLocal
)

// Bundle is the normalized company bundle. Fields are in alphabetical JSON-key
// order so Encode's bytes equal the Swift twin's sorted-keys encoding.
type Bundle struct {
	Atlassian     *Atlassian `json:"atlassian,omitempty"`
	Company       string     `json:"company"`
	Google        *Google    `json:"google,omitempty"`
	Linear        *Linear    `json:"linear,omitempty"`
	LinkDenyHosts []string   `json:"link_deny_hosts,omitempty"`
	Microsoft     *Microsoft `json:"microsoft,omitempty"`
	Personal      bool       `json:"personal,omitempty"`
	Slack         *Slack     `json:"slack,omitempty"`
	V             int        `json:"v"`
}

// Slack names the company's Slack app.
type Slack struct {
	ClientID string `json:"client_id"`
	TeamID   string `json:"team_id"`
}

// Google is the company's (or, with Personal, the person's) OAuth client.
// Domain is optional (a personal project has none).
type Google struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	Domain       string `json:"domain,omitempty"`
}

// Atlassian is the company's 3LO app; Site is normalized to https://<host>.
type Atlassian struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	Confluence   bool   `json:"confluence"`
	Site         string `json:"site"`
}

// Linear is the company's Linear OAuth app.
type Linear struct {
	ClientID string `json:"client_id"`
}

// Microsoft is the company's Entra app; TenantID is a GUID or a verified
// domain, lower-cased.
type Microsoft struct {
	ClientID string `json:"client_id"`
	TenantID string `json:"tenant_id"`
}

// Refusal is the closed set of reasons a bundle is refused; the listener and
// the Desktop map each to one sentence.
type Refusal string

const (
	RefusalDamaged      Refusal = "damaged"
	RefusalTooLong      Refusal = "too_long"
	RefusalSiteNotHTTPS Refusal = "site_not_https"
	RefusalPersonal     Refusal = "personal"
	RefusalNewerVersion Refusal = "newer_version"
)

// refusals is every Refusal; the Swift enum holds the same raw values.
var refusals = []Refusal{RefusalDamaged, RefusalTooLong, RefusalSiteNotHTTPS, RefusalPersonal, RefusalNewerVersion}

// ParseError is the error every refused bundle returns; Detail names the
// offending field and is for logs, never shown to the user.
type ParseError struct {
	Reason Refusal
	Detail string
}

func (e *ParseError) Error() string {
	if e.Detail == "" {
		return "company bundle refused: " + string(e.Reason)
	}
	return "company bundle refused: " + string(e.Reason) + " (" + e.Detail + ")"
}

func refuse(r Refusal, detail string) *ParseError { return &ParseError{Reason: r, Detail: detail} }

func damaged(field string) *ParseError { return refuse(RefusalDamaged, field) }

var (
	wireCharset    = regexp.MustCompile(`^[A-Za-z0-9_-]*$`)
	slackTeamID    = regexp.MustCompile(`^[TE][A-Z0-9]{2,}$`)
	slackClientID  = regexp.MustCompile(`^[0-9]+\.[0-9]+$`)
	googleClientID = regexp.MustCompile(`^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$`)
	plainID        = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	secret         = regexp.MustCompile(`^[\x21-\x7e]{1,256}$`)
	guid           = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	hostLabel      = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
)

// trimASCII drops surrounding ASCII spaces, tabs and line breaks only, so Go
// and Swift trim the same characters.
func trimASCII(s string) string { return strings.Trim(s, " \t\r\n") }

// asciiLower lower-cases A–Z only: strings.ToLower would fold non-ASCII
// look-alikes (the Kelvin sign, a dotted İ) into ASCII hosts, and the Swift
// twin folds them differently.
func asciiLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 'a' - 'A'
		}
		return r
	}, s)
}

// Parse decodes and validates a wire-form bundle (link, MDM, code).
func Parse(wire string, origin Origin) (Bundle, error) {
	wire = trimASCII(wire)
	if len(wire) > MaxEncodedLen {
		return Bundle{}, refuse(RefusalTooLong, fmt.Sprintf("%d characters", len(wire)))
	}
	if !wireCharset.MatchString(wire) {
		return Bundle{}, damaged("wire: not base64url without padding")
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(wire)
	if err != nil {
		return Bundle{}, damaged("wire: " + err.Error())
	}
	return ParseJSON(raw, origin)
}

// ParseJSON validates a bundle's JSON (a stored file reads with OriginLocal).
func ParseJSON(raw []byte, origin Origin) (Bundle, error) {
	if !utf8.Valid(raw) {
		return Bundle{}, damaged("json: invalid UTF-8")
	}
	top, err := object(raw, "bundle")
	if err != nil {
		return Bundle{}, err
	}
	// The version first: a newer bundle may carry fields this build lacks.
	vRaw, ok := top["v"]
	if !ok {
		return Bundle{}, damaged("v: missing")
	}
	var v int
	if err := json.Unmarshal(vRaw, &v); err != nil || v < 1 {
		return Bundle{}, damaged("v")
	}
	if v > Version {
		return Bundle{}, refuse(RefusalNewerVersion, fmt.Sprintf("v=%d", v))
	}
	if err := onlyKeys(top, "bundle", "v", "company", "personal", "slack", "google", "atlassian", "linear", "microsoft", "link_deny_hosts"); err != nil {
		return Bundle{}, err
	}
	b := Bundle{V: v}
	if b.Company, err = str(top, "company"); err != nil {
		return Bundle{}, err
	}
	b.Company = trimASCII(b.Company)
	if !validCompany(b.Company) {
		return Bundle{}, damaged("company")
	}
	if b.Personal, err = boolean(top, "personal"); err != nil {
		return Bundle{}, err
	}
	if b.Personal && origin != OriginLocal {
		return Bundle{}, refuse(RefusalPersonal, "")
	}
	if err := parseVendors(top, &b); err != nil {
		return Bundle{}, err
	}
	if b.LinkDenyHosts, err = denyHosts(top["link_deny_hosts"]); err != nil {
		return Bundle{}, err
	}
	return b, nil
}

func parseVendors(top map[string]json.RawMessage, b *Bundle) error {
	var err error
	if b.Slack, err = parseSlack(top["slack"]); err != nil {
		return err
	}
	if b.Google, err = parseGoogle(top["google"]); err != nil {
		return err
	}
	if b.Atlassian, err = parseAtlassian(top["atlassian"]); err != nil {
		return err
	}
	if b.Linear, err = parseLinear(top["linear"]); err != nil {
		return err
	}
	b.Microsoft, err = parseMicrosoft(top["microsoft"])
	return err
}

func parseSlack(raw json.RawMessage) (*Slack, error) {
	m, err := block(raw, "slack", "team_id", "client_id")
	if m == nil || err != nil {
		return nil, err
	}
	s := &Slack{}
	if s.TeamID, err = id(m, "slack", "team_id", slackTeamID); err != nil {
		return nil, err
	}
	if s.ClientID, err = id(m, "slack", "client_id", slackClientID); err != nil {
		return nil, err
	}
	return s, nil
}

func parseGoogle(raw json.RawMessage) (*Google, error) {
	m, err := block(raw, "google", "client_id", "client_secret", "domain")
	if m == nil || err != nil {
		return nil, err
	}
	g := &Google{}
	if g.ClientID, err = id(m, "google", "client_id", googleClientID); err != nil {
		return nil, err
	}
	if g.ClientSecret, err = id(m, "google", "client_secret", secret); err != nil {
		return nil, err
	}
	d, err := str(m, "google.domain")
	if err != nil {
		return nil, err
	}
	if d = asciiLower(trimASCII(d)); d != "" && !validHost(d) {
		return nil, damaged("google.domain")
	}
	g.Domain = d
	return g, nil
}

func parseAtlassian(raw json.RawMessage) (*Atlassian, error) {
	m, err := block(raw, "atlassian", "client_id", "client_secret", "site", "confluence")
	if m == nil || err != nil {
		return nil, err
	}
	a := &Atlassian{}
	if a.ClientID, err = id(m, "atlassian", "client_id", plainID); err != nil {
		return nil, err
	}
	if a.ClientSecret, err = id(m, "atlassian", "client_secret", secret); err != nil {
		return nil, err
	}
	site, err := str(m, "atlassian.site")
	if err != nil {
		return nil, err
	}
	if a.Site, err = normalizeSite(site); err != nil {
		return nil, err
	}
	if a.Confluence, err = boolean(m, "atlassian.confluence"); err != nil {
		return nil, err
	}
	return a, nil
}

func parseLinear(raw json.RawMessage) (*Linear, error) {
	m, err := block(raw, "linear", "client_id")
	if m == nil || err != nil {
		return nil, err
	}
	l := &Linear{}
	if l.ClientID, err = id(m, "linear", "client_id", plainID); err != nil {
		return nil, err
	}
	return l, nil
}

func parseMicrosoft(raw json.RawMessage) (*Microsoft, error) {
	m, err := block(raw, "microsoft", "client_id", "tenant_id")
	if m == nil || err != nil {
		return nil, err
	}
	ms := &Microsoft{}
	cid, err := str(m, "microsoft.client_id")
	if err != nil {
		return nil, err
	}
	if ms.ClientID = asciiLower(trimASCII(cid)); !guid.MatchString(ms.ClientID) {
		return nil, damaged("microsoft.client_id")
	}
	tid, err := str(m, "microsoft.tenant_id")
	if err != nil {
		return nil, err
	}
	if ms.TenantID = asciiLower(trimASCII(tid)); !guid.MatchString(ms.TenantID) && !validHost(ms.TenantID) {
		return nil, damaged("microsoft.tenant_id")
	}
	return ms, nil
}

// normalizeSite accepts https://<host> with an optional trailing slash and
// returns it lower-cased without the slash; any other scheme (or none) is
// site_not_https, a path, port, query or user part is damaged.
func normalizeSite(site string) (string, error) {
	s := asciiLower(trimASCII(site))
	if s == "" {
		return "", damaged("atlassian.site: missing")
	}
	host, ok := strings.CutPrefix(s, "https://")
	if !ok {
		return "", refuse(RefusalSiteNotHTTPS, "atlassian.site")
	}
	host = strings.TrimSuffix(host, "/")
	if !validHost(host) {
		return "", damaged("atlassian.site")
	}
	return "https://" + host, nil
}

// denyHosts reads link_deny_hosts: bare lower-case DNS names only (no scheme,
// path, port, wildcard or IP literal), the form linkrule.NormalizeHostSet
// keeps unchanged. A hostile entry refuses the whole bundle.
func denyHosts(raw json.RawMessage) ([]string, error) {
	if isAbsent(raw) {
		return nil, nil
	}
	var list []json.RawMessage
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, damaged("link_deny_hosts")
	}
	var out []string
	for i, item := range list {
		var h string
		if isAbsent(item) || json.Unmarshal(item, &h) != nil {
			return nil, damaged(fmt.Sprintf("link_deny_hosts[%d]", i))
		}
		if h = asciiLower(trimASCII(h)); !validHost(h) {
			return nil, damaged(fmt.Sprintf("link_deny_hosts[%d]", i))
		}
		out = append(out, h)
	}
	return out, nil
}

// validHost: a lower-case ASCII DNS name of two or more labels whose last
// label has a letter (so no IPv4 literal), at most 253 characters.
func validHost(h string) bool {
	if len(h) > 253 {
		return false
	}
	labels := strings.Split(h, ".")
	if len(labels) < 2 {
		return false
	}
	for _, l := range labels {
		if !hostLabel.MatchString(l) {
			return false
		}
	}
	return strings.ContainsAny(labels[len(labels)-1], "abcdefghijklmnopqrstuvwxyz")
}

// validCompany: non-empty, at most maxCompanyBytes, no control or line/
// paragraph separator characters.
func validCompany(c string) bool {
	if c == "" || len(c) > maxCompanyBytes {
		return false
	}
	for _, r := range c {
		if unicode.Is(unicode.Cc, r) || unicode.Is(unicode.Zl, r) || unicode.Is(unicode.Zp, r) {
			return false
		}
	}
	return true
}

// object decodes a JSON object into its raw members.
func object(raw []byte, field string) (map[string]json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil || m == nil {
		return nil, damaged(field + ": not an object")
	}
	return m, nil
}

// onlyKeys refuses any member not in allowed — exact case, unlike
// encoding/json's case-insensitive field match.
func onlyKeys(m map[string]json.RawMessage, field string, allowed ...string) error {
	for k := range m {
		found := false
		for _, a := range allowed {
			if k == a {
				found = true
				break
			}
		}
		if !found {
			return damaged(field + ": unknown field " + k)
		}
	}
	return nil
}

// block reads an optional vendor object; absent or null returns nil, nil.
func block(raw json.RawMessage, field string, allowed ...string) (map[string]json.RawMessage, error) {
	if isAbsent(raw) {
		return nil, nil
	}
	m, err := object(raw, field)
	if err != nil {
		return nil, err
	}
	if err := onlyKeys(m, field, allowed...); err != nil {
		return nil, err
	}
	return m, nil
}

// isAbsent: a missing member or a JSON null.
func isAbsent(raw json.RawMessage) bool {
	return raw == nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// str reads an optional string member (absent or null → ""); key is the
// dotted path, its last segment the member name.
func str(m map[string]json.RawMessage, key string) (string, error) {
	raw := m[key[strings.LastIndex(key, ".")+1:]]
	if isAbsent(raw) {
		return "", nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", damaged(key + ": not a string")
	}
	return s, nil
}

// boolean reads an optional bool member (absent or null → false).
func boolean(m map[string]json.RawMessage, key string) (bool, error) {
	raw := m[key[strings.LastIndex(key, ".")+1:]]
	if isAbsent(raw) {
		return false, nil
	}
	var b bool
	if err := json.Unmarshal(raw, &b); err != nil {
		return false, damaged(key + ": not a bool")
	}
	return b, nil
}

// id reads a required string member, trims it and matches it against re.
func id(m map[string]json.RawMessage, vendor, name string, re *regexp.Regexp) (string, error) {
	s, err := str(m, vendor+"."+name)
	if err != nil {
		return "", err
	}
	if s = trimASCII(s); !re.MatchString(s) {
		return "", damaged(vendor + "." + name)
	}
	return s, nil
}

// Encode validates b (as a link would be read) and returns its normalized
// wire form: base64url of the sorted-keys JSON, no padding.
func Encode(b Bundle) (string, error) {
	raw, err := marshal(b)
	if err != nil {
		return "", err
	}
	n, err := ParseJSON(raw, OriginLink)
	if err != nil {
		return "", err
	}
	if raw, err = marshal(n); err != nil {
		return "", err
	}
	wire := base64.RawURLEncoding.EncodeToString(raw)
	if len(wire) > MaxEncodedLen {
		return "", refuse(RefusalTooLong, fmt.Sprintf("%d characters", len(wire)))
	}
	return wire, nil
}

// marshal is json.Marshal without HTML escaping or the trailing newline, the
// bytes Swift's JSONEncoder([.sortedKeys, .withoutEscapingSlashes]) writes.
func marshal(b Bundle) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// reservedSlugs would collide with the store's own files in company/.
var reservedSlugs = map[string]bool{"draft": true}

// Slug is the file-name stem for a company: ASCII-lower-cased, every run of
// characters outside [a-z0-9] one dash, no leading or trailing dash, at most
// 64 characters; "company" when nothing is left, "<slug>-company" for a name
// the store reserves. A clash between two different companies is the store's
// to resolve (numeric suffix).
func Slug(company string) string {
	var sb strings.Builder
	dash := false
	for i := 0; i < len(company); i++ {
		c := company[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			if dash && sb.Len() > 0 {
				sb.WriteByte('-')
			}
			dash = false
			sb.WriteByte(c)
			continue
		}
		dash = true
	}
	s := sb.String()
	if len(s) > maxSlugLen {
		s = strings.TrimRight(s[:maxSlugLen], "-")
	}
	switch {
	case s == "":
		return "company"
	case reservedSlugs[s]:
		return s + "-company"
	}
	return s
}

// Vendors lists the vendor blocks present, in the fixed order the connect
// chain and the confirmation use.
func (b Bundle) Vendors() []string {
	var out []string
	if b.Slack != nil {
		out = append(out, "slack")
	}
	if b.Google != nil {
		out = append(out, "google")
	}
	if b.Atlassian != nil {
		out = append(out, "atlassian")
	}
	if b.Microsoft != nil {
		out = append(out, "microsoft")
	}
	if b.Linear != nil {
		out = append(out, "linear")
	}
	return out
}
