package cmd

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// grantRecipe is a recipe whose manifest admits create_idea (ideas:write),
// create_target through outputs:[target] and only reads of Jira.
type grantRecipe struct {
	name, description, trigger, budget, script string
}

func defaultGrantRecipe() grantRecipe {
	return grantRecipe{name: "Grants", description: "A grant test recipe.", trigger: "manual: true",
		budget: "tokens: 50000", script: "return 1"}
}

func (g grantRecipe) text() string {
	return fmt.Sprintf("---\nname: %s\ntrigger:\n  %s\npermissions:\n  - ideas:write\n  - jira:read@*\n"+
		"outputs: [report, target]\nbudget:\n  %s\n---\n%s\n\n```js\n%s\n```\n",
		g.name, g.trigger, g.budget, g.description, g.script)
}

// grantRows returns the automation's grant rows (never nil).
func (c *autoCLI) grantRows(t *testing.T, id int64) []db.AutomationToolGrant {
	t.Helper()
	gs, err := c.d.ListAutomationToolGrants(id)
	require.NoError(t, err)
	return gs
}

func TestAgent03_AutoGrantRefusedUnderAgentMarkers(t *testing.T) {
	require.Contains(t, agentEnvMarkers, automations.RunEnvMarker, "an automation run's children are agents too")
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.confirmedRecipe(t, "grants", defaultGrantRecipe().text())
			out, err := runAutomations(t, "auto", idArg(a.ID), "create_target", "on", "--hash", a.ApprovalHash)
			require.NoError(t, err, out)

			t.Setenv(marker, "1")
			_, err = runAutomations(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", a.ApprovalHash)
			require.Error(t, err)
			assert.Contains(t, err.Error(), marker)
			assert.Contains(t, err.Error(), "the owner decides in Watchtower Desktop (or runs this from a plain Terminal)")
			_, err = runAutomations(t, "auto", "999999", "create_idea", "on", "--hash", a.ApprovalHash)
			require.ErrorContains(t, err, marker, "refused before the automation is looked up")
			gs := c.grantRows(t, a.ID)
			require.Len(t, gs, 1, "no grant row written under %s", marker)
			assert.Equal(t, "create_target", gs[0].Tool)

			out, err = runAutomations(t, "auto", idArg(a.ID), "create_target", "off")
			require.NoError(t, err, "off stays open under %s: %s", marker, out)
			assert.Empty(t, c.grantRows(t, a.ID))
		})
	}
}

func TestAutomationsAuto_RefusesStaleHashAlwaysAskAndNotAdmitted(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "grants", defaultGrantRecipe().text())
	cases := []struct {
		name, tool, hash, want string
	}{
		{"stale hash", "create_idea", strings.Repeat("0", 64), "the recipe changed; reload and confirm again"},
		{"always ask", "dismiss_tracks", a.ApprovalHash, "D14"},
		{"not admitted as a write", "create_jira_issue", a.ApprovalHash, "do not admit create_jira_issue as a write"},
		{"read tool", "list_targets", a.ApprovalHash, "do not admit list_targets as a write"},
		{"unknown tool", "no_such_tool", a.ApprovalHash, `unknown tool "no_such_tool"`},
		{"no hash", "create_idea", "", "--hash is required"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			args := []string{"auto", idArg(a.ID), tc.tool, "on"}
			if tc.hash != "" {
				args = append(args, "--hash", tc.hash)
			}
			_, err := runAutomations(t, args...)
			require.ErrorContains(t, err, tc.want)
			assert.Empty(t, c.grantRows(t, a.ID), "no grant row")
		})
	}
	_, err := runAutomations(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", strings.Repeat("0", 64))
	require.ErrorIs(t, err, db.ErrHashMismatch)
	_, err = runAutomations(t, "auto", idArg(a.ID), "create_idea", "maybe", "--hash", a.ApprovalHash)
	require.ErrorContains(t, err, `want "on" or "off"`)
	_, err = runAutomations(t, "auto", "999999", "create_idea", "on", "--hash", a.ApprovalHash)
	require.ErrorIs(t, err, db.ErrAutomationNotFound)

	broken := c.indexRecipe(t, "broken", "broken")
	_, err = runAutomations(t, "auto", idArg(broken.ID), "create_idea", "on", "--hash", "x")
	require.ErrorIs(t, err, db.ErrHashMismatch, "the hash is compared before the recipe is parsed")
	_, err = c.d.Exec(`UPDATE automations SET approval_hash = 'x' WHERE id = ?`, broken.ID)
	require.NoError(t, err)
	_, err = runAutomations(t, "auto", idArg(broken.ID), "create_idea", "on", "--hash", "x")
	require.ErrorContains(t, err, "does not parse", "a parse-error row admits nothing")
	assert.Empty(t, c.grantRows(t, broken.ID))
}

// Without outputs:[target] and without targets:write, create_target is not
// a write the manifest admits, so its grant is refused.
func TestAutomationsAuto_CreateTargetNeedsOutputOrPermission(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "plain", autoCLIRecipeText(`return 1`))
	_, err := runAutomations(t, "auto", idArg(a.ID), "create_target", "on", "--hash", a.ApprovalHash)
	require.ErrorContains(t, err, "do not admit create_target as a write")
	assert.Empty(t, c.grantRows(t, a.ID))
}

// grantsOf reads the grants array of show --json as tool → active.
func grantsOf(t *testing.T, show map[string]any) map[string]bool {
	t.Helper()
	raw, ok := show["grants"].([]any)
	require.True(t, ok, "grants is an array: %v", show["grants"])
	out := map[string]bool{}
	for _, g := range raw {
		m := g.(map[string]any)
		wantKeys(t, m, "tool", "active", "granted_at")
		out[m["tool"].(string)] = m["active"].(bool)
	}
	return out
}

// listItem returns the `list --json` row of automation id.
func listItem(t *testing.T, id int64) map[string]any {
	t.Helper()
	for _, it := range runAutomationsJSONList(t, "list") {
		if it["id"] == float64(id) {
			return it
		}
	}
	t.Fatalf("automation %d not listed", id)
	return nil
}

// saveConfirmed saves g over automation a's file as the owner, confirming it
// at its new approval hash, and returns the new row.
func (c *autoCLI) saveConfirmed(t *testing.T, a *db.Automation, g grantRecipe) *db.Automation {
	t.Helper()
	src := writeRecipe(t, t.TempDir(), "grants", g.text())
	v := runAutomationsJSON(t, "validate", src)
	runAutomationsJSON(t, "save", "--file", src, "--path", a.Path, "--confirm-hash", v["approval_hash"].(string))
	row, err := c.d.GetAutomation(a.ID)
	require.NoError(t, err)
	return row
}

func assertGrantState(t *testing.T, id int64, active bool) {
	t.Helper()
	assert.Equal(t, map[string]bool{"create_idea": active}, grantsOf(t, runAutomationsJSON(t, "show", idArg(id))))
	item := listItem(t, id)
	assert.Equal(t, !active, item["auto_paused"])
	require.Len(t, item["grants"], 1)
	assert.Equal(t, active, item["grants"].([]any)[0].(map[string]any)["active"])
}

func TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash(t *testing.T) {
	edits := []struct {
		name      string
		edit      func(*grantRecipe)
		keepsAuto bool
	}{
		{"script", func(g *grantRecipe) { g.script = "return 2" }, false},
		{"trigger", func(g *grantRecipe) { g.trigger = `schedule: "0 9 * * 1"` }, false},
		{"budget", func(g *grantRecipe) { g.budget = "tokens: 60000" }, false},
		{"name and description", func(g *grantRecipe) { g.name, g.description = "Renamed", "Another description." }, true},
	}
	for _, e := range edits {
		t.Run(e.name, func(t *testing.T) {
			c := newAutoCLI(t)
			g := defaultGrantRecipe()
			a := c.confirmedRecipe(t, "grants", g.text())
			got := runAutomationsJSON(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", a.ApprovalHash)
			assert.Equal(t, true, got["auto"])
			assertGrantState(t, a.ID, true)

			e.edit(&g)
			row := c.saveConfirmed(t, a, g)
			assert.Equal(t, e.keepsAuto, row.ApprovalHash == a.ApprovalHash, "hash scope (D26)")
			assertGrantState(t, a.ID, e.keepsAuto)
			if e.keepsAuto {
				return
			}
			_, err := runAutomations(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", a.ApprovalHash)
			require.ErrorIs(t, err, db.ErrHashMismatch, "the old hash cannot re-grant")
			runAutomationsJSON(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", row.ApprovalHash)
			assertGrantState(t, a.ID, true)
		})
	}
}

func TestAutomationsAuto_OffIsIdempotent(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "grants", defaultGrantRecipe().text())
	got := runAutomationsJSON(t, "auto", idArg(a.ID), "create_idea", "off")
	assert.Equal(t, map[string]any{"automation_id": float64(a.ID), "tool": "create_idea", "auto": false, "changed": false}, got)

	runAutomationsJSON(t, "auto", "grants", "create_idea", "on", "--hash", a.ApprovalHash)
	got = runAutomationsJSON(t, "auto", "grants", "create_idea", "off")
	assert.Equal(t, true, got["changed"])
	assert.Empty(t, c.grantRows(t, a.ID))
	out, err := runAutomations(t, "auto", idArg(a.ID), "create_idea", "off")
	require.NoError(t, err, out)
	assert.Contains(t, out, "no auto grant")
	_, err = runAutomations(t, "auto", "999999", "create_idea", "off")
	require.ErrorIs(t, err, db.ErrAutomationNotFound)
}

func TestAutomationsAuto_GrantsJSONNeverNull(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "grants", defaultGrantRecipe().text())
	assert.Equal(t, []any{}, runAutomationsJSON(t, "show", idArg(a.ID))["grants"])
	item := listItem(t, a.ID)
	assert.Equal(t, []any{}, item["grants"])
	assert.Equal(t, false, item["auto_paused"])

	broken := c.indexRecipe(t, "broken", "broken")
	assert.Equal(t, []any{}, runAutomationsJSON(t, "show", idArg(broken.ID))["grants"])
	wantKeys(t, runAutomationsJSON(t, "auto", idArg(a.ID), "create_idea", "on", "--hash", a.ApprovalHash),
		"automation_id", "tool", "auto", "changed")
	keys := automationJSONKeys(listItem(t, a.ID))
	assert.True(t, slices.Contains(keys, "grants") && slices.Contains(keys, "auto_paused"), "%v", keys)
}
