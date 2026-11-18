package policy

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
)

type fixture struct {
	Cases []struct {
		Name string          `json:"name"`
		Raw  map[string]any  `json:"raw"`
		Want json.RawMessage `json:"want"`
	} `json:"cases"`
	ConnectionCases []struct {
		Name    string `json:"name"`
		Allowed []any  `json:"allowed"`
		Kind    string `json:"kind"`
		URL     string `json:"url"`
		Command string `json:"command"`
		Want    bool   `json:"want"`
	} `json:"connection_cases"`
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "policy_cases.json"))
	require.NoError(t, err)
	var f fixture
	require.NoError(t, json.Unmarshal(b, &f))
	require.NotEmpty(t, f.Cases)
	require.NotEmpty(t, f.ConnectionCases)
	return f
}

// TestPolicy02_SharedFixture runs the fixture the Swift ManagedPolicyTests
// run too: Go and Swift normalize and match the same way.
func TestPolicy02_SharedFixture(t *testing.T) {
	f := loadFixture(t)
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := json.Marshal(Normalize(c.Raw))
			require.NoError(t, err)
			assert.JSONEq(t, string(c.Want), string(got))
		})
	}
	for _, c := range f.ConnectionCases {
		t.Run("connection/"+c.Name, func(t *testing.T) {
			raw := map[string]any{}
			if c.Allowed != nil {
				raw[KeyAllowedQuickConnections] = c.Allowed
			}
			assert.Equal(t, c.Want, Normalize(raw).ConnectionAllowed(c.Kind, c.URL, c.Command))
		})
	}
}

// TestPolicy01_WrongTypesFailClosed pins that a wrong-typed value of each v1
// key gives the most restrictive answer.
func TestPolicy01_WrongTypesFailClosed(t *testing.T) {
	cases := []struct {
		key        string
		value      any
		restricted func(Policy) bool
	}{
		{KeyAllowedSources, "slack", func(p Policy) bool { return !p.SourceAllowed("slack") }},
		{KeyMobileSync, 1, func(p Policy) bool { return p.MobileSyncMode() == MobileOff }},
		{KeyAllowedQuickConnections, "https://mcp.example.com", func(p Policy) bool {
			return !p.ConnectionAllowed("http", "https://mcp.example.com/", "")
		}},
		{KeyAllowAutomationShell, 1, func(p Policy) bool { return !p.ShellAllowed() }},
		{KeyAllowAutomationShell, int64(1), func(p Policy) bool { return !p.ShellAllowed() }},
		{KeyAllowedAIProviders, "claude", func(p Policy) bool { return !p.ProviderAllowed("claude") }},
		{KeyAllowClaudeAITools, "yes", func(p Policy) bool { return !p.ClaudeAIToolsAllowed() }},
		{KeyPurgeRevokedData, 0, func(p Policy) bool { on, set := p.PurgeRevokedData(); return on && set }},
		{KeyCompanyBundle, 1, func(p Policy) bool { return p.CompanyBundle() == "" }},
		{KeyCompanyBundle, []any{"x"}, func(p Policy) bool { return p.CompanyBundle() == "" }},
		{KeyAllowAtlassianAPIToken, 1, func(p Policy) bool { return !p.AtlassianAPITokenAllowed() }},
		{KeyAllowOwnGoogleProject, "true", func(p Policy) bool { return !p.OwnGoogleProjectAllowed() }},
	}
	for _, c := range cases {
		t.Run(c.key, func(t *testing.T) {
			p := Normalize(map[string]any{c.key: c.value})
			assert.True(t, c.restricted(p), "wrong type must fail closed")
			assert.Equal(t, []Problem{{Key: c.key, Problem: ProblemWrongType}}, p.Errors)
			assert.True(t, p.Managed)
		})
	}
}

func TestPolicy_AbsentKeysRestrictNothing(t *testing.T) {
	p := Normalize(nil)
	assert.False(t, p.Managed)
	assert.True(t, p.SourceAllowed("linear"))
	assert.Equal(t, MobileAllowed, p.MobileSyncMode())
	assert.True(t, p.ConnectionAllowed("stdio", "", "/bin/anything"))
	assert.True(t, p.ShellAllowed())
	assert.True(t, p.ProviderAllowed("codex"))
	assert.True(t, p.ClaudeAIToolsAllowed())
	on, set := p.PurgeRevokedData()
	assert.False(t, on)
	assert.False(t, set)
	assert.Empty(t, p.CompanyBundle())
	assert.True(t, p.AtlassianAPITokenAllowed())
	assert.True(t, p.OwnGoogleProjectAllowed())
}

// TestPolicy01_RefusedCompanyBundleIsAbsent pins that a forced bundle
// companybundle.Parse refuses from MDM (here one carrying `personal`) is no
// company, reported as an invalid entry.
func TestPolicy01_RefusedCompanyBundleIsAbsent(t *testing.T) {
	// {"v":1,"company":"Acme","personal":true}; Encode refuses `personal`.
	personal := "eyJ2IjoxLCJjb21wYW55IjoiQWNtZSIsInBlcnNvbmFsIjp0cnVlfQ"
	p := Normalize(map[string]any{KeyCompanyBundle: personal})
	assert.Empty(t, p.CompanyBundle())
	assert.Equal(t, []Problem{{Key: KeyCompanyBundle, Problem: ProblemInvalidEntry}}, p.Errors)
	assert.True(t, p.Managed)

	valid, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Acme"})
	require.NoError(t, err)
	assert.Equal(t, valid, Normalize(map[string]any{KeyCompanyBundle: valid}).CompanyBundle())
}

func TestPolicy_ErrorsWrapErrNotAllowed(t *testing.T) {
	p := Normalize(map[string]any{
		KeyAllowedAIProviders:      []any{"claude", "ollama"},
		KeyAllowedSources:          []any{},
		KeyAllowedQuickConnections: []any{"https://mcp.example.com"},
	})

	err := p.ProviderError("codex")
	assert.True(t, errors.Is(err, ErrNotAllowed))
	assert.Equal(t, "policy: AI provider codex is not allowed by your organization (allowed: claude, ollama)", err.Error())

	err = p.SourceError("jira")
	assert.True(t, errors.Is(err, ErrNotAllowed))
	assert.Contains(t, err.Error(), "(allowed: none)")

	err = p.ConnectionError("acme")
	assert.True(t, errors.Is(err, ErrNotAllowed))
	assert.Contains(t, err.Error(), "Quick Connection acme is not allowed by your organization (allowed: https://mcp.example.com)")

	err = ShellError()
	assert.True(t, errors.Is(err, ErrNotAllowed))
	assert.Equal(t, "policy: shell() in automations is not allowed by your organization", err.Error())
}

// TestPolicy_ErrorUsesItsSnapshot pins that the message lists the snapshot
// that refused, not a later read.
func TestPolicy_ErrorUsesItsSnapshot(t *testing.T) {
	restore := SetReaderForTesting(func() map[string]any { return map[string]any{KeyAllowedSources: []any{"slack"}} })
	t.Cleanup(restore)
	p := Current()
	inner := SetReaderForTesting(func() map[string]any { return map[string]any{KeyAllowedSources: []any{"linear"}} })
	t.Cleanup(inner)
	assert.Contains(t, p.SourceError("jira").Error(), "(allowed: slack)")
}
