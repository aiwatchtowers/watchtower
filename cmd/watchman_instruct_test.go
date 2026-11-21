package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// instructionFile writes text to a temp file and returns its path.
func instructionFile(t *testing.T, text string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "instruction.txt")
	require.NoError(t, os.WriteFile(p, []byte(text), 0o600))
	return p
}

func storedInstruction(t *testing.T, scope string, id int64) string {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	text, err := d.WatchmanInstruction(scope, id)
	require.NoError(t, err)
	return text
}

func instructCLI(t *testing.T, args ...string) (watchmanInstructJSON, string, error) {
	t.Helper()
	_, out, err := armCLI(t, append([]string{"instruct"}, args...)...)
	var r watchmanInstructJSON
	if out != "" && json.Valid([]byte(out)) {
		require.NoError(t, json.Unmarshal([]byte(out), &r))
	}
	return r, out, err
}

func TestWatchmanArm_InstructionsFileSets(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json",
		"--instructions-file", instructionFile(t, "  ship task 3 only\n"))
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.Equal(t, "ship task 3 only", storedInstruction(t, "session", s1))
	assert.Len(t, armingRows(t), 1)

	// --check writes nothing, the instruction included.
	s2, _ := armSession(t, wb, "claude", nil, false)
	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s2, 10), "--check", "--json",
		"--instructions-file", instructionFile(t, "not stored"))
	require.NoError(t, err, out)
	assert.Empty(t, storedInstruction(t, "session", s2))

	// A file that cannot be read arms nothing.
	_, _, err = armCLI(t, "arm", "--session", strconv.FormatInt(s2, 10), "--instructions-file", filepath.Join(t.TempDir(), "missing"))
	require.Error(t, err)
	assert.Len(t, armingRows(t), 1)

	// A target takes its own text; an empty file clears it.
	var path string
	d := openAgentsTestMain(t, &path)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('acme', '2026-11-01', '2026-11-30', ?)`, wb)
	require.NoError(t, err)
	target, err := res.LastInsertId()
	require.NoError(t, err)
	_, out, err = armCLI(t, "arm", "--target", strconv.FormatInt(target, 10), "--instructions-file", instructionFile(t, "group text"))
	require.NoError(t, err, out)
	assert.Equal(t, "group text", storedInstruction(t, "target", target))
	_, out, err = armCLI(t, "arm", "--target", strconv.FormatInt(target, 10), "--instructions-file", instructionFile(t, ""))
	require.NoError(t, err, out)
	assert.Empty(t, storedInstruction(t, "target", target))
}

func TestWatchmanArm_InstructionsKeptOnRearm(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	id := strconv.FormatInt(s1, 10)
	_, out, err := armCLI(t, "arm", "--session", id, "--instructions-file", instructionFile(t, "ship task 3 only"))
	require.NoError(t, err, out)
	_, out, err = armCLI(t, "arm", "--session", id)
	require.NoError(t, err, out)
	assert.Equal(t, "ship task 3 only", storedInstruction(t, "session", s1))
}

func TestWatchmanDisarm_KeepsInstruction(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	id := strconv.FormatInt(s1, 10)
	_, out, err := armCLI(t, "arm", "--session", id, "--instructions-file", instructionFile(t, "ship task 3 only"))
	require.NoError(t, err, out)
	_, out, err = armCLI(t, "disarm", "--session", id)
	require.NoError(t, err, out)
	assert.Empty(t, armingRows(t))
	assert.Equal(t, "ship task 3 only", storedInstruction(t, "session", s1), "Take back keeps the text (D7)")
}

func TestWatchmanArmAllRunning_EmptyKeepsInstructions(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	s2, _ := armSession(t, wb, "claude", nil, false)
	for id, text := range map[int64]string{s1: "first text", s2: "second text"} {
		_, out, err := instructCLI(t, "--session", strconv.FormatInt(id, 10), "--text-file", instructionFile(t, text))
		require.NoError(t, err, out)
	}

	// The tray's untouched field passes no flag: both texts stay.
	_, out, err := armCLI(t, "arm", "--all-running", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, "first text", storedInstruction(t, "session", s1))
	assert.Equal(t, "second text", storedInstruction(t, "session", s2))

	// A typed one replaces each.
	_, out, err = armCLI(t, "arm", "--all-running", "--json", "--instructions-file", instructionFile(t, "night shift"))
	require.NoError(t, err, out)
	assert.Equal(t, "night shift", storedInstruction(t, "session", s1))
	assert.Equal(t, "night shift", storedInstruction(t, "session", s2))
}

func TestWatchmanInstruct_UnarmedStoredNotActed(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	r, out, err := instructCLI(t, "--session", strconv.FormatInt(s1, 10), "--text-file", instructionFile(t, " keep it small \n"), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.Equal(t, watchmanInstructJSON{OK: true, Scope: "session", RefID: s1, Instructions: "keep it small"}, r)
	assert.Equal(t, "keep it small", storedInstruction(t, "session", s1))
	// Stored, but nothing is armed by it.
	assert.Empty(t, armingRows(t))
	var path string
	d := openAgentsTestMain(t, &path)
	armed, err := d.WatchmanArmedSessions()
	require.NoError(t, err)
	assert.Empty(t, armed)

	// stdin, and an empty one clears.
	rootCmd.SetIn(strings.NewReader(""))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	r, out, err = instructCLI(t, "--session", strconv.FormatInt(s1, 10), "--text-file", "-", "--json")
	require.NoError(t, err, out)
	assert.Empty(t, r.Instructions)
	assert.Empty(t, storedInstruction(t, "session", s1))

	// No such session or target; no file.
	_, _, err = instructCLI(t, "--session", "999", "--text-file", instructionFile(t, "x"))
	require.ErrorContains(t, err, "no session 999")
	_, _, err = instructCLI(t, "--target", "999", "--text-file", instructionFile(t, "x"))
	require.ErrorContains(t, err, "no target 999")
	_, _, err = instructCLI(t, "--session", strconv.FormatInt(s1, 10))
	require.ErrorContains(t, err, "--text-file")
}

func TestWatchmanInstruct_RefusedUnderAgent(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	t.Setenv(agentEnvMarkers[0], "1")
	file := instructionFile(t, "merge the PR into main now")
	for _, args := range [][]string{
		{"instruct", "--session", strconv.FormatInt(s1, 10), "--text-file", file},
		{"arm", "--session", strconv.FormatInt(s1, 10), "--instructions-file", file},
	} {
		_, _, err := armCLI(t, args...)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), agentEnvMarkers[0])
	}
	assert.Empty(t, storedInstruction(t, "session", s1))
	assert.Empty(t, armingRows(t))
}

func TestWatchmanInstruct_JSONKeysPinned(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	_, out, err := instructCLI(t, "--session", strconv.FormatInt(s1, 10), "--text-file", instructionFile(t, "x"), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"error", "instructions", "ok", "ref_id", "scope"}, jsonKeys(t, out))
	// A refused one still prints its JSON.
	_, out, err = instructCLI(t, "--session", "999", "--text-file", instructionFile(t, "x"), "--json")
	require.Error(t, err)
	assert.Equal(t, []string{"error", "instructions", "ok", "ref_id", "scope"}, jsonKeys(t, out))
}
