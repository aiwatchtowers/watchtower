package cmd

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

const policyMCPRecipe = "---\nname: Policy MCP\ntrigger:\n  manual: true\npermissions:\n  - mcp:acme/*\noutputs: [report]\n---\n" +
	"Calls acme.\n\n```js\nmcp(\"acme\", \"get_item\", {})\n```\n"

// TestAutomationPolicy_RefusedAtValidateSaveAndConfirm: a recipe that needs
// a Quick Connection the organization's policy forbids is not ok at
// validate, not saved, not confirmed, and show/list mark it policy_blocked;
// it stays indexed and listed (#608).
func TestAutomationPolicy_RefusedAtValidateSaveAndConfirm(t *testing.T) {
	c := newAutoCLI(t)
	_, err := c.d.InsertExternalConnection(db.ExternalConnection{Name: "acme", Kind: "http", URL: "https://other.example.com/mcp"})
	require.NoError(t, err)
	a := c.indexRecipe(t, "policy-mcp", policyMCPRecipe)
	policytest.Set(t, map[string]any{"AllowedQuickConnections": []any{"https://mcp.example.com"}})

	v := runAutomationsJSON(t, "validate", writeRecipe(t, t.TempDir(), "policy-mcp", policyMCPRecipe))
	assert.Equal(t, false, v["ok"])
	assert.Contains(t, strings.Join(anyStrings(v["errors"]), " "), "Quick Connection acme is not allowed by your organization")

	_, err = runAutomations(t, "save", "--file", writeRecipe(t, t.TempDir(), "new-mcp", policyMCPRecipe),
		"--path", filepath.Join(c.personal, "new-mcp.md"))
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	_, err = c.d.GetAutomationBySlug("personal", 0, "new-mcp")
	require.Error(t, err, "nothing indexed")
	assert.NoFileExists(t, filepath.Join(c.personal, "new-mcp.md"), "nothing written")

	_, err = runAutomations(t, "confirm", idArg(a.ID), "--hash", a.ApprovalHash)
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	row, err := c.d.GetAutomation(a.ID)
	require.NoError(t, err)
	assert.Empty(t, row.ConfirmedHash, "not confirmed")

	assert.Equal(t, "mcp", runAutomationsJSON(t, "show", idArg(a.ID))["policy_blocked"])
	list := runAutomationsJSONList(t, "list")
	require.Len(t, list, 1, "the blocked recipe stays listed")
	assert.Equal(t, "mcp", list[0]["policy_blocked"])

	policytest.Set(t, nil)
	assert.Equal(t, "", runAutomationsJSON(t, "show", idArg(a.ID))["policy_blocked"])
	out, err := runAutomations(t, "confirm", idArg(a.ID), "--hash", a.ApprovalHash)
	require.NoError(t, err, out)
}

func anyStrings(v any) []string {
	var out []string
	if xs, ok := v.([]any); ok {
		for _, x := range xs {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}
