package cmd

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy/policytest"
)

func runPolicyShow(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&bytes.Buffer{})
	rootCmd.SetArgs(append([]string{"policy", "show"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	policyShowFlagJSON = false
	require.NoError(t, err, out.String())
	return out.String()
}

func policyShowJSON(t *testing.T) map[string]any {
	t.Helper()
	out := strings.TrimSpace(runPolicyShow(t, "--json"))
	lines := strings.Split(out, "\n")
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-1]), &m), out)
	return m
}

func TestPolicyShow_JSONKeys(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": "off", "RetentionDays": int64(30)})
	m := policyShowJSON(t)
	wantKeys(t, m, "managed", "domain", "keys", "reserved_not_enforced", "errors")
	keys, ok := m["keys"].(map[string]any)
	require.True(t, ok)
	wantKeys(t, keys, "AllowedSources", "MobileSync", "AllowedQuickConnections", "AllowAutomationShell",
		"AllowedAIProviders", "AllowClaudeAITools", "PurgeRevokedData")
	assert.Equal(t, true, m["managed"])
	assert.Equal(t, "com.watchtower.desktop", m["domain"])
	assert.Equal(t, "off", keys["MobileSync"])
	assert.Equal(t, []any{"RetentionDays"}, m["reserved_not_enforced"])
}

func TestPolicyShow_NoProfile(t *testing.T) {
	policytest.Set(t, nil)
	m := policyShowJSON(t)
	assert.Equal(t, false, m["managed"])
	assert.Equal(t, []any{}, m["errors"])
	assert.Equal(t, []any{}, m["reserved_not_enforced"])
	keys, ok := m["keys"].(map[string]any)
	require.True(t, ok)
	for k, v := range keys {
		assert.Nil(t, v, k)
	}
}

func TestPolicyShow_Plain(t *testing.T) {
	policytest.Set(t, map[string]any{
		"MobileSync":           "off",
		"AllowedSources":       []any{},
		"AllowedAIProviders":   []any{"claude", "ollama"},
		"AllowAutomationShell": 1,
		"RetentionDays":        int64(30),
	})
	out := runPolicyShow(t)
	assert.Contains(t, out, "Managed by your organization: yes (domain com.watchtower.desktop)\n")
	assert.Contains(t, out, "MobileSync: off\n")
	assert.Contains(t, out, "AllowedSources: none\n")
	assert.Contains(t, out, "AllowedAIProviders: claude, ollama\n")
	assert.Contains(t, out, "AllowAutomationShell: not allowed\n")
	assert.Contains(t, out, "AllowClaudeAITools: not set\n")
	assert.Contains(t, out, "Not enforced in this version: RetentionDays\n")
	assert.Contains(t, out, "Profile problems: AllowAutomationShell (wrong_type)\n")
}

func TestPolicyShow_PlainNoProfile(t *testing.T) {
	policytest.Set(t, nil)
	out := runPolicyShow(t)
	assert.Contains(t, out, "Managed by your organization: no (domain com.watchtower.desktop)\n")
	assert.Contains(t, out, "PurgeRevokedData: not set\n")
	assert.NotContains(t, out, "Not enforced")
	assert.NotContains(t, out, "Profile problems")
}
