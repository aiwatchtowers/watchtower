package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchmethod"
)

func runMethodology(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	return runWorkbench(t, append([]string{"methodology"}, args...)...)
}

func decodeMethodology(t *testing.T, out string) workbenchMethodologyJSON {
	t.Helper()
	var res workbenchMethodologyJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

func methodologyWorkbench(t *testing.T) (*db.DB, int64, string) {
	t.Helper()
	database := writeActionsConfig(t)
	folder := t.TempDir()
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	return database, pid, folder
}

// The empty-state wire shape the Desktop decodes: every object present.
func TestWorkbenchMethodology_ShowsDefaultsAndSources(t *testing.T) {
	_, pid, _ := methodologyWorkbench(t)

	out, _, err := runMethodology(t, strconv.FormatInt(pid, 10), "--json")

	require.NoError(t, err)
	res := decodeMethodology(t, out)
	assert.True(t, res.OK)
	assert.True(t, res.InstallOK)
	assert.Equal(t, methodologyValuesJSON{}, res.Personal)
	assert.Equal(t, methodologyValuesJSON{Preset: "watchtower-flow", AskGuard: "strict", FinishCheck: "on"}, res.Effective)
	assert.Equal(t, methodologyValuesJSON{Preset: "default", AskGuard: "default", FinishCheck: "default"}, res.Sources)
	assert.Equal(t, methodologyFileJSON{Path: workbenchmethod.FileRel, Ignored: []string{}}, res.File)
	assert.Contains(t, out, `"ignored": []`, "an array, never null")
	assert.JSONEq(t, `{"preset":"","ask_guard":"","finish_check":""}`, string(mustJSON(t, res.Personal)))
}

func TestWorkbenchMethodology_SetsDropsAndClears(t *testing.T) {
	database, pid, folder := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, workbenchmethod.FileRel), []byte("---\nfinish_check: off\n---\nRules."), 0o644))

	_, _, err := runMethodology(t, id, "--ask-guard", "soft", "--finish-check", "on")
	require.NoError(t, err)
	m, err := database.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, db.WorkbenchMethodology{AskGuard: "soft", FinishCheck: "on"}, m)

	out, _, err := runMethodology(t, id, "--finish-check", "file", "--json")
	require.NoError(t, err)
	res := decodeMethodology(t, out)
	assert.Equal(t, "soft", res.Personal.AskGuard, "the other setting stays")
	assert.Equal(t, "on", res.Effective.FinishCheck, "the file never turns a check down (board #558)")
	assert.Equal(t, "default", res.Sources.FinishCheck)
	assert.Equal(t, methodologyFileJSON{Path: workbenchmethod.FileRel, Present: true, BodyChars: 6,
		Ignored: []string{"finish_check: off"}}, res.File)

	text, _, err := runMethodology(t, id)
	require.NoError(t, err)
	assert.Contains(t, text, "ignored       finish_check: off in the folder file")

	_, _, err = runMethodology(t, id, "--clear")
	require.NoError(t, err)
	m, err = database.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, db.WorkbenchMethodology{}, m)
}

// Board #558's one-time carry-over through the owner's CLI: a workbench
// made on this install (a fresh install, or after the upgrade) is never
// carried; one marked carry-pending (it existed at migration 00131) gets its
// file's off as the owner's setting, shown with its carry date, once — a
// later edit of the file is never copied.
func TestWorkbenchMethodology_CarriesFileChecksOverOnce(t *testing.T) {
	database, pid, folder := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	writeFolderWorkflow(t, folder, "---\nask_guard: off\n---\n")

	out, _, err := runMethodology(t, id, "--json")
	require.NoError(t, err)
	res := decodeMethodology(t, out)
	assert.Equal(t, methodologyValuesJSON{}, res.Personal, "not pending: a fresh install never carries")
	assert.Equal(t, "strict", res.Effective.AskGuard)
	assert.Equal(t, []string{"ask_guard: off"}, res.File.Ignored)

	_, err = database.Exec(`UPDATE projects SET methodology_carry_pending = 1 WHERE id = ?`, pid)
	require.NoError(t, err)
	out, _, err = runMethodology(t, id, "--json")
	require.NoError(t, err)
	res = decodeMethodology(t, out)
	assert.Equal(t, "off", res.Personal.AskGuard, "carried over")
	assert.NotEmpty(t, res.CarriedAt.AskGuard)
	assert.Empty(t, res.CarriedAt.FinishCheck)
	assert.Empty(t, res.File.Ignored, "the owner's value now stands; nothing to note")

	writeFolderWorkflow(t, folder, "---\nask_guard: off\nfinish_check: off\n---\n")
	out, _, err = runMethodology(t, id, "--json")
	require.NoError(t, err)
	res = decodeMethodology(t, out)
	assert.Equal(t, methodologyValuesJSON{AskGuard: "off"}, res.Personal, "a later edit is never copied")
	assert.Equal(t, []string{"finish_check: off"}, res.File.Ignored)
}

// Board #558: the checks are the owner's alone — under an agent the CLI
// refuses to change them (AGENT-07's refusal) and writes nothing; a read
// and a preset change still work.
func TestWorkbenchMethodology_RefusesCheckWritesUnderAnAgent(t *testing.T) {
	database, pid, _ := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	t.Setenv(agentEnvMarkers[0], "1")
	for _, args := range [][]string{{"--ask-guard", "off"}, {"--finish-check", "off"}, {"--ask-guard", "file"}, {"--clear"}} {
		_, _, err := runMethodology(t, append([]string{id}, args...)...)
		require.Error(t, err, "%v", args)
		assert.Contains(t, err.Error(), "refusing to change the ask guard or the finish check under an AI agent")
	}
	m, err := database.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, db.WorkbenchMethodology{}, m)
	_, _, err = runMethodology(t, id, "--json")
	require.NoError(t, err, "a read is fine")
}

func writeFolderWorkflow(t *testing.T, folder, content string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, workbenchmethod.FileRel), []byte(content), 0o644))
}

func TestWorkbenchMethodology_RefusesBadValuesWithoutWriting(t *testing.T) {
	database, pid, _ := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)
	for _, args := range [][]string{
		{"--ask-guard", "loose"}, {"--preset", "scrum"}, {"--finish-check", "yes"}, {"--clear", "--preset", "none"},
	} {
		_, _, err := runMethodology(t, append([]string{id}, args...)...)
		assert.Error(t, err, "%v", args)
	}
	m, err := database.GetWorkbenchMethodology(pid)
	require.NoError(t, err)
	assert.Equal(t, db.WorkbenchMethodology{}, m)
}

func TestWorkbenchMethodology_CreateFileNeverOverwrites(t *testing.T) {
	_, pid, folder := methodologyWorkbench(t)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runMethodology(t, id, "--create-file", "--json")
	require.NoError(t, err)
	res := decodeMethodology(t, out)
	assert.True(t, res.FileCreated)
	assert.True(t, res.File.Present)
	assert.Empty(t, res.File.Error, "the template parses")

	require.NoError(t, os.WriteFile(filepath.Join(folder, workbenchmethod.FileRel), []byte("mine"), 0o644))
	out, _, err = runMethodology(t, id, "--create-file", "--json")
	require.NoError(t, err)
	assert.False(t, decodeMethodology(t, out).FileCreated)
	got, err := os.ReadFile(filepath.Join(folder, workbenchmethod.FileRel))
	require.NoError(t, err)
	assert.Equal(t, "mine", string(got))
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return b
}
