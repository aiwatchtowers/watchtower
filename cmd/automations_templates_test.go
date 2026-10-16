package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// installJSON decodes `install-template --json`.
type installJSONOut struct {
	AutomationID int64  `json:"automation_id"`
	Path         string `json:"path"`
	Installed    []struct {
		AutomationID int64  `json:"automation_id"`
		Slug         string `json:"slug"`
		Path         string `json:"path"`
		ParseError   string `json:"parse_error"`
	} `json:"installed"`
}

func installTemplate(t *testing.T, args ...string) installJSONOut {
	t.Helper()
	out, err := runAutomations(t, append(append([]string{"install-template"}, args...), "--json")...)
	require.NoError(t, err, out)
	var got installJSONOut
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	return got
}

// templateWorkbench binds a workbench to a temp folder (stored resolved).
func templateWorkbench(t *testing.T, c *autoCLI) (int64, string) {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	id, err := c.d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	return id, folder
}

func TestInstallTemplate_PlaceholdersAndParams(t *testing.T) {
	c := newAutoCLI(t)
	got := installTemplate(t, "jira-state-report")
	require.Len(t, got.Installed, 1)
	assert.Contains(t, got.Installed[0].ParseError, "<PROJECT>")
	a, err := c.d.GetAutomation(got.AutomationID)
	require.NoError(t, err)
	assert.False(t, a.Runnable())
	text, err := os.ReadFile(got.Path)
	require.NoError(t, err)
	assert.Contains(t, string(text), "jira:read@<PROJECT>", "the placeholder is installed as written")

	c2 := newAutoCLI(t)
	got = installTemplate(t, "jira-state-report", "--param", "PROJECT=PAY")
	require.Len(t, got.Installed, 1)
	assert.Empty(t, got.Installed[0].ParseError)
	a, err = c2.d.GetAutomation(got.AutomationID)
	require.NoError(t, err)
	assert.Contains(t, a.PermissionsJSON, "jira:read@PAY")

	c3 := newAutoCLI(t)
	for _, param := range []string{"PROJECT=a b", "X=1", "PROJECT", "PROJECT=PAY:", `PROJECT=PAY\`} {
		out, err := runAutomations(t, "install-template", "jira-state-report", "--param", param)
		require.Error(t, err, "--param %s: %s", param, out)
	}
	assert.NoFileExists(t, filepath.Join(c3.personal, "jira-state-report.md"))
	rows, err := c3.d.ListAutomations(db.AutomationFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestInstallTemplate_FailedWriteRollsBack(t *testing.T) {
	c := newAutoCLI(t)
	wb, folder := templateWorkbench(t, c)
	calls := 0
	orig := writeTemplateFile
	writeTemplateFile = func(path string, data []byte, perm os.FileMode) error {
		calls++
		if calls == 2 {
			return os.ErrPermission
		}
		return orig(path, data, perm)
	}
	t.Cleanup(func() { writeTemplateFile = orig })

	_, err := runAutomations(t, "install-template", "release-buttons", "--workbench", idArg(wb))
	require.Error(t, err)
	dir := automations.WorkbenchDir(folder)
	for _, slug := range []string{"release", "deploy-test", "deploy-stage"} {
		assert.NoFileExists(t, filepath.Join(dir, slug+".md"))
	}

	writeTemplateFile = orig
	got := installTemplate(t, "release-buttons", "--workbench", idArg(wb))
	assert.Len(t, got.Installed, 3, "a retry is not refused")
}

func TestInstallTemplate_InstalledUnconfirmedAndDisabled(t *testing.T) {
	c := newAutoCLI(t)
	got := installTemplate(t, "team-performance-report")
	require.Len(t, got.Installed, 1)
	assert.Empty(t, got.Installed[0].ParseError)

	show := runAutomationsJSON(t, "show", idArg(got.AutomationID))
	assert.Equal(t, true, show["needs_confirmation"])
	assert.Equal(t, false, show["enabled"])
	assert.Equal(t, false, show["runnable"])

	_, err := runAutomations(t, "run", idArg(got.AutomationID))
	require.ErrorContains(t, err, "needs your confirmation")

	// A run queued anyway (a schedule tick, a stale button) is cancelled by
	// the executor as not runnable (AUTO-06).
	runID, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: got.AutomationID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	exec := automations.NewExecutor(c.d, automations.Backends{}, automations.ExecutorOptions{})
	started, err := exec.Step(context.Background())
	require.NoError(t, err)
	assert.Zero(t, started)
	run, err := c.d.GetAutomationRun(runID)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)
	assert.Equal(t, db.ErrKindNotRunnable, run.ErrorKind)
}

func TestInstallTemplate_WorkbenchScopeRules(t *testing.T) {
	c := newAutoCLI(t)
	wb, folder := templateWorkbench(t, c)

	_, err := runAutomations(t, "install-template", "pr-review-rounds")
	require.ErrorContains(t, err, "--workbench")
	_, err = runAutomations(t, "install-template", "new-mail-summary", "--workbench", idArg(wb))
	require.ErrorContains(t, err, "personal")
	assert.NoDirExists(t, automations.WorkbenchDir(folder))
	assert.NoFileExists(t, filepath.Join(c.personal, "new-mail-summary.md"))

	got := installTemplate(t, "release-buttons", "--workbench", idArg(wb))
	require.Len(t, got.Installed, 3)
	dir := automations.WorkbenchDir(folder)
	for i, slug := range []string{"release", "deploy-test", "deploy-stage"} {
		e := got.Installed[i]
		assert.Equal(t, slug, e.Slug)
		assert.Equal(t, filepath.Join(dir, slug+".md"), e.Path)
		assert.FileExists(t, e.Path)
		assert.Empty(t, e.ParseError)
		a, err := c.d.GetAutomation(e.AutomationID)
		require.NoError(t, err)
		assert.Equal(t, string(automations.ScopeWorkbench), a.Scope)
		assert.Equal(t, wb, a.ProjectID)
		assert.False(t, a.Enabled)
		assert.NotEqual(t, a.ApprovalHash, a.ConfirmedHash)
	}
	assert.Equal(t, got.Installed[0].AutomationID, got.AutomationID)
	assert.Equal(t, got.Installed[0].Path, got.Path)
}

func TestInstallTemplate_RefusesExistingSlug(t *testing.T) {
	c := newAutoCLI(t)
	got := installTemplate(t, "new-mail-summary")
	before, err := os.ReadFile(got.Path)
	require.NoError(t, err)
	_, err = runAutomations(t, "install-template", "new-mail-summary")
	require.ErrorContains(t, err, "new-mail-summary")
	after, err := os.ReadFile(got.Path)
	require.NoError(t, err)
	assert.Equal(t, before, after)

	// A slug held only by an index row (its file removed) is refused too,
	// and so is a template one of whose several slugs is taken.
	require.NoError(t, os.Remove(got.Path))
	_, err = runAutomations(t, "install-template", "new-mail-summary")
	require.ErrorContains(t, err, "new-mail-summary")
	assert.NoFileExists(t, got.Path)

	wb, folder := templateWorkbench(t, c)
	dir := automations.WorkbenchDir(folder)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	writeRecipe(t, dir, "deploy-test", "mine")
	_, err = runAutomations(t, "install-template", "release-buttons", "--workbench", idArg(wb))
	require.ErrorContains(t, err, "deploy-test")
	assert.NoFileExists(t, filepath.Join(dir, "release.md"), "nothing is written when one slug is taken")
	mine, err := os.ReadFile(filepath.Join(dir, "deploy-test.md"))
	require.NoError(t, err)
	assert.Equal(t, "mine", string(mine))
}

func TestTemplatesCLI_JSON(t *testing.T) {
	newAutoCLI(t)
	out, err := runAutomations(t, "templates", "--json")
	require.NoError(t, err, out)
	var entries []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &entries), out)
	require.Len(t, entries, 5)
	for _, e := range entries {
		for _, k := range []string{"name", "title", "description", "scope", "trigger_text", "permissions", "outputs", "files", "params"} {
			assert.Contains(t, e, k, "entry %v", e["name"])
		}
		assert.IsType(t, []any{}, e["permissions"])
		assert.IsType(t, []any{}, e["outputs"])
		assert.IsType(t, []any{}, e["params"])
	}
	release := entries[4]
	assert.Equal(t, "release-buttons", release["name"])
	assert.Equal(t, "workbench", release["scope"])
	assert.Equal(t, "Button: Release", release["trigger_text"])
	assert.Equal(t, []any{`shell:"make release"`, "session:start"}, release["permissions"])
	assert.Equal(t, []any{"release", "deploy-test", "deploy-stage"}, release["files"])
	jira := entries[2]
	assert.Equal(t, []any{map[string]any{"key": "PROJECT", "label": "Jira project key", "example": "PAY"}}, jira["params"])

	text, err := runAutomations(t, "templates")
	require.NoError(t, err)
	assert.Contains(t, text, "release-buttons")

	raw, err := runAutomations(t, "install-template", "new-mail-summary", "--json")
	require.NoError(t, err, raw)
	var top map[string]any
	require.NoError(t, json.Unmarshal([]byte(raw), &top), raw)
	assert.Contains(t, top, "automation_id")
	assert.Contains(t, top, "path")
	assert.Contains(t, top, "installed")
}
