package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
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

// autoToolsOf reads show --json's auto_tools as tool → always_asks.
func autoToolsOf(t *testing.T, show map[string]any) map[string]bool {
	t.Helper()
	raw, ok := show["auto_tools"].([]any)
	require.True(t, ok, "auto_tools is an array, never null: %v", show["auto_tools"])
	out := map[string]bool{}
	for _, e := range raw {
		m := e.(map[string]any)
		wantKeys(t, m, "tool", "always_asks")
		out[m["tool"].(string)] = m["always_asks"].(bool)
	}
	return out
}

// show --json's auto_tools lists the writes the manifest admits — by
// capability (ideas:write → create_idea) and through an output shortcut
// (outputs:[target] → create_target) — and no read tool; a recipe that admits
// no write has [].
func TestAutomationsCLI_ShowAutoTools(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "grants", defaultGrantRecipe().text())
	got := autoToolsOf(t, runAutomationsJSON(t, "show", idArg(a.ID)))
	assert.Contains(t, got, "create_idea")
	assert.False(t, got["create_idea"])
	assert.Contains(t, got, "create_target", "outputs:[target] admits create_target")
	assert.NotContains(t, got, "list_jira_issues", "a read tool is never an auto tool")
	assert.NotContains(t, got, "create_jira_issue", "jira:read admits no Jira write")

	plain := c.indexRecipe(t, "plain", autoCLIRecipeText(`return 1`))
	assert.Empty(t, autoToolsOf(t, runAutomationsJSON(t, "show", idArg(plain.ID))))

	broken := c.indexRecipe(t, "broken", "broken")
	assert.Empty(t, automationAutoTools(tools.New(c.d), broken), "a parse-error row admits nothing")
}

// llmSendRecipe is defaultGrantRecipe plus llm:light and slack:write@*
// (jira:read@* already brings data in).
func llmSendRecipe(g grantRecipe) string {
	return strings.Replace(g.text(), "  - ideas:write\n", "  - ideas:write\n  - llm:light\n  - slack:write@*\n", 1)
}

// llmAutoWritesOf reads show --json's llm_auto_writes.
func llmAutoWritesOf(t *testing.T, id int64) []any {
	t.Helper()
	got, ok := runAutomationsJSON(t, "show", idArg(id))["llm_auto_writes"].([]any)
	require.True(t, ok, "llm_auto_writes is an array, never null")
	return got
}

// show --json's llm_auto_writes names the External tools with an auto grant
// (paused ones too) when the recipe feeds its sources to llm() (#559): the
// confirmation sheet warns about them.
func TestAutomationsCLI_ShowLLMAutoWrites(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "llmsend", llmSendRecipe(defaultGrantRecipe()))
	for _, tool := range []string{"send_slack_message", "create_idea"} {
		out, err := runAutomations(t, "auto", idArg(a.ID), tool, "on", "--hash", a.ApprovalHash)
		require.NoError(t, err, out)
	}
	assert.Equal(t, []any{"send_slack_message"}, llmAutoWritesOf(t, a.ID), "the local create_idea is not External")

	edited := defaultGrantRecipe()
	edited.script = "return 2"
	writeRecipe(t, c.personal, "llmsend", llmSendRecipe(edited))
	out, err := runAutomations(t, "rescan")
	require.NoError(t, err, out)
	assert.Equal(t, map[string]bool{"send_slack_message": false, "create_idea": false},
		grantsOf(t, runAutomationsJSON(t, "show", idArg(a.ID))), "the edit paused both grants")
	assert.Equal(t, []any{"send_slack_message"}, llmAutoWritesOf(t, a.ID), "a paused grant still warns")
}

// Without an llm: entry, or without an External grant, nothing is listed.
func TestAutomationsCLI_ShowLLMAutoWritesNeedsLLMAndExternalGrant(t *testing.T) {
	c := newAutoCLI(t)
	noLLM := c.confirmedRecipe(t, "nollm",
		strings.Replace(defaultGrantRecipe().text(), "  - ideas:write\n", "  - ideas:write\n  - slack:write@*\n", 1))
	out, err := runAutomations(t, "auto", idArg(noLLM.ID), "send_slack_message", "on", "--hash", noLLM.ApprovalHash)
	require.NoError(t, err, out)
	assert.Empty(t, llmAutoWritesOf(t, noLLM.ID), "no llm: entry")

	noGrant := c.confirmedRecipe(t, "nogrant", llmSendRecipe(defaultGrantRecipe()))
	assert.Empty(t, llmAutoWritesOf(t, noGrant.ID), "no grant")

	broken := c.indexRecipe(t, "broken", "broken")
	assert.Empty(t, automationLLMAutoWrites(tools.New(c.d), broken, nil), "a parse-error row lists nothing")
}

// An AlwaysAsk write the manifest admits is listed with always_asks, so the
// form shows it as "Always asks" instead of a toggle the CLI refuses (D14).
// No AlwaysAsk tool is on the automation surface today, so a stub stands in.
func TestAutomationsCLI_AutoToolsMarkAlwaysAsk(t *testing.T) {
	c := newAutoCLI(t)
	text := strings.Replace(defaultGrantRecipe().text(), "  - ideas:write\n", "  - ideas:write\n  - tool:bulk_stub\n", 1)
	a := c.indexRecipe(t, "stub", text)
	reg := tools.New(c.d)
	schema, err := jsonschema.For[struct{}](nil)
	require.NoError(t, err)
	stub := func(name string, alwaysAsk bool, access tools.Access) *tools.Tool {
		return &tools.Tool{
			Name: name, InputSchema: schema, Access: access, AlwaysAsk: alwaysAsk,
			Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
			Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { return nil, nil },
		}
	}
	require.NoError(t, reg.Register(stub("bulk_stub", true, tools.AccessWrite)))
	require.NoError(t, reg.Register(stub("create_idea", false, tools.AccessWrite)))
	require.NoError(t, reg.Register(stub("other_stub", false, tools.AccessWrite)))
	assert.Equal(t, []automationAutoToolJSON{
		{Tool: "bulk_stub", AlwaysAsks: true},
		{Tool: "create_idea", AlwaysAsks: false},
	}, automationAutoTools(reg, a))
}
