package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/authoring"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// autoCLI is a temp workspace for the automations CLI tests: a fresh
// database under a temp HOME with every AGENT-07 marker unset, the personal
// recipe folder, and a FakeGenerator behind the dry-run generator seam.
type autoCLI struct {
	d        *db.DB
	personal string
	gen      *automationstest.FakeGenerator
}

func newAutoCLI(t *testing.T) *autoCLI {
	t.Helper()
	d := writeActionsConfig(t)
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	gen := &automationstest.FakeGenerator{Replies: []string{"done"}, Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}}}
	orig := automationsDryRunGenerator
	automationsDryRunGenerator = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { automationsDryRunGenerator = orig })
	personal := automations.PersonalDir(cfg.WorkspaceDir())
	require.NoError(t, os.MkdirAll(personal, 0o755))
	return &autoCLI{d: d, personal: personal, gen: gen}
}

func runAutomations(t *testing.T, args ...string) (string, error) {
	t.Helper()
	// stdout only: --json output must decode on its own, as the Desktop reads
	// it; notes and warnings go to stderr.
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"automations"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	autoFlags = automationsFlags{}
	for _, c := range automationsCmd.Commands() {
		c.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	}
	return out.String(), err
}

// runAutomationsJSON runs a --json command and decodes its output.
func runAutomationsJSON(t *testing.T, args ...string) map[string]any {
	t.Helper()
	out, err := runAutomations(t, append(args, "--json")...)
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

const autoCLIRecipe = "---\nname: CLI test\ntrigger:\n  manual: true\npermissions:\n  - llm:light\noutputs: [report]\n---\n" +
	"A CLI test recipe.\n\n```js\nSCRIPT\n```\n"

func autoCLIRecipeText(script string) string {
	return strings.Replace(autoCLIRecipe, "SCRIPT", script, 1)
}

// writeRecipe writes slug.md into dir and returns its path.
func writeRecipe(t *testing.T, dir, slug, text string) string {
	t.Helper()
	path := filepath.Join(dir, slug+".md")
	require.NoError(t, os.WriteFile(path, []byte(text), 0o644))
	return path
}

// indexRecipe writes a personal recipe, rescans and returns its row.
func (c *autoCLI) indexRecipe(t *testing.T, slug, text string) *db.Automation {
	t.Helper()
	writeRecipe(t, c.personal, slug, text)
	out, err := runAutomations(t, "rescan")
	require.NoError(t, err, out)
	a, err := c.d.GetAutomationBySlug("personal", 0, slug)
	require.NoError(t, err)
	return a
}

// confirmedRecipe indexes, confirms and enables a personal recipe.
func (c *autoCLI) confirmedRecipe(t *testing.T, slug, text string) *db.Automation {
	t.Helper()
	a := c.indexRecipe(t, slug, text)
	id := strconv.FormatInt(a.ID, 10)
	out, err := runAutomations(t, "confirm", id, "--hash", a.ApprovalHash)
	require.NoError(t, err, out)
	out, err = runAutomations(t, "enable", id)
	require.NoError(t, err, out)
	a, err = c.d.GetAutomation(a.ID)
	require.NoError(t, err)
	return a
}

func (c *autoCLI) runs(t *testing.T, automationID int64) []db.AutomationRun {
	t.Helper()
	runs, err := c.d.ListAutomationRuns(automationID, 0)
	require.NoError(t, err)
	return runs
}

func idArg(id int64) string { return strconv.FormatInt(id, 10) }

func automationJSONKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func wantKeys(t *testing.T, m map[string]any, want ...string) {
	t.Helper()
	slices.Sort(want)
	assert.Equal(t, want, automationJSONKeys(m))
}

func TestAutomationsCLI_ValidateReportsErrorsWithoutWriting(t *testing.T) {
	c := newAutoCLI(t)
	broken := writeRecipe(t, t.TempDir(), "broken", "---\ntrigger:\n  manual: true\n---\n```js\nreturn 1\n```\n")
	out, err := runAutomations(t, "validate", broken)
	require.Error(t, err, out)
	assert.Contains(t, err.Error(), `"name" is required`)

	good := writeRecipe(t, t.TempDir(), "good", autoCLIRecipeText(`return 1`))
	out, err = runAutomations(t, "validate", good)
	require.NoError(t, err, out)
	assert.Contains(t, out, "ok")

	rows, err := c.d.ListAutomations(db.AutomationFilter{IncludeRemoved: true})
	require.NoError(t, err)
	assert.Empty(t, rows, "validate writes no index row")
}

func TestAutomationsCLI_ValidateParseErrorIsOkFalse(t *testing.T) {
	newAutoCLI(t)
	broken := writeRecipe(t, t.TempDir(), "broken", "not a recipe")
	v := runAutomationsJSON(t, "validate", broken)
	assert.Equal(t, false, v["ok"])
	assert.NotEmpty(t, v["errors"])
	_, err := runAutomations(t, "validate", broken)
	require.Error(t, err, "without --json a parse error exits non-zero")
	_, err = runAutomations(t, "validate", filepath.Join(t.TempDir(), "missing.md"), "--json")
	require.Error(t, err, "a missing file is a usage error even with --json")
}

func TestAutomationsCLI_RescanListShow(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))

	out, err := runAutomations(t, "list", "--json")
	require.NoError(t, err, out)
	var items []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &items), out)
	require.Len(t, items, 1)
	assert.Equal(t, "digest", items[0]["slug"])
	assert.Equal(t, true, items[0]["needs_confirmation"])
	assert.Equal(t, false, items[0]["runnable"])

	show := runAutomationsJSON(t, "show", "digest")
	assert.Equal(t, float64(a.ID), show["id"])
	assert.Equal(t, true, show["needs_confirmation"])
	assert.Equal(t, "return 1", strings.TrimSpace(show["script"].(string)))
	assert.Equal(t, "A CLI test recipe.", show["description"])
	assert.Equal(t, []any{"llm:light"}, show["widening"], "an unconfirmed recipe widens by every permission")

	c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	show = runAutomationsJSON(t, "show", idArg(a.ID))
	assert.Equal(t, true, show["runnable"])
	assert.Equal(t, []any{}, show["widening"])
	out, err = runAutomations(t, "list")
	require.NoError(t, err, out)
	assert.Contains(t, out, "digest")
}

func TestAutomationsCLI_ConfirmRefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
			t.Setenv(marker, "1")
			_, err := runAutomations(t, "confirm", idArg(a.ID), "--hash", a.ApprovalHash)
			require.Error(t, err)
			assert.Contains(t, err.Error(), marker)
			assert.Contains(t, err.Error(), "the owner decides in Watchtower Desktop (or runs this from a plain Terminal)")
			row, err := c.d.GetAutomation(a.ID)
			require.NoError(t, err)
			assert.Empty(t, row.ConfirmedHash, "nothing confirmed under %s", marker)
		})
	}
	t.Run("owner", func(t *testing.T) {
		c := newAutoCLI(t)
		a := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
		_, err := runAutomations(t, "confirm", idArg(a.ID), "--hash", strings.Repeat("0", 64))
		require.ErrorIs(t, err, db.ErrHashMismatch, "a stale hash is refused")
		_, err = runAutomations(t, "confirm", idArg(a.ID))
		require.Error(t, err, "--hash is required")
		out, err := runAutomations(t, "confirm", idArg(a.ID), "--hash", a.ApprovalHash)
		require.NoError(t, err, out)
		row, err := c.d.GetAutomation(a.ID)
		require.NoError(t, err)
		assert.Equal(t, a.ApprovalHash, row.ConfirmedHash)
	})
}

// AGENT-07 (owner decision, ask #293): enable and delete are owner-only —
// refused under every agent marker before anything is read or written; the
// verbs that only reduce activity or run what the owner confirmed stay open.
func TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
			out, err := runAutomations(t, "disable", idArg(a.ID))
			require.NoError(t, err, out)
			t.Setenv(marker, "1")
			for _, verb := range []string{"enable", "delete"} {
				_, err := runAutomations(t, verb, idArg(a.ID))
				require.Error(t, err, verb)
				assert.Contains(t, err.Error(), marker)
				assert.Contains(t, err.Error(), ownerOnlyAutomationHint)
			}
			row, err := c.d.GetAutomation(a.ID)
			require.NoError(t, err, "the row is still there under %s", marker)
			assert.False(t, row.Enabled, "nothing enabled under %s", marker)
			assert.FileExists(t, a.Path, "the recipe file is still there")

			for _, verb := range []string{"enable", "delete"} {
				_, err = runAutomations(t, verb, "999999")
				require.ErrorContains(t, err, ownerOnlyAutomationHint, "%s refused before the id is looked up", verb)
			}
			c.assertOpenUnderAgent(t, a)
		})
	}
	t.Run("owner", func(t *testing.T) {
		c := newAutoCLI(t)
		a := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
		out, err := runAutomations(t, "enable", idArg(a.ID))
		require.NoError(t, err, out)
		row, err := c.d.GetAutomation(a.ID)
		require.NoError(t, err)
		assert.True(t, row.Enabled)
		out, err = runAutomations(t, "delete", idArg(a.ID))
		require.NoError(t, err, out)
		_, err = c.d.GetAutomation(a.ID)
		require.ErrorIs(t, err, db.ErrAutomationNotFound)
		assert.NoFileExists(t, a.Path)
	})
}

// assertOpenUnderAgent checks that disable, run (of a confirmed recipe) and
// rescan still work under the marker the caller set.
func (c *autoCLI) assertOpenUnderAgent(t *testing.T, a *db.Automation) {
	t.Helper()
	for _, args := range [][]string{{"disable", idArg(a.ID)}, {"rescan"}} {
		out, err := runAutomations(t, args...)
		require.NoError(t, err, "%v stays open: %s", args, out)
	}
	require.NoError(t, c.d.SetAutomationEnabled(a.ID, true, time.Now()))
	out, err := runAutomations(t, "run", idArg(a.ID))
	require.NoError(t, err, "run of a confirmed, enabled recipe stays open: %s", out)
}

func TestAutomationsCLI_SaveIsAtomicAndIndexes(t *testing.T) {
	c := newAutoCLI(t)
	src := writeRecipe(t, t.TempDir(), "draft", autoCLIRecipeText(`return 1`))
	target := filepath.Join(c.personal, "saved.md")
	v := runAutomationsJSON(t, "validate", src)
	saved := runAutomationsJSON(t, "save", "--file", src, "--path", target, "--confirm-hash", v["approval_hash"].(string))
	assert.Equal(t, true, saved["confirmed"])

	data, err := os.ReadFile(target)
	require.NoError(t, err)
	assert.Equal(t, autoCLIRecipeText(`return 1`), string(data))
	entries, err := os.ReadDir(c.personal)
	require.NoError(t, err)
	require.Len(t, entries, 1, "no temp file left beside the recipe")
	a, err := c.d.GetAutomationBySlug("personal", 0, "saved")
	require.NoError(t, err)
	assert.Equal(t, float64(a.ID), saved["automation_id"])
	assert.Equal(t, a.ApprovalHash, a.ConfirmedHash)

	_, err = runAutomations(t, "save", "--file", src, "--path", filepath.Join(c.personal, "stale.md"), "--confirm-hash", strings.Repeat("0", 64))
	require.ErrorIs(t, err, db.ErrHashMismatch)
	assert.NoFileExists(t, filepath.Join(c.personal, "stale.md"), "a wrong hash is refused before the write")
	_, err = runAutomations(t, "save", "--file", src, "--path", filepath.Join(t.TempDir(), "elsewhere.md"))
	require.Error(t, err, "a path outside the recipe folders is refused")

	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			t.Setenv(marker, "1")
			path := filepath.Join(c.personal, "agent.md")
			_, err := runAutomations(t, "save", "--file", src, "--path", path, "--confirm-hash", v["approval_hash"].(string))
			require.Error(t, err)
			assert.Contains(t, err.Error(), marker)
			assert.NoFileExists(t, path, "refused before the write")
		})
	}
}

func TestAuto09_RunCommandOnlyQueues(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
	out, err := runAutomations(t, "run", idArg(a.ID))
	require.NoError(t, err, out)
	assert.Contains(t, out, "daemon not running; the run starts when it does")
	runs := c.runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunQueued, runs[0].Status)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)

	again := runAutomationsJSON(t, "run", idArg(a.ID))
	assert.Equal(t, true, again["coalesced"])
	assert.Equal(t, float64(runs[0].ID), again["run_id"])
	assert.Equal(t, false, again["daemon_running"])
	assert.Len(t, c.runs(t, a.ID), 1)
	assert.Zero(t, c.gen.CallCount(), "run executes nothing")

	unconfirmed := c.indexRecipe(t, "fresh", autoCLIRecipeText(`return 1`))
	_, err = runAutomations(t, "run", idArg(unconfirmed.ID))
	require.Error(t, err, "an automation that is not runnable is not queued")
	assert.Empty(t, c.runs(t, unconfirmed.ID))
}

func TestAutomationsCLI_DryRunPrintsSteps(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
	out, err := runAutomations(t, "dry-run", idArg(a.ID))
	require.NoError(t, err, out)
	assert.Contains(t, out, "succeeded")
	assert.Contains(t, out, "llm")
	runs := c.runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerDryRun, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status)
	assert.Equal(t, 1, c.gen.CallCount())
}

func TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.indexRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
			confirmed := c.confirmedRecipe(t, "confirmed", autoCLIRecipeText(`llm("x"); return 2`))
			t.Setenv(marker, "1")
			for _, args := range [][]string{{"dry-run", idArg(a.ID)}, {"dry-run", "--file", a.Path}} {
				_, err := runAutomations(t, args...)
				require.Error(t, err, "%v", args)
				assert.Contains(t, err.Error(), marker)
				assert.Contains(t, err.Error(), dryRunUnconfirmedHint)
			}
			assert.Empty(t, c.runs(t, a.ID), "no run row")
			assert.Zero(t, c.gen.CallCount())

			out, err := runAutomations(t, "dry-run", idArg(confirmed.ID))
			require.NoError(t, err, "a confirmed recipe dry-runs under %s: %s", marker, out)
		})
	}
	t.Run("owner", func(t *testing.T) {
		c := newAutoCLI(t)
		a := c.indexRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
		res := runAutomationsJSON(t, "dry-run", "--file", a.Path)
		assert.Equal(t, db.RunSucceeded, res["status"])
		assert.Equal(t, 1, c.gen.CallCount())

		outside := writeRecipe(t, t.TempDir(), "outside", autoCLIRecipeText(`return 1`))
		_, err := runAutomations(t, "dry-run", "--file", outside)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "save it first")
		_, err = runAutomations(t, "dry-run")
		require.Error(t, err, "an id or --file is required")
	})
}

func TestAutomationsCLI_CancelAndDelete(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	run := runAutomationsJSON(t, "run", idArg(a.ID))
	runID := int64(run["run_id"].(float64))
	out, err := runAutomations(t, "cancel", idArg(runID))
	require.NoError(t, err, out)
	got, err := c.d.GetAutomationRun(runID)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, got.Status)
	out, err = runAutomations(t, "cancel", idArg(runID))
	require.NoError(t, err)
	assert.Contains(t, out, "already finished")

	active, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(active, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	_, err = runAutomations(t, "delete", idArg(a.ID))
	require.Error(t, err, "an automation with an active run is not deleted")
	assert.FileExists(t, a.Path)

	_, err = c.d.CancelAutomationRun(active, time.Now())
	require.NoError(t, err)
	out, err = runAutomations(t, "delete", idArg(a.ID))
	require.NoError(t, err, out)
	assert.NoFileExists(t, a.Path)
	_, err = c.d.GetAutomation(a.ID)
	require.ErrorIs(t, err, db.ErrAutomationNotFound)
	_, err = c.d.GetAutomationRun(runID)
	require.ErrorIs(t, err, db.ErrAutomationRunNotFound, "history cascades")
}

func TestAutomationsCLI_WakeWithoutDaemon(t *testing.T) {
	newAutoCLI(t)
	out, err := runAutomations(t, "wake")
	require.NoError(t, err)
	assert.Contains(t, out, "daemon not running")
}

func TestAutomationsCLI_ShowJSONKeys(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	wantKeys(t, runAutomationsJSON(t, "show", idArg(a.ID)), "id", "slug", "scope", "project_id", "path", "name",
		"description", "script", "recipe_text", "trigger_kind", "trigger_spec", "permissions", "outputs",
		"budget_tokens", "budget_minutes", "concurrency", "missed_policy", "pause_timeout_hours", "enabled",
		"runnable", "needs_confirmation", "parse_error", "content_hash", "approval_hash", "confirmed_hash", "widening", "grants",
		"changes", "changes_known", "changed_by", "changed_at", "auto_tools")
}

func TestAutomationsCLI_ValidateJSONKeys(t *testing.T) {
	newAutoCLI(t)
	for _, text := range []string{autoCLIRecipeText(`return 1`), "broken"} {
		path := writeRecipe(t, t.TempDir(), "digest", text)
		wantKeys(t, runAutomationsJSON(t, "validate", path), "ok", "errors", "slug", "name", "scope",
			"approval_hash", "content_hash", "permissions", "outputs", "widening")
	}
}

func TestAutomationsCLI_RunJSONKeys(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	wantKeys(t, runAutomationsJSON(t, "run", idArg(a.ID)), "run_id", "coalesced", "daemon_running")
}

func TestAutomationsCLI_DryRunJSONKeys(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	for _, args := range [][]string{{"dry-run", idArg(a.ID)}, {"dry-run", "--file", a.Path}} {
		wantKeys(t, runAutomationsJSON(t, args...), "run_id", "status", "error", "input_tokens", "output_tokens")
	}
}

func TestAutomationsCLI_SaveJSONKeys(t *testing.T) {
	c := newAutoCLI(t)
	src := writeRecipe(t, t.TempDir(), "digest", autoCLIRecipeText(`return 1`))
	wantKeys(t, runAutomationsJSON(t, "save", "--file", src, "--path", filepath.Join(c.personal, "digest.md")),
		"automation_id", "path", "approval_hash", "confirmed")
}

func TestAutomationsCLI_JSONEmptyArraysNotNull(t *testing.T) {
	c := newAutoCLI(t)
	bare := "---\nname: Bare\ntrigger:\n  manual: true\n---\n```js\nreturn 1\n```\n"
	a := c.indexRecipe(t, "bare", bare)
	show := runAutomationsJSON(t, "show", idArg(a.ID))
	v := runAutomationsJSON(t, "validate", a.Path)
	for _, k := range []string{"permissions", "outputs", "widening"} {
		assert.Equal(t, []any{}, show[k], "show %s", k)
		assert.Equal(t, []any{}, v[k], "validate %s", k)
	}
	assert.Equal(t, []any{}, v["errors"])

	broken := c.indexRecipe(t, "broken", "broken")
	show = runAutomationsJSON(t, "show", idArg(broken.ID))
	for _, k := range []string{"permissions", "outputs", "widening"} {
		assert.Equal(t, []any{}, show[k], "show of a parse-error recipe: %s", k)
	}
	out, err := runAutomations(t, "outputs", "--json")
	require.NoError(t, err)
	assert.Equal(t, "[]\n", out)
}

// D16 TOCTOU: a rescan that changes the recipe between the dry run's gate and
// its claim cancels the run — under a marker nothing the owner never
// confirmed runs.
func TestAutomationsCLI_DryRunRecipeChangedBeforeClaimRefused(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
			orig := automationsBeforeDryRunClaim
			automationsBeforeDryRunClaim = func() {
				writeRecipe(t, c.personal, "digest", autoCLIRecipeText(`llm("x"); llm("y"); return 2`))
				ix := automations.NewIndexer(c.d, t.TempDir(), automations.RealClock{})
				_, err := ix.RescanFolder(t.Context(), automations.Scope{Kind: automations.ScopePersonal}, c.personal)
				require.NoError(t, err)
			}
			t.Cleanup(func() { automationsBeforeDryRunClaim = orig })
			t.Setenv(marker, "1")

			_, err := runAutomations(t, "dry-run", idArg(a.ID))
			require.ErrorIs(t, err, automations.ErrRecipeChanged)
			assert.Zero(t, c.gen.CallCount(), "nothing ran")
			runs := c.runs(t, a.ID)
			require.Len(t, runs, 1)
			assert.Equal(t, db.RunCancelled, runs[0].Status)
		})
	}
}

// An all-digit argument names the recipe with that slug first, then an id.
func TestAutomationsCLI_ShowResolvesSlugBeforeID(t *testing.T) {
	c := newAutoCLI(t)
	first := c.indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	numeric := c.indexRecipe(t, idArg(first.ID), autoCLIRecipeText(`return 2`))
	require.NotEqual(t, first.ID, numeric.ID)

	assert.Equal(t, float64(numeric.ID), runAutomationsJSON(t, "show", idArg(first.ID))["id"], "slug wins")
	assert.Equal(t, float64(first.ID), runAutomationsJSON(t, "show", "digest")["id"])
	assert.Equal(t, float64(numeric.ID), runAutomationsJSON(t, "show", idArg(numeric.ID))["id"], "no such slug: the id")
	_, err := runAutomations(t, "show", "999")
	require.ErrorIs(t, err, db.ErrAutomationNotFound)
}

func TestAutomationsCLI_RunsStepsOutputsJSONKeys(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`llm("x"); return 1`))
	dry := runAutomationsJSON(t, "dry-run", idArg(a.ID))
	runID := int64(dry["run_id"].(float64))
	committed, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(committed, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, c.d.FinishAutomationRun(committed, db.RunFinish{Status: db.RunSucceeded, Now: time.Now()},
		&db.RunCommit{Outputs: []db.AutomationOutput{{Kind: "report", Title: "t", Body: "b"}}}))

	rows := runAutomationsJSONList(t, "runs", idArg(a.ID))
	require.Len(t, rows, 2)
	wantKeys(t, rows[0], "id", "automation_id", "trigger", "scheduled_for", "event_cycle", "rerun_of", "status",
		"waiting_reason", "recipe_hash", "budget_tokens", "budget_minutes", "input_tokens", "output_tokens",
		"tokens_estimated", "reported_cost_usd", "active_ms", "error", "error_kind", "summary", "queued_at",
		"started_at", "finished_at")
	steps := runAutomationsJSONList(t, "steps", idArg(runID))
	require.NotEmpty(t, steps)
	wantKeys(t, steps[0], "id", "run_id", "seq", "kind", "name", "args_json", "result_summary", "status", "auto",
		"permission", "action_id", "ask_id", "session_id", "input_tokens", "output_tokens", "tokens_estimated",
		"reported_cost_usd", "duration_ms", "error", "started_at", "finished_at")
	outs := runAutomationsJSONList(t, "outputs")
	require.Len(t, outs, 1)
	wantKeys(t, outs[0], "id", "automation_id", "run_id", "kind", "title", "body", "priority", "created_at",
		"read_at", "dismissed_at")

	fresh := c.indexRecipe(t, "fresh", autoCLIRecipeText(`return 1`))
	for _, args := range [][]string{{"runs", idArg(fresh.ID)}, {"steps", idArg(committed)}} {
		out, err := runAutomations(t, append(args, "--json")...)
		require.NoError(t, err)
		assert.Equal(t, "[]\n", out, "%v: an empty list is [], never null", args)
	}
}

func runAutomationsJSONList(t *testing.T, args ...string) []map[string]any {
	t.Helper()
	out, err := runAutomations(t, append(args, "--json")...)
	require.NoError(t, err, out)
	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &rows), out)
	return rows
}

// writeDaemonPID makes this test process look like the running daemon, with
// or without the automation wake capability.
func writeDaemonPID(t *testing.T, capable bool) {
	t.Helper()
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	pidPath := pidFilePath(cfg)
	// The legacy pid-only form: the identity check would otherwise refuse a
	// process not named watchtower (this test binary).
	require.NoError(t, os.MkdirAll(filepath.Dir(pidPath), 0o700))
	require.NoError(t, os.WriteFile(pidPath, []byte(idArg(int64(os.Getpid()))), 0o600))
	t.Cleanup(func() { daemon.RemovePID(pidPath) })
	if capable {
		body := idArg(int64(os.Getpid())) + "\n" + daemon.AutomationWakeCapability + "\n"
		require.NoError(t, os.WriteFile(daemon.CapsPath(pidPath), []byte(body), 0o600))
		t.Cleanup(func() { _ = os.Remove(daemon.CapsPath(pidPath)) })
	}
}

// A daemon that does not advertise the wake (older, or started with
// automations off) is never signalled; the owner is told to restart it.
func TestAutomationsCLI_WakeSkipsDaemonWithoutCapability(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	writeDaemonPID(t, false)
	got := make(chan os.Signal, 1)
	signal.Notify(got, daemon.AutomationWakeSignal)
	t.Cleanup(func() { signal.Stop(got) })

	out, err := runAutomations(t, "wake")
	require.NoError(t, err)
	assert.Contains(t, out, "the running daemon is older, or was started with automations off, and can't be woken; restart it")
	out, err = runAutomations(t, "run", idArg(a.ID))
	require.NoError(t, err)
	assert.Contains(t, out, "the run starts on its next poll")
	assert.Len(t, c.runs(t, a.ID), 1, "the run is queued all the same")
	select {
	case <-got:
		t.Fatal("SIGUSR2 sent to a daemon that does not advertise it")
	case <-time.After(200 * time.Millisecond):
	}
}

func TestAutomationsCLI_WakeSignalsCapableDaemon(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	writeDaemonPID(t, true)
	got := make(chan os.Signal, 1)
	signal.Notify(got, daemon.AutomationWakeSignal)
	t.Cleanup(func() { signal.Stop(got) })

	res := runAutomationsJSON(t, "run", idArg(a.ID))
	assert.Equal(t, true, res["daemon_running"])
	select {
	case <-got:
	case <-time.After(5 * time.Second):
		t.Fatal("no SIGUSR2 reached the capable daemon")
	}
}

// turnAutomationsOff writes automations.enabled=false into the test config.
func turnAutomationsOff(t *testing.T) {
	t.Helper()
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	_, err = f.WriteString("automations:\n  enabled: false\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())
}

// With automations off no executor would claim a run, and turning them on
// cancels what was queued: run refuses and queues nothing, wake says why it
// woke nothing, cancel still cancels — and none of them signals the daemon.
func TestAutomationsCLI_FeatureOffRefusesRunAndSkipsWake(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	queued, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	turnAutomationsOff(t)
	writeDaemonPID(t, true)
	got := make(chan os.Signal, 1)
	signal.Notify(got, daemon.AutomationWakeSignal)
	t.Cleanup(func() { signal.Stop(got) })

	_, err = runAutomations(t, "run", idArg(a.ID))
	require.ErrorContains(t, err, "automations are turned off in Settings → Features")
	assert.Len(t, c.runs(t, a.ID), 1, "run queues nothing while automations are off")

	out, err := runAutomations(t, "wake")
	require.NoError(t, err)
	assert.Contains(t, out, "automations are turned off in Settings → Features")
	assert.Contains(t, out, "cancelled when you turn them on")

	out, err = runAutomations(t, "cancel", idArg(queued))
	require.NoError(t, err, out)
	assert.Contains(t, out, "cancelled")
	run, err := c.d.GetAutomationRun(queued)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)

	select {
	case <-got:
		t.Fatal("SIGUSR2 sent while automations are off")
	case <-time.After(200 * time.Millisecond):
	}
}

// guardWorkbenchFolder binds a workbench to a folder under the fake HOME's
// Documents that does not exist and fails the test if the CLI canonicalises
// anything inside it: a command about another folder must never touch a
// workbench folder (TCC: ~/Documents asks the user before an app reads it).
func guardWorkbenchFolder(t *testing.T, d *db.DB) string {
	t.Helper()
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	folder := filepath.Join(home, "Documents", "acme")
	_, err = d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	orig := automationsCanonicalDir
	automationsCanonicalDir = func(dir string) (string, error) {
		if dir == folder || strings.HasPrefix(dir, folder+string(filepath.Separator)) {
			t.Errorf("canonicalised %s inside a workbench folder the command is not about", dir)
		}
		return orig(dir)
	}
	t.Cleanup(func() { automationsCanonicalDir = orig })
	return folder
}

func TestAutomationsCLI_PersonalCommandsNeverTouchWorkbenchFolders(t *testing.T) {
	c := newAutoCLI(t)
	folder := guardWorkbenchFolder(t, c.d)
	src := writeRecipe(t, t.TempDir(), "draft", autoCLIRecipeText(`llm("x"); return 1`))

	saved := runAutomationsJSON(t, "save", "--file", src, "--path", filepath.Join(c.personal, "saved.md"))
	id := int64(saved["automation_id"].(float64))
	_, err := runAutomations(t, "save", "--file", src, "--path", filepath.Join(t.TempDir(), "elsewhere.md"))
	require.Error(t, err, "a path outside the recipe folders is refused")

	a, err := c.d.GetAutomation(id)
	require.NoError(t, err)
	out, err := runAutomations(t, "confirm", idArg(id), "--hash", a.ApprovalHash)
	require.NoError(t, err, out)
	out, err = runAutomations(t, "dry-run", "--file", filepath.Join(c.personal, "saved.md"))
	require.NoError(t, err, out)
	assert.Contains(t, out, "succeeded")

	out, err = runAutomations(t, "delete", idArg(id))
	require.NoError(t, err, out)
	assert.NoFileExists(t, a.Path)
	assert.NoDirExists(t, folder, "nothing created the workbench folder")
}

// A recipe saved into a workbench's folder is matched to that workbench by
// its path; the other (guarded) workbench folder is never touched, and
// delete removes the file through the automation's own scope.
func TestAutomationsCLI_SaveAndDeleteInWorkbenchFolder(t *testing.T) {
	c := newAutoCLI(t)
	guardWorkbenchFolder(t, c.d)
	folder, err := filepath.EvalSymlinks(t.TempDir()) // stored resolved, as ResolveWorkbenchFolder does
	require.NoError(t, err)
	wbID, err := c.d.CreateWorkbench("beta", folder)
	require.NoError(t, err)
	src := writeRecipe(t, t.TempDir(), "draft", autoCLIRecipeText(`return 1`))
	target := filepath.Join(automations.WorkbenchDir(folder), "wb.md")

	saved := runAutomationsJSON(t, "save", "--file", src, "--path", target)
	assert.FileExists(t, target)
	a, err := c.d.GetAutomation(int64(saved["automation_id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, string(automations.ScopeWorkbench), a.Scope)
	assert.Equal(t, wbID, a.ProjectID)

	out, err := runAutomations(t, "delete", idArg(a.ID))
	require.NoError(t, err, out)
	assert.NoFileExists(t, target)
}

// PROJ-03 (amended, ask #272): in a workbench folder, save writes only
// <folder>/.watchtower/automations/<slug>.md — any other path of the folder
// is refused before anything is written.
func TestAutomationsCLI_SavePathOutsideWorkbenchAutomationsRefused(t *testing.T) {
	c := newAutoCLI(t)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	_, err = c.d.CreateWorkbench("beta", folder)
	require.NoError(t, err)
	src := writeRecipe(t, t.TempDir(), "draft", autoCLIRecipeText(`return 1`))
	for _, rel := range []string{
		filepath.Join("src", "x.md"),
		"x.md",
		filepath.Join(".watchtower", "x.md"),
		filepath.Join(".watchtower", "automations", "nested", "x.md"),
	} {
		target := filepath.Join(folder, rel)
		out, err := runAutomations(t, "save", "--file", src, "--path", target, "--json")
		require.Error(t, err, "save --path %s: %s", rel, out)
		assert.Contains(t, err.Error(), "cannot save to")
		assert.NoFileExists(t, target)
	}
	entries, err := os.ReadDir(folder)
	require.NoError(t, err)
	assert.Empty(t, entries, "nothing was written in the workbench folder")
	rows, err := c.d.ListAutomations(db.AutomationFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

// autoCLIRecipeWith is a recipe with the given trigger block (indented
// lines), one permission and a token budget.
func autoCLIRecipeWith(trigger, perm string, tokens int) string {
	return "---\nname: CLI test\ntrigger:\n" + trigger + "\npermissions:\n  - " + perm +
		"\noutputs: [report]\nbudget:\n  tokens: " + strconv.Itoa(tokens) + "\n  minutes: 5\n---\n" +
		"A CLI test recipe.\n\n```js\nreturn 1\n```\n"
}

const (
	weekdayCron = `  schedule: "0 9 * * 1-5"`
	dailyCron   = `  schedule: "30 8 * * *"`
)

func TestAutomationsCLI_ValidateAgainstComputesWidening(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "pay", autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000))
	src := writeRecipe(t, t.TempDir(), "pay", autoCLIRecipeWith(weekdayCron, "jira:read@*", 1000))

	v := runAutomationsJSON(t, "validate", src, "--against", idArg(a.ID))
	assert.Equal(t, true, v["ok"])
	assert.Equal(t, []any{"jira:read@*"}, v["widening"])
	assert.Equal(t, "personal", v["scope"], "the scope comes from the automation")

	runAutomationsJSON(t, "save", "--file", src, "--path", a.Path)
	show := runAutomationsJSON(t, "show", idArg(a.ID))
	assert.Equal(t, show["approval_hash"], v["approval_hash"])

	_, err := runAutomations(t, "validate", src, "--against", idArg(a.ID), "--workbench", "1", "--json")
	require.Error(t, err, "--against and --workbench are mutually exclusive")
	_, err = runAutomations(t, "validate", src, "--against", "999999", "--json")
	require.ErrorIs(t, err, db.ErrAutomationNotFound)
}

func TestAutomationsCLI_ValidateAgainstEmptyWideningIsArray(t *testing.T) {
	c := newAutoCLI(t)
	text := autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000)
	a := c.confirmedRecipe(t, "pay", text)
	src := writeRecipe(t, t.TempDir(), "pay", strings.Replace(text, "tokens: 1000", "tokens: 2000", 1))
	out, err := runAutomations(t, "validate", src, "--against", idArg(a.ID), "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"widening": []`)
}

// --against widens from the confirmed permissions, not the current ones: a
// hand edit adds a permission, the owner then renames the recipe in the form,
// and the widening still lists the hand-added permission (J3).
func TestAutomationsCLI_ValidateAgainstWidensFromConfirmedPermissions(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "pay", autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000))
	handEdited := strings.Replace(autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000),
		"  - jira:read@PAY\noutputs: [report]", "  - jira:read@PAY\n  - slack:write@acme\noutputs: [report, slack]", 1)
	require.NotEqual(t, autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000), handEdited)
	c.runOnce(t, a, a.ApprovalHash) // the confirmed text is known from the run snapshot
	saveText(t, a, handEdited)

	renamed := writeRecipe(t, t.TempDir(), "pay", strings.Replace(handEdited, "name: CLI test", "name: Renamed", 1))
	v := runAutomationsJSON(t, "validate", renamed, "--against", idArg(a.ID))
	require.Equal(t, true, v["ok"], v["errors"])
	assert.Equal(t, []any{"slack:write@acme"}, v["widening"], "the hand-added permission is still new since the confirmation")
}

// --against an automation never confirmed (or with no known confirmed text)
// widens from nothing: every permission.
func TestAutomationsCLI_ValidateAgainstUnconfirmedWidensEverything(t *testing.T) {
	c := newAutoCLI(t)
	text := autoCLIRecipeWith(weekdayCron, "jira:read@PAY", 1000)
	a := c.indexRecipe(t, "pay", text)
	src := writeRecipe(t, t.TempDir(), "pay", strings.Replace(text, "tokens: 1000", "tokens: 2000", 1))
	v := runAutomationsJSON(t, "validate", src, "--against", idArg(a.ID))
	assert.Equal(t, []any{"jira:read@PAY"}, v["widening"])
}

func TestAutomationsCLI_SaveRefusesWhenFileChangedSinceLoad(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	loaded := a.ContentHash
	rewritten := autoCLIRecipeText(`return 2`)
	writeRecipe(t, c.personal, "digest", rewritten) // changed on disk after the Desktop loaded it
	src := writeRecipe(t, t.TempDir(), "digest", autoCLIRecipeText(`return 3`))
	v := runAutomationsJSON(t, "validate", src)

	_, err := runAutomations(t, "save", "--file", src, "--path", a.Path, "--confirm-hash", v["approval_hash"].(string),
		"--expect-content-hash", loaded, "--json")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "the recipe changed on disk since you opened it")
	data, err := os.ReadFile(a.Path)
	require.NoError(t, err)
	assert.Equal(t, rewritten, string(data), "the file keeps the rewritten bytes")
	row, err := c.d.GetAutomation(a.ID)
	require.NoError(t, err)
	assert.Equal(t, a.ConfirmedHash, row.ConfirmedHash, "nothing confirmed")

	_, err = runAutomations(t, "save", "--file", src, "--path", a.Path, "--expect-content-hash", "")
	require.ErrorContains(t, err, "the recipe changed on disk since you opened it", `"" means the file must not exist`)

	saved := runAutomationsJSON(t, "save", "--file", src, "--path", a.Path,
		"--expect-content-hash", automations.ContentHash([]byte(rewritten)))
	assert.Equal(t, float64(a.ID), saved["automation_id"], "the current hash saves")
	fresh := filepath.Join(c.personal, "fresh.md")
	runAutomationsJSON(t, "save", "--file", src, "--path", fresh, "--expect-content-hash", "")
	assert.FileExists(t, fresh, `"" saves a new file`)
}

// --expect-content-hash refuses, before anything is written, a symlink or a
// FIFO at the target — whatever hash was expected — and writes nothing
// through it.
func TestAutomationsCLI_SaveExpectContentHashRefusesSymlinkOrSpecialFile(t *testing.T) {
	c := newAutoCLI(t)
	text := autoCLIRecipeText(`return 1`)
	src := writeRecipe(t, t.TempDir(), "digest", text)
	outside := writeRecipe(t, t.TempDir(), "outside", text)
	plant := map[string]func(path string) error{
		"symlink": func(path string) error { return os.Symlink(outside, path) },
		"fifo":    func(path string) error { return syscall.Mkfifo(path, 0o644) },
	}
	for name, put := range plant {
		path := filepath.Join(c.personal, name+".md")
		require.NoError(t, put(path), name)
		for _, want := range []string{"", automations.ContentHash([]byte(text))} {
			_, err := runAutomations(t, "save", "--file", src, "--path", path, "--expect-content-hash", want)
			require.Error(t, err, "%s with expected hash %q", name, want)
			info, lerr := os.Lstat(path)
			require.NoError(t, lerr)
			assert.False(t, info.Mode().IsRegular(), "%s: the planted entry stays", name)
		}
	}
	data, err := os.ReadFile(outside)
	require.NoError(t, err)
	assert.Equal(t, text, string(data), "nothing written through the symlink")
}

// showChanges runs show --json and returns its Changed-block keys.
func showChanges(t *testing.T, id int64) (changes []any, known bool, changedBy string, changedAt any) {
	t.Helper()
	out, err := runAutomations(t, "show", idArg(id), "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	require.IsType(t, []any{}, m["changes"], "changes is always an array: %s", out)
	return m["changes"].([]any), m["changes_known"].(bool), m["changed_by"].(string), m["changed_at"]
}

func change(field, old, next string) map[string]any {
	return map[string]any{"field": field, "old": old, "new": next}
}

// runOnce records a finished run of a at its current approval hash and text.
func (c *autoCLI) runOnce(t *testing.T, a *db.Automation, hash string) {
	t.Helper()
	id, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(id, hash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, c.d.FinishAutomationRun(id, db.RunFinish{Status: db.RunSucceeded, Now: time.Now()}, nil))
}

// saveText saves text over a's recipe file with a plain `save`.
func saveText(t *testing.T, a *db.Automation, text string) {
	t.Helper()
	src := writeRecipe(t, t.TempDir(), a.Slug, text)
	runAutomationsJSON(t, "save", "--file", src, "--path", a.Path)
}

func TestAutomationsCLI_ShowChangesFromConfirmedSnapshot(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeWith(weekdayCron, "llm:light", 40000))
	changes, known, _, _ := showChanges(t, a.ID)
	assert.Equal(t, []any{}, changes, "confirmed: nothing changed")
	assert.True(t, known)

	c.runOnce(t, a, a.ApprovalHash)
	saveText(t, a, autoCLIRecipeWith(dailyCron, "llm:light", 20000))
	row, err := c.d.GetAutomation(a.ID)
	require.NoError(t, err)

	changes, known, by, at := showChanges(t, a.ID)
	assert.Equal(t, []any{
		change("trigger", `{"schedule":"0 9 * * 1-5"}`, `{"schedule":"30 8 * * *"}`),
		change("budget_tokens", "40000", "20000"),
	}, changes)
	assert.True(t, known)
	assert.Empty(t, by)
	assert.Equal(t, row.UpdatedAt.UTC().Format(time.RFC3339), at)
}

// assistantSave proposes, approves and applies a real save_automation of
// text at slug — the way the owner's Approve on the card does.
func (c *autoCLI) assistantSave(t *testing.T, slug, text string) {
	t.Helper()
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	deps := automationAuthoringDeps(cfg, c.d)
	deps.Enabled = func() bool { return true }
	reg := tools.New(c.d)
	require.NoError(t, reg.Register(authoring.NewSaveAutomation(deps)))
	raw, err := json.Marshal(map[string]any{"recipe_text": text, "slug": slug, "reason": "the owner asked"})
	require.NoError(t, err)
	rc, err := reg.Propose(t.Context(), "save_automation", raw, tools.Binding{Surface: "main"})
	require.NoError(t, err)
	ok, err := reg.Approve(t.Context(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	row, err := reg.Apply(t.Context(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
}

// An assistant save confirms its own recipe_text; a hand edit afterwards
// (no run in between) diffs against that text (J2).
func TestAutomationsCLI_ShowChangesFromSaveAutomationText(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeWith(weekdayCron, "llm:light", 40000))
	saved := strings.Replace(autoCLIRecipeWith(weekdayCron, "llm:light", 40000), "return 1", "return 2", 1)
	c.assistantSave(t, "digest", saved)

	changes, known, by, _ := showChanges(t, a.ID)
	assert.Equal(t, []any{}, changes, "the save confirmed its own text")
	assert.True(t, known)
	assert.Equal(t, "assistant", by)

	saveText(t, a, strings.Replace(autoCLIRecipeWith(weekdayCron, "llm:light", 20000), "return 1", "return 2", 1))
	row, err := c.d.GetAutomation(a.ID)
	require.NoError(t, err)
	require.NotEqual(t, row.ConfirmedHash, row.ApprovalHash)

	changes, known, by, at := showChanges(t, a.ID)
	assert.Equal(t, []any{change("budget_tokens", "40000", "20000")}, changes,
		"diffed against the saved text, not the text the save replaced")
	assert.True(t, known)
	assert.Empty(t, by, "a hand edit has no recorded author")
	assert.Equal(t, row.UpdatedAt.UTC().Format(time.RFC3339), at)
}

func TestAutomationsCLI_ShowChangesUnknownWithoutSource(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeWith(weekdayCron, "llm:light", 40000))
	saveText(t, a, autoCLIRecipeWith(dailyCron, "llm:light", 40000))

	out, err := runAutomations(t, "show", idArg(a.ID), "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"changes": []`)
	changes, known, by, _ := showChanges(t, a.ID)
	assert.Empty(t, changes)
	assert.False(t, known)
	assert.Empty(t, by)
}

// D26: the confirmed hash is an old-format hash; the snapshot at it holds
// the very text on disk, but re-hashing it now gives the new approval_hash.
func TestAutomationsCLI_ShowChangesUnknownAfterRehash(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "digest", autoCLIRecipeWith(weekdayCron, "llm:light", 40000))
	oldFormat := strings.Repeat("ab", 32)
	_, err := c.d.Exec(`UPDATE automations SET confirmed_hash = ?, enabled = 1 WHERE id = ?`, oldFormat, a.ID)
	require.NoError(t, err)
	c.runOnce(t, a, oldFormat)

	changes, known, _, _ := showChanges(t, a.ID)
	assert.Equal(t, []any{}, changes)
	assert.False(t, known)
}

func TestAutomationsCLI_ShowChangesNeverConfirmed(t *testing.T) {
	c := newAutoCLI(t)
	a := c.indexRecipe(t, "digest", autoCLIRecipeWith(weekdayCron, "llm:light", 40000))
	changes, known, by, at := showChanges(t, a.ID)
	assert.Equal(t, []any{}, changes)
	assert.False(t, known)
	assert.Empty(t, by)
	assert.Equal(t, a.UpdatedAt.UTC().Format(time.RFC3339), at)
}

func TestAutomationsCLI_ShowChangesIgnoresButtonLabel(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "digest", autoCLIRecipeWith("  button: {label: Go}", "llm:light", 40000))
	saveText(t, a, autoCLIRecipeWith("  button: {label: Run it now}", "llm:light", 40000))
	changes, known, _, _ := showChanges(t, a.ID)
	assert.Equal(t, []any{}, changes, "a label rename keeps the confirmation")
	assert.True(t, known)

	c.runOnce(t, a, a.ApprovalHash)
	saveText(t, a, autoCLIRecipeWith("  button: {label: Again}", "llm:light", 30000))
	changes, known, _, _ = showChanges(t, a.ID)
	assert.Equal(t, []any{change("budget_tokens", "40000", "30000")}, changes, "no trigger entry for the label")
	assert.True(t, known)
}
