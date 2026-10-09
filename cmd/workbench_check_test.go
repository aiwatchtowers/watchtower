package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchcheck"
)

// driftRepo is a git repository whose branch "merged" is merged into main
// and whose branch "open" is not.
func driftRepo(t *testing.T) string {
	t.Helper()
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		t.Setenv(k, v)
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	git := func(args ...string) {
		c := exec.Command("git", args...)
		c.Dir = dir
		out, err := c.CombinedOutput()
		require.NoError(t, err, "git %v: %s", args, out)
	}
	write := func(name string) {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(name), 0o644))
		git("add", name)
		git("commit", "-q", "-m", name)
	}
	git("init", "-q", "-b", "main")
	write("README.md")
	git("checkout", "-q", "-b", "merged")
	write("a.txt")
	git("checkout", "-q", "main")
	git("merge", "-q", "--no-ff", "-m", "merge", "merged")
	git("checkout", "-q", "-b", "open")
	write("b.txt")
	git("checkout", "-q", "main")
	return dir
}

// driftWorkbench creates a project in folder with one in-progress target on
// branch.
func driftWorkbench(t *testing.T, database *db.DB, folder, branch string) (int64, int64) {
	t.Helper()
	// Run from a Watchtower terminal, `go test` inherits its row id; a test
	// that wants the session state sets the variable itself afterwards.
	unsetTerminalEnv(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	var ids []int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		ids, err = database.CreateWorkbenchTargetsTx(tx, pid, db.ActorAgent, []db.WorkbenchTargetInput{{Title: "Feature", Branch: branch}})
		return err
	}))
	require.NoError(t, database.UpdateTargetStatus(int(ids[0]), "in_progress"))
	return pid, ids[0]
}

func stopHook(t *testing.T, id int64, input string) string {
	t.Helper()
	out, _ := stopHookIO(t, strconv.FormatInt(id, 10), input)
	return out
}

func stopHookIO(t *testing.T, rawID, input string) (stdout, stderr string) {
	t.Helper()
	var out, errOut bytes.Buffer
	runStopHook(context.Background(), strings.NewReader(input), &out, &errOut, rawID, workbenchVocabulary)
	return out.String(), errOut.String()
}

func TestProj07_StopHookBlocksOnceWithTheDrift(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, tid := driftWorkbench(t, database, folder, "merged")

	out := stopHook(t, pid, `{"hook_event_name":"Stop","stop_hook_active":false}`)
	var got stopHookOutput
	require.NoError(t, json.Unmarshal([]byte(out), &got), "the hook must print one JSON object: %q", out)
	assert.Equal(t, "block", got.Decision)
	assert.Contains(t, got.Reason, "#"+strconv.FormatInt(tid, 10))
	assert.Contains(t, got.Reason, "branch merged is merged into main")

	// Claude Code is already continuing because of this hook: never block again.
	assert.Empty(t, stopHook(t, pid, `{"hook_event_name":"Stop","stop_hook_active":true}`))

	// Fixed board: silent.
	require.NoError(t, database.UpdateTargetStatus(int(tid), "done"))
	assert.Empty(t, stopHook(t, pid, `{"stop_hook_active":false}`))
}

func TestProj07_StopHookIsSilentWithoutGitDrift(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, tid := driftWorkbench(t, database, folder, "open")
	assert.Empty(t, stopHook(t, pid, `{"stop_hook_active":false}`), "an unmerged branch of in-progress work is no drift")

	// Staleness alone never stops a turn.
	_, err := database.Exec(`UPDATE targets SET branch = '', updated_at = ? WHERE id = ?`,
		time.Now().Add(-30*24*time.Hour).UTC().Format(time.RFC3339), tid)
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`,
		time.Now().Add(-30*24*time.Hour).UTC().Format(time.RFC3339), tid)
	require.NoError(t, err)
	assert.Empty(t, stopHook(t, pid, `{"stop_hook_active":false}`))
}

// A leftover Stop hook of a deleted project (an old install), a moved
// folder, bad input or a bad id: always silent, never an error.
func TestProj07_StopHookFailuresAreSilent(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, _ := driftWorkbench(t, database, folder, "merged")

	assert.Empty(t, stopHook(t, pid, `not json`))
	assert.Empty(t, stopHook(t, pid, ``))
	out, errOut := stopHookIO(t, "abc", `{}`)
	assert.Empty(t, out)
	assert.Contains(t, errOut, "invalid --workbench", "a real failure names itself on stderr")
	// The pre-rename install's hook (--project, legacy vocabulary) too.
	var legacyOut, legacyErr bytes.Buffer
	runStopHook(context.Background(), strings.NewReader(`{}`), &legacyOut, &legacyErr, "abc", legacyWorkbenchVocabulary)
	assert.Empty(t, legacyOut.String())
	assert.Contains(t, legacyErr.String(), "invalid --project", "a real failure names itself on stderr")

	require.NoError(t, database.DeleteWorkbench(pid))
	out, errOut = stopHookIO(t, strconv.FormatInt(pid, 10), `{"stop_hook_active":false}`)
	assert.Empty(t, out, "a deleted project's leftover hook exits silently")
	assert.Empty(t, errOut, "a deleted project's leftover hook is not an error")

	pid2, _ := driftWorkbench(t, database, folder, "merged")
	require.NoError(t, os.RemoveAll(filepath.Join(folder, ".git")))
	assert.Empty(t, stopHook(t, pid2, `{"stop_hook_active":false}`), "no repository: nothing to check")

	// Through cobra: exit 0, even with an unknown flag and a bad id.
	stdout, _, err := runWorkbenchCheckCmd(t, strings.NewReader(`{}`), "check", "--project", "nope", "--stop-hook", "--future-flag")
	require.NoError(t, err)
	assert.Empty(t, stdout)
}

func runWorkbenchCheckCmd(t *testing.T, stdin *strings.Reader, args ...string) (string, string, error) {
	t.Helper()
	rootCmd.SetIn(stdin)
	t.Cleanup(func() {
		rootCmd.SetIn(nil)
		workbenchCheckFlagWorkbench, workbenchCheckFlagJSON, workbenchCheckFlagStopHook = "", false, false
		workbenchCheckFlagNoNetwork = false
		workbenchCheckFlagStaleDays = int(workbenchcheck.DefaultStaleAfter / (24 * time.Hour))
	})
	return runWorkbench(t, args...)
}

func TestProjectCheck_JSONReportsTheDrift(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, tid := driftWorkbench(t, database, folder, "merged")

	stdout, _, err := runWorkbenchCheckCmd(t, strings.NewReader(""), "check", "--project", strconv.FormatInt(pid, 10), "--json", "--no-network")
	require.NoError(t, err)
	var rep workbenchcheck.Report
	require.NoError(t, json.Unmarshal([]byte(stdout), &rep), stdout)
	require.Len(t, rep.Findings, 1)
	assert.Equal(t, workbenchcheck.KindMergedOpen, rep.Findings[0].Kind)
	assert.Equal(t, int(tid), rep.Findings[0].TargetID)
	assert.Equal(t, "main", rep.Base)

	_, _, err = runWorkbenchCheckCmd(t, strings.NewReader(""), "check", "--project", "999", "--no-network")
	assert.Error(t, err, "outside the hook an unknown project is an error")
}

func TestProjectBrief_ShowsTheBoardDrift(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, tid := driftWorkbench(t, database, folder, "merged")
	brief := loadWorkbenchBrief(pid, workbenchVocabulary)
	assert.Contains(t, brief, "Board drift")
	assert.Contains(t, brief, "#"+strconv.FormatInt(tid, 10)+` "Feature" [in_progress]: branch merged is merged into main`)
	assert.LessOrEqual(t, len([]rune(brief)), briefMaxChars)
}

// PROJ-02/PROJ-04: nothing of a deleted project remains in the folder's
// settings — neither hook — while the owner's own settings survive.
func TestProj02_ProjectDeleteLeavesNoHookOfTheProject(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	settings := filepath.Join(p.FolderPath, ".claude", "settings.local.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(settings), 0o755))
	require.NoError(t, os.WriteFile(settings, []byte(`{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}],`+
		`"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo mine-prompt"}]}],`+
		`"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"echo mine-ask"}]}]}}`), 0o644))
	var out bytes.Buffer
	require.NoError(t, runWorkbenchInstall(context.Background(), &out, p), out.String())
	installed, err := os.ReadFile(settings)
	require.NoError(t, err)
	ours := []string{
		devpack.WorkbenchStopHookCommand("/usr/local/bin/watchtower", p.ID),
		devpack.WorkbenchHookCommand("/usr/local/bin/watchtower", p.ID),
		devpack.WorkbenchSessionStateHookCommand("/usr/local/bin/watchtower", p.ID),
		devpack.WorkbenchAskGuardHookCommand("/usr/local/bin/watchtower", p.ID),
		"[watchtower-workbench ask-guard 7]",
	}
	for _, c := range ours {
		require.Contains(t, string(installed), c)
	}

	require.NoError(t, workbenchRemoveInstall(context.Background(), nil, p))
	after, err := os.ReadFile(settings)
	require.NoError(t, err)
	assert.NotContains(t, string(after), "--project 7", "PROJ-02: a hook of the deleted project survived:\n%s", after)
	for _, c := range ours {
		assert.NotContains(t, string(after), c, "PROJ-02: a hook of the deleted project survived:\n%s", after)
	}
	assert.NotContains(t, string(after), "session-state", "PROJ-02: a session state hook survived:\n%s", after)
	assert.Contains(t, string(after), "echo mine", "PROJ-04: the owner's own Stop hook stays")
	assert.Contains(t, string(after), "echo mine-prompt", "PROJ-04: the owner's own UserPromptSubmit hook stays")
	assert.Contains(t, string(after), "echo mine-ask", "PROJ-04: the owner's own PreToolUse hook stays")
	assert.NotContains(t, string(after), "ask-guard", "PROJ-02: an ask guard hook survived:\n%s", after)
	assert.Contains(t, string(after), `"model": "sonnet"`)
}

func TestStopHookReason_CapsAndClips(t *testing.T) {
	var findings []workbenchcheck.Finding
	for i := 0; i < stopHookMaxFindings+5; i++ {
		findings = append(findings, workbenchcheck.Finding{TargetID: i + 1, Title: strings.Repeat("x", 600), Status: "in_progress",
			Kind: workbenchcheck.KindMergedOpen, Detail: "d", Fix: "f"})
	}
	reason := stopHookReason(3, findings, workbenchVocabulary)
	lines := strings.Split(reason, "\n")
	require.Len(t, lines, 1+stopHookMaxFindings+1, "header, the capped findings, one overflow line")
	assert.Equal(t, "- … 5 more (watchtower workbench check --workbench 3)", lines[len(lines)-1])
	for _, l := range lines[1 : len(lines)-1] {
		assert.LessOrEqual(t, len([]rune(l)), 402, "each finding is clipped")
	}
}
