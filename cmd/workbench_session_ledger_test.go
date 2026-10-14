package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The session-state hooks record the session's worktree ledger (board #535,
// spec 2026-10-12-session-cleanup §3.2). The repositories here are laid out
// the way git writes them — a main work tree's .git dir, a linked work
// tree's "gitdir:" file and admin dir — because the hook reads files only.

// ledgerRepo is a main work tree on branch main under a fresh temp dir,
// symlink-resolved (the form the ledger stores).
func ledgerRepo(t *testing.T) string {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	main := filepath.Join(base, "acme")
	require.NoError(t, os.MkdirAll(filepath.Join(main, ".git"), 0o755))
	setLedgerHead(t, filepath.Join(main, ".git"), "ref: refs/heads/main")
	return main
}

// ledgerWorktree adds a linked work tree of main at main/rel on branch
// (head is written as is when it does not start with "ref:" — a detached
// sha), its admin dir under main/.git/worktrees.
func ledgerWorktree(t *testing.T, main, rel, head string) string {
	t.Helper()
	dir := filepath.Join(main, rel)
	admin := filepath.Join(main, ".git", "worktrees", filepath.Base(dir))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	require.NoError(t, os.MkdirAll(admin, 0o755))
	setLedgerHead(t, admin, head)
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".git"), []byte("gitdir: "+admin+"\n"), 0o644))
	return dir
}

func setLedgerHead(t *testing.T, gitDir, head string) {
	t.Helper()
	require.NoError(t, os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte(head+"\n"), 0o644))
}

func ledgerRows(t *testing.T, database *db.DB, row int64) []db.SessionWorktree {
	t.Helper()
	rows, err := database.SessionWorktrees(context.Background(), row)
	require.NoError(t, err)
	return rows
}

// ledgerPairs is rows as "root@branch", in order.
func ledgerPairs(rows []db.SessionWorktree) []string {
	out := []string{}
	for _, r := range rows {
		out = append(out, r.Root+"@"+r.Branch)
	}
	return out
}

// runLedgerEvent runs one session-state event and asserts the hook contract:
// nothing on stdout, nothing on stderr, exit 0.
func runLedgerEvent(t *testing.T, pid int64, payload string) {
	t.Helper()
	out, errOut, err := runSessionState(t, pid, strings.NewReader(payload))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
}

func TestSessionStateLedger_Resolver(t *testing.T) {
	main := ledgerRepo(t)
	wt := ledgerWorktree(t, main, ".claude/worktrees/agent-x", "ref: refs/heads/feat/x")
	detached := ledgerWorktree(t, main, "wt-detached", "0123456789abcdef0123456789abcdef01234567")
	reftable := ledgerWorktree(t, main, "wt-reftable", "ref: refs/heads/.invalid")
	relative := filepath.Join(main, "wt-relative")
	require.NoError(t, os.MkdirAll(filepath.Join(relative, "sub"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(relative, ".git"), []byte("gitdir: ../.git/worktrees/agent-x\n"), 0o644))
	broken := filepath.Join(main, "broken")
	require.NoError(t, os.MkdirAll(broken, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(broken, ".git"), []byte("not a pointer\n"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(main, "src", "pkg"), 0o755))
	outside, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)

	for _, tc := range []struct {
		name, dir, root, branch string
		ok                      bool
	}{
		{"main work tree", main, main, "main", true},
		{"inside the main work tree", filepath.Join(main, "src", "pkg"), main, "main", true},
		{"a missing dir inside it", filepath.Join(main, "gone", "deeper"), main, "main", true},
		{"linked work tree", wt, wt, "feat/x", true},
		{"detached HEAD", detached, detached, "", true},
		{"reftable HEAD stub: branch unknown", reftable, reftable, "", true},
		{"relative gitdir", filepath.Join(relative, "sub"), relative, "feat/x", true},
		{"a .git that is no pointer", broken, "", "", false},
		{"outside any repository", outside, "", "", false},
	} {
		root, branch, ok := sessionWorktreeAt(tc.dir)
		assert.Equal(t, tc.ok, ok, tc.name)
		assert.Equal(t, tc.root, root, tc.name)
		assert.Equal(t, tc.branch, branch, tc.name)
	}
}

func TestSessionStateLedger_ResolvesSymlinks(t *testing.T) {
	main := ledgerRepo(t)
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(main, link))
	root, branch, ok := sessionWorktreeAt(filepath.Join(link, "src"))
	require.True(t, ok)
	assert.Equal(t, main, root, "the root is stored symlink-resolved")
	assert.Equal(t, "main", branch)
}

// A symlink to a repository's SUBDIRECTORY: walking up the link's own path
// would never meet .git, so the cwd is resolved before the walk — also
// when the cwd itself is gone (its nearest existing ancestor is resolved).
func TestSessionStateLedger_ResolvesASymlinkIntoASubdirectory(t *testing.T) {
	main := ledgerRepo(t)
	require.NoError(t, os.MkdirAll(filepath.Join(main, "src", "pkg"), 0o755))
	link := filepath.Join(t.TempDir(), "pkg-link")
	require.NoError(t, os.Symlink(filepath.Join(main, "src", "pkg"), link))

	for _, dir := range []string{link, filepath.Join(link, "gone", "deeper")} {
		root, branch, ok := sessionWorktreeAt(dir)
		require.True(t, ok, dir)
		assert.Equal(t, main, root, dir)
		assert.Equal(t, "main", branch, dir)
	}
}

// PROJ-11 (amended, owner approved 2026-10-12, ask #193): a (root, branch)
// pair is recorded once; a new branch in the same work tree is a new pair.
func TestProj11_LedgerRecordsANewWorktreeOnce(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	main := ledgerRepo(t)
	wt := ledgerWorktree(t, main, "wt", "ref: refs/heads/feat/x")

	runLedgerEvent(t, pid, withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), wt))
	runLedgerEvent(t, pid, withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), filepath.Join(wt, "sub")))
	rows := ledgerRows(t, database, row)
	require.Len(t, rows, 1, "two events in one work tree record one pair")
	assert.Equal(t, []string{wt + "@feat/x"}, ledgerPairs(rows))
	assert.NotEmpty(t, rows[0].FirstAt)
	first := rows[0].FirstAt

	setLedgerHead(t, filepath.Join(main, ".git", "worktrees", "wt"), "ref: refs/heads/feat/y")
	runLedgerEvent(t, pid, withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), wt))
	rows = ledgerRows(t, database, row)
	assert.ElementsMatch(t, []string{wt + "@feat/x", wt + "@feat/y"}, ledgerPairs(rows))
	for _, r := range rows {
		if r.Branch == "feat/x" {
			assert.Equal(t, first, r.FirstAt, "a recorded pair is never rewritten")
		}
	}
}

// PROJ-11: a ledger failure is one stderr line; the state write lands and
// the hook exits 0 with nothing on stdout.
func TestProj11_LedgerFailureNeverCostsTheStateWrite(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	main := ledgerRepo(t)
	_, err := database.Exec(`DROP TABLE terminal_session_worktrees`)
	require.NoError(t, err)

	out, errOut, err := runSessionState(t, pid,
		strings.NewReader(withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), main)))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Equal(t, 1, strings.Count(errOut, "\n"), "one stderr line: %q", errOut)
	assert.Contains(t, errOut, "watchtower: session worktree not recorded:")
	assert.Equal(t, "working", storedAgentState(t, database, row), "the state write ran")
	assert.Equal(t, main, storedCwd(t, database, row).Path, "the cwd rode in the state write")
}

// PROJ-11: a subagent's cwd (its isolated worktree) goes to the ledger, but
// the session's place (#565's cwd column) follows the main agent only.
func TestProj11_SubagentCwdIsRecordedButNeverMovesTheSessionPlace(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	main := ledgerRepo(t)
	wtStart := ledgerWorktree(t, main, ".claude/worktrees/agent-x", "ref: refs/heads/worktree-agent-x")
	wtTool := ledgerWorktree(t, main, ".claude/worktrees/agent-y", "ref: refs/heads/worktree-agent-y")

	runLedgerEvent(t, pid, withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), main))
	place := storedCwd(t, database, row)
	require.Equal(t, main, place.Path)

	// Each subagent path gets its own worktree, so each is seen recording.
	sub := withCwd(t, fixtureInput(t, "subagentstart_teammate.json"), wtStart)
	runLedgerEvent(t, pid, sub)
	assert.ElementsMatch(t, []string{main + "@main", wtStart + "@worktree-agent-x"},
		ledgerPairs(ledgerRows(t, database, row)), "SubagentStart records its cwd")
	tool := withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), wtTool)
	tool = strings.Replace(tool, `{`, `{"agent_id":"aworktree-1","agent_type":"general-purpose",`, 1)
	runLedgerEvent(t, pid, tool)

	assert.ElementsMatch(t, []string{main + "@main", wtStart + "@worktree-agent-x", wtTool + "@worktree-agent-y"},
		ledgerPairs(ledgerRows(t, database, row)), "a subagent's PostToolUse records its cwd")
	assert.Equal(t, place, storedCwd(t, database, row), "a subagent never moves the session's place")
}

func TestSessionStateLedger_OutsideARepositoryRecordsNothing(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	outside, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)

	runLedgerEvent(t, pid, withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), outside))
	assert.Empty(t, ledgerRows(t, database, row))
	assert.Equal(t, outside, storedCwd(t, database, row).Path, "the cwd column still records it")
}

func TestSessionStateLedger_NoCwdRecordsNothing(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	main := ledgerRepo(t)

	runLedgerEvent(t, pid, withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), ""))
	runLedgerEvent(t, pid, withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), "acme/relative"))
	runLedgerEvent(t, pid, withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), main+"\nx"))
	assert.Empty(t, ledgerRows(t, database, row))
}

// A nested `claude -p` inherits the row's env var but runs another
// conversation: its cwd is not the session's.
func TestSessionStateLedger_ForeignConversationRecordsNothing(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	main := ledgerRepo(t)

	runLedgerEvent(t, pid, withCwd(t, statePayload("UserPromptSubmit", nestedSessionID, ""), main))
	assert.Empty(t, ledgerRows(t, database, row))
}

// At most db.MaxSessionWorktrees pairs: a new one past the cap is dropped
// with one stderr line; the state write is unaffected.
func TestSessionStateLedger_StopsAtTheCap(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	main := ledgerRepo(t)
	for i := range db.MaxSessionWorktrees {
		_, err := database.RecordSessionWorktree(context.Background(), nil, row,
			fmt.Sprintf("/tmp/acme/wt-%d", i), "b", db.AgentStateStamp(hookNow()))
		require.NoError(t, err)
	}

	sessionLedgerFullReported.Store(false)
	t.Cleanup(func() { sessionLedgerFullReported.Store(false) })

	out, errOut, err := runSessionState(t, pid,
		strings.NewReader(withCwd(t, statePayload("UserPromptSubmit", briefLaunchID, ""), main)))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Equal(t, 1, strings.Count(errOut, "\n"), "one stderr line: %q", errOut)
	assert.Contains(t, errOut, "already records")
	assert.Len(t, ledgerRows(t, database, row), db.MaxSessionWorktrees)
	assert.Equal(t, "working", storedAgentState(t, database, row))

	// Within the same run a further new pair is dropped without a line.
	wt := ledgerWorktree(t, main, "wt", "ref: refs/heads/feat/x")
	out, errOut, err = runSessionState(t, pid,
		strings.NewReader(withCwd(t, statePayload("PostToolUse", briefLaunchID, ""), wt)))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut, "the full line is printed once per run")
	assert.Len(t, ledgerRows(t, database, row), db.MaxSessionWorktrees)
}

// A full session is known from one read: no write transaction is opened to
// find out (a query_only handle refuses any BEGIN IMMEDIATE).
func TestSessionStateLedger_AFullSessionTakesNoWriteLock(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	for i := range db.MaxSessionWorktrees {
		_, err := database.RecordSessionWorktree(context.Background(), nil, row,
			fmt.Sprintf("/tmp/acme/wt-%d", i), "b", db.AgentStateStamp(hookNow()))
		require.NoError(t, err)
	}
	require.NoError(t, database.SetReadOnly())

	err := writeSessionLedger(database, row, pid, briefLaunchID, "/tmp/acme/new", "b", hookNow())
	assert.ErrorIs(t, err, errSessionLedgerFull)
}

// The captured shape of a worktree-isolated subagent's PostToolUse (owner
// check, ask #197): agent_id set, cwd = the subagent's own worktree.
func TestSessionStateLedger_UsesTheFixture(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	main := ledgerRepo(t)
	wt := ledgerWorktree(t, main, ".claude/worktrees/agent-x", "ref: refs/heads/worktree-agent-x")
	input := fixtureInput(t, "posttooluse_subagent_worktree_cwd.json", `"/tmp/acme/`, `"`+main+`/`)
	require.Contains(t, input, `"agent_id"`)
	require.Contains(t, input, `"cwd": "`+wt+`"`)

	runLedgerEvent(t, pid, input)
	assert.Equal(t, []string{wt + "@worktree-agent-x"}, ledgerPairs(ledgerRows(t, database, row)))
	assert.Empty(t, storedCwd(t, database, row).Path, "a subagent's cwd is not the session's place")
}

// Codex hook payloads carry cwd too: its state hook records the ledger.
func TestCodexSessionStateLedger_RecordsTheCwd(t *testing.T) {
	const codexID = "01a10000-0000-7000-8000-000000000001"
	database, _, row := codexRowFixture(t, codexID)
	main := ledgerRepo(t)
	wt := ledgerWorktree(t, main, "wt", "ref: refs/heads/feat/codex")

	runCodexState(t, codexPayload(t, "post_tool_use", map[string]any{"cwd": wt}))
	runCodexState(t, codexPayload(t, "post_tool_use", map[string]any{"cwd": wt}))
	assert.Equal(t, []string{wt + "@feat/codex"}, ledgerPairs(ledgerRows(t, database, row)))
}
