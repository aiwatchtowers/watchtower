// Package policy reads the settings a company forces on Watchtower through its
// MDM (board #608, spec docs/superpowers/specs/2026-10-25-mdm-policy-design.md).
//
// A configuration profile for the preference domain Domain delivers the keys;
// only forced values count (POLICY-01). Normalize turns the raw forced values
// into a Policy, failing closed on a wrong type. The Swift twin is
// WatchtowerCore's ManagedPolicy; both run testdata/policy_cases.json
// (POLICY-02). Call sites ask the package helpers (SourceAllowed, …) only.
package policy

import (
	"math"
	"net/url"
	"slices"
	"strings"
)

// Domain is the preference domain an admin targets: the Desktop's bundle id.
// The CLI and daemon name it explicitly.
const Domain = "com.watchtower.desktop"

// The v1 keys, enforced.
const (
	KeyAllowedSources          = "AllowedSources"
	KeyMobileSync              = "MobileSync"
	KeyAllowedQuickConnections = "AllowedQuickConnections"
	KeyAllowAutomationShell    = "AllowAutomationShell"
	KeyAllowedAIProviders      = "AllowedAIProviders"
	KeyAllowClaudeAITools      = "AllowClaudeAITools"
	KeyPurgeRevokedData        = "PurgeRevokedData"
)

// The reserved keys: read and shown, not enforced in this version.
const (
	KeyRequireDatabaseEncryption = "RequireDatabaseEncryption"
	KeyRetentionDays             = "RetentionDays"
	KeyBulkReadLimits            = "BulkReadLimits"
)

// Keys are the v1 keys, in display order.
var Keys = []string{
	KeyAllowedSources, KeyMobileSync, KeyAllowedQuickConnections, KeyAllowAutomationShell,
	KeyAllowedAIProviders, KeyAllowClaudeAITools, KeyPurgeRevokedData,
}

// ReservedKeys are named now and enforced by their own boards later.
var ReservedKeys = []string{KeyRequireDatabaseEncryption, KeyRetentionDays, KeyBulkReadLimits}

// The closed value sets.
var (
	knownSources    = []string{"slack", "google", "imap", "caldav", "jira", "linear"}
	knownProviders  = []string{"claude", "codex", "ollama"}
	mobileSyncModes = []string{MobileAllowed, MobileWorkbenchOnly, MobileOff}
)

// The MobileSync modes.
const (
	MobileAllowed       = "allowed"
	MobileWorkbenchOnly = "workbench_only"
	MobileOff           = "off"
)

// The Problem kinds.
const (
	ProblemWrongType    = "wrong_type"
	ProblemUnknownValue = "unknown_value"
	ProblemInvalidEntry = "invalid_entry"
)

// Problem is one defect of the delivered profile.
type Problem struct {
	Key     string `json:"key"`
	Problem string `json:"problem"`
}

// Keyset holds the effective v1 values. nil = the key is absent (no
// restriction); an empty slice is a real, most restrictive value.
type Keyset struct {
	AllowedSources          []string `json:"AllowedSources"`
	MobileSync              *string  `json:"MobileSync"`
	AllowedQuickConnections []string `json:"AllowedQuickConnections"`
	AllowAutomationShell    *bool    `json:"AllowAutomationShell"`
	AllowedAIProviders      []string `json:"AllowedAIProviders"`
	AllowClaudeAITools      *bool    `json:"AllowClaudeAITools"`
	PurgeRevokedData        *bool    `json:"PurgeRevokedData"`
}

// Policy is the normalized policy, also the pinned `policy show --json`
// document.
type Policy struct {
	Managed             bool      `json:"managed"`
	Domain              string    `json:"domain"`
	Keys                Keyset    `json:"keys"`
	ReservedNotEnforced []string  `json:"reserved_not_enforced"`
	Errors              []Problem `json:"errors"`
}

// Normalize turns raw forced values (only forced keys, as the reader delivers
// them) into a Policy. Pure. A wrong type gives the key's most restrictive
// value; unknown or invalid array entries are dropped. Every defect lands in
// Errors.
func Normalize(raw map[string]any) Policy {
	n := normalizer{p: Policy{Domain: Domain, ReservedNotEnforced: []string{}, Errors: []Problem{}}}
	for _, k := range append(slices.Clone(Keys), ReservedKeys...) {
		if _, ok := raw[k]; ok {
			n.p.Managed = true
		}
	}
	ks := &n.p.Keys
	if v, ok := raw[KeyAllowedSources]; ok {
		ks.AllowedSources = n.list(KeyAllowedSources, v, closedSet(knownSources))
	}
	if v, ok := raw[KeyMobileSync]; ok {
		ks.MobileSync = n.mobileSync(v)
	}
	if v, ok := raw[KeyAllowedQuickConnections]; ok {
		ks.AllowedQuickConnections = n.list(KeyAllowedQuickConnections, v, connectionEntry)
	}
	if v, ok := raw[KeyAllowAutomationShell]; ok {
		ks.AllowAutomationShell = n.boolean(KeyAllowAutomationShell, v, false)
	}
	if v, ok := raw[KeyAllowedAIProviders]; ok {
		ks.AllowedAIProviders = n.list(KeyAllowedAIProviders, v, closedSet(knownProviders))
	}
	if v, ok := raw[KeyAllowClaudeAITools]; ok {
		ks.AllowClaudeAITools = n.boolean(KeyAllowClaudeAITools, v, false)
	}
	if v, ok := raw[KeyPurgeRevokedData]; ok {
		ks.PurgeRevokedData = n.boolean(KeyPurgeRevokedData, v, true)
	}
	n.reserved(raw)
	return n.p
}

type normalizer struct{ p Policy }

func (n *normalizer) report(key, problem string) {
	pr := Problem{Key: key, Problem: problem}
	if !slices.Contains(n.p.Errors, pr) {
		n.p.Errors = append(n.p.Errors, pr)
	}
}

// entryCheck classifies one string entry of an array key: "" = keep, else
// the problem kind it is dropped with.
type entryCheck func(string) string

func closedSet(set []string) entryCheck {
	return func(s string) string {
		if slices.Contains(set, s) {
			return ""
		}
		return ProblemUnknownValue
	}
}

func connectionEntry(s string) string {
	if isAbsPath(s) {
		return ""
	}
	if _, ok := httpsEntry(s); ok {
		return ""
	}
	return ProblemInvalidEntry
}

func (n *normalizer) list(key string, v any, check entryCheck) []string {
	arr, ok := v.([]any)
	if !ok {
		n.report(key, ProblemWrongType)
		return []string{}
	}
	out := []string{}
	for _, e := range arr {
		s, ok := e.(string)
		if !ok {
			n.report(key, ProblemInvalidEntry)
			continue
		}
		if problem := check(s); problem != "" {
			n.report(key, problem)
			continue
		}
		out = append(out, s)
	}
	return out
}

func (n *normalizer) mobileSync(v any) *string {
	off := MobileOff
	s, ok := v.(string)
	if !ok {
		n.report(KeyMobileSync, ProblemWrongType)
		return &off
	}
	if !slices.Contains(mobileSyncModes, s) {
		n.report(KeyMobileSync, ProblemUnknownValue)
		return &off
	}
	return &s
}

// boolean accepts only a real boolean; anything else (an integer 1 included)
// is a wrong type and gives restrictive.
func (n *normalizer) boolean(key string, v any, restrictive bool) *bool {
	b, ok := v.(bool)
	if !ok {
		n.report(key, ProblemWrongType)
		return &restrictive
	}
	return &b
}

// reserved lists the present reserved keys and reports a wrong type; their
// values are not enforced in this version.
func (n *normalizer) reserved(raw map[string]any) {
	for _, k := range ReservedKeys {
		v, ok := raw[k]
		if !ok {
			continue
		}
		n.p.ReservedNotEnforced = append(n.p.ReservedNotEnforced, k)
		var typeOK bool
		switch k {
		case KeyRequireDatabaseEncryption:
			_, typeOK = v.(bool)
		case KeyRetentionDays:
			typeOK = isIntegral(v)
		case KeyBulkReadLimits:
			_, typeOK = v.(map[string]any)
		}
		if !typeOK {
			n.report(k, ProblemWrongType)
		}
	}
}

func isIntegral(v any) bool {
	switch x := v.(type) {
	case int, int64:
		return true
	case float64:
		return x == math.Trunc(x) && !math.IsInf(x, 0)
	}
	return false
}

func isAbsPath(s string) bool { return strings.HasPrefix(s, "/") }

// httpsEntry parses an https:// URL with a host.
func httpsEntry(s string) (*url.URL, bool) {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, false
	}
	return u, true
}

// SourceAllowed reports whether src may be connected and synced.
func (p Policy) SourceAllowed(src string) bool {
	return p.Keys.AllowedSources == nil || slices.Contains(p.Keys.AllowedSources, src)
}

// MobileSyncMode returns the MobileSync mode; MobileAllowed when absent.
func (p Policy) MobileSyncMode() string {
	if p.Keys.MobileSync == nil {
		return MobileAllowed
	}
	return *p.Keys.MobileSync
}

// ConnectionAllowed reports whether a Quick Connection may be mounted, added,
// enabled or called. kind "http" matches rawURL against the https:// entries
// (https only, host incl. port case-insensitive, path on a "/" boundary or a
// plain prefix when the entry path ends in "/"); kind "stdio" matches command
// byte-equal to an absolute-path entry.
func (p Policy) ConnectionAllowed(kind, rawURL, command string) bool {
	allowed := p.Keys.AllowedQuickConnections
	if allowed == nil {
		return true
	}
	switch kind {
	case "http":
		return slices.ContainsFunc(allowed, func(e string) bool { return httpMatches(e, rawURL) })
	case "stdio":
		return isAbsPath(command) && slices.Contains(allowed, command)
	}
	return false
}

func httpMatches(entry, rawURL string) bool {
	eu, ok := httpsEntry(entry)
	if !ok {
		return false
	}
	cu, ok := httpsEntry(rawURL)
	if !ok || !strings.EqualFold(eu.Host, cu.Host) {
		return false
	}
	cp := cu.EscapedPath()
	if hasDotSegment(cp) {
		return false
	}
	ep := eu.EscapedPath()
	if ep == "" {
		ep = "/"
	}
	if cp == "" {
		cp = "/"
	}
	if strings.HasSuffix(ep, "/") {
		return strings.HasPrefix(cp, ep)
	}
	return cp == ep || strings.HasPrefix(cp, ep+"/")
}

// hasDotSegment refuses "." and ".." segments: the server would resolve them
// out of the allowed path.
func hasDotSegment(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if seg == "." || seg == ".." {
			return true
		}
	}
	return false
}

// ShellAllowed reports whether automations may call shell().
func (p Policy) ShellAllowed() bool {
	return p.Keys.AllowAutomationShell == nil || *p.Keys.AllowAutomationShell
}

// ProviderAllowed reports whether the LLM provider id may be used.
func (p Policy) ProviderAllowed(id string) bool {
	return p.Keys.AllowedAIProviders == nil || slices.Contains(p.Keys.AllowedAIProviders, id)
}

// ClaudeAIToolsAllowed reports whether the main chat may offer claude.ai
// publish and connectors.
func (p Policy) ClaudeAIToolsAllowed() bool {
	return p.Keys.AllowClaudeAITools == nil || *p.Keys.AllowClaudeAITools
}

// PurgeRevokedData returns the forced purge switch; set is false when the key
// is absent.
func (p Policy) PurgeRevokedData() (on, set bool) {
	if p.Keys.PurgeRevokedData == nil {
		return false, false
	}
	return *p.Keys.PurgeRevokedData, true
}

// AllowedList returns the effective list of an array key (nil when absent or
// not an array key), for error copy.
func (p Policy) AllowedList(key string) []string {
	switch key {
	case KeyAllowedSources:
		return p.Keys.AllowedSources
	case KeyAllowedQuickConnections:
		return p.Keys.AllowedQuickConnections
	case KeyAllowedAIProviders:
		return p.Keys.AllowedAIProviders
	}
	return nil
}
