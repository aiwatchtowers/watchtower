package cmd

import (
	"encoding/json"
	"io"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// previewRecipe is a manual recipe making one llm() call and one feed
// Inbox card with a markdown body.
const previewRecipe = "---\nname: Preview test\ntrigger:\n  manual: true\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n" +
	"A preview test recipe.\n\n```js\nvar s = llm(\"x\");\noutput.inbox({title: \"Threads\", body: s});\nreturn 1\n```\n"

// readSpy is a stdin that records whether anything read it.
type readSpy struct{ read bool }

func (r *readSpy) Read([]byte) (int, error) {
	r.read = true
	return 0, io.EOF
}

// TestAutomationsCLI_PreviewRefusedUnderAgentMarkers pins AUTO-06 (ask
// #445): the owner preview is refused under every AGENT-07 marker —
// WATCHTOWER_AUTOMATION_RUN_ID included — before stdin is read.
func TestAutomationsCLI_PreviewRefusedUnderAgentMarkers(t *testing.T) {
	require.Contains(t, agentEnvMarkers, automations.RunEnvMarker)
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			t.Setenv(marker, "1")
			spy := &readSpy{}
			rootCmd.SetIn(spy)
			defer rootCmd.SetIn(nil)
			_, err := runAutomations(t, "preview", "--stdin", "--json")
			require.ErrorContains(t, err, "refusing to dry-run a recipe preview under an AI agent ("+marker+" is set)")
			assert.False(t, spy.read, "stdin read before the refusal")
			assert.Zero(t, c.gen.CallCount())
		})
	}
}

// allTableCounts is the row count of every table in the database.
func allTableCounts(t *testing.T, d *db.DB) map[string]int {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	out := make(map[string]int, len(names))
	for _, n := range names {
		var c int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM "`+n+`"`).Scan(&c), n)
		out[n] = c
	}
	return out
}

// TestAutomationsCLI_PreviewWritesNoRows pins AUTO-12 (ask #445): the
// preview is a dry run in memory — llm() runs (faked), no row of any table
// changes, the draft cache included.
func TestAutomationsCLI_PreviewWritesNoRows(t *testing.T) {
	c := newAutoCLI(t)
	before := allTableCounts(t, c.d)
	require.NotEmpty(t, before)

	out, err := runAutomationsWithStdin(t, previewRecipe, "preview", "--stdin", "--json")
	require.NoError(t, err, out)
	var res map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	require.Equal(t, true, res["ok"], out)
	dry := res["dry_run"].(map[string]any)
	assert.Equal(t, db.RunSucceeded, dry["status"])
	assert.Equal(t, 1, c.gen.CallCount())
	assert.Equal(t, before, allTableCounts(t, c.d))
}

// TestAutomationsCLI_PreviewPinnedKeys pins `preview --json`'s key set —
// draft_automation's DraftResult — with blocks null for a markdown output
// (the wire-shape rule: present, never omitted).
func TestAutomationsCLI_PreviewPinnedKeys(t *testing.T) {
	newAutoCLI(t)
	out, err := runAutomationsWithStdin(t, previewRecipe, "preview", "--stdin", "--json")
	require.NoError(t, err, out)
	var res map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, []string{"dry_run", "errors", "manifest", "ok", "widening"}, previewKeys(res))

	var manifest map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(res["manifest"], &manifest))
	assert.Equal(t, []string{"approval_hash", "budget_minutes", "budget_tokens", "name", "outputs", "permissions",
		"scope", "slug", "trigger", "trigger_kind"}, previewKeys(manifest))

	var dry struct {
		Steps   []map[string]json.RawMessage `json:"steps"`
		Outputs []map[string]json.RawMessage `json:"outputs"`
	}
	require.NoError(t, json.Unmarshal(res["dry_run"], &dry))
	var dryKeys map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(res["dry_run"], &dryKeys))
	assert.Equal(t, []string{"error", "outputs", "status", "steps", "tokens"}, previewKeys(dryKeys))
	require.NotEmpty(t, dry.Steps)
	assert.Equal(t, []string{"args", "error", "kind", "name", "permission", "result", "seq", "status", "tokens"},
		previewKeys(dry.Steps[0]))
	require.Len(t, dry.Outputs, 1)
	assert.Equal(t, []string{"blocks", "body", "content_hash", "key", "kind", "priority", "title"}, previewKeys(dry.Outputs[0]))
	assert.Equal(t, "null", string(dry.Outputs[0]["blocks"]))
	assert.Equal(t, `""`, string(dry.Outputs[0]["key"]))
}

func previewKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// TestAutomationsCLI_PreviewParseError: a recipe that does not parse is
// ok: false with its error and dry_run null, exit 0.
func TestAutomationsCLI_PreviewParseError(t *testing.T) {
	c := newAutoCLI(t)
	out, err := runAutomationsWithStdin(t, "not a recipe", "preview", "--stdin", "--json")
	require.NoError(t, err, out)
	var res map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, "false", string(res["ok"]))
	assert.Equal(t, "null", string(res["dry_run"]))
	assert.NotEqual(t, "[]", string(res["errors"]))
	assert.Zero(t, c.gen.CallCount())
}

// TestAutomationsCLI_PreviewUsage: empty stdin, or no --stdin / --json, is
// refused with the usage line.
func TestAutomationsCLI_PreviewUsage(t *testing.T) {
	newAutoCLI(t)
	for _, tc := range []struct {
		name, in string
		args     []string
	}{
		{"empty stdin", "", []string{"--stdin", "--json"}},
		{"blank stdin", " \n\t", []string{"--stdin", "--json"}},
		{"no --stdin", previewRecipe, []string{"--json"}},
		{"no --json", previewRecipe, []string{"--stdin"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out, err := runAutomationsWithStdin(t, tc.in, append([]string{"preview"}, tc.args...)...)
			require.ErrorContains(t, err, previewUsage, out)
			assert.Empty(t, strings.TrimSpace(out))
		})
	}
}

// TestAutomationsCLI_PreviewDryRunsUnconfirmedRecipe: the owner's preview
// dry-runs the text of an indexed recipe not confirmed yet (D16 guards the
// chat path only), against its slug.
func TestAutomationsCLI_PreviewDryRunsUnconfirmedRecipe(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "threads", previewRecipe)
	require.NotEqual(t, a.ApprovalHash, a.ConfirmedHash)
	out, err := runAutomationsWithStdin(t, previewRecipe, "preview", "--stdin", "--json", "--slug", "threads")
	require.NoError(t, err, out)
	var res struct {
		Manifest struct {
			Slug string `json:"slug"`
		} `json:"manifest"`
		DryRun struct {
			Status string `json:"status"`
		} `json:"dry_run"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, "threads", res.Manifest.Slug)
	assert.Equal(t, db.RunSucceeded, res.DryRun.Status)
}

// TestAutomationsCLI_PreviewUnknownBuiltin: a --builtin naming no built-in
// is an error, not a result.
func TestAutomationsCLI_PreviewUnknownBuiltin(t *testing.T) {
	newAutoCLI(t)
	_, err := runAutomationsWithStdin(t, previewRecipe, "preview", "--stdin", "--json", "--builtin", "no-such")
	require.ErrorContains(t, err, `there is no built-in "no-such"`)
}
