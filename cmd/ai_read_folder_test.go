package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// readFolderFixture is a config whose claude is a stub that answers with its
// cwd and the flags it was given, a database, and one workbench bound to a
// folder.
type readFolderFixture struct {
	config string
	dbPath string
	folder string // resolved, as the workbench stores it
}

func newReadFolderFixture(t *testing.T) readFolderFixture {
	t.Helper()
	dir := t.TempDir()
	// The stub prints one v1 stream-json text event:
	// "<cwd>|<--disallowedTools>|<--setting-sources>|<--tools>".
	stub := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(stub, []byte(`#!/bin/sh
dis=""; src="unset"; tools="unset"
while [ $# -gt 0 ]; do
  case "$1" in
    --disallowedTools) dis="$2"; shift ;;
    --setting-sources) src="$2"; shift ;;
    --tools) tools="$2"; shift ;;
  esac
  shift
done
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s|%s|%s|%s"}]}}\n' "$(pwd -P)" "$dis" "$src" "$tools"
printf '{"type":"result","subtype":"success","result":"","session_id":"s1"}\n'
`), 0o755))

	config := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(config, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, stub), 0o600))

	dbPath := filepath.Join(dir, "wt.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	return readFolderFixture{config: config, dbPath: dbPath, folder: folder}
}

func (f readFolderFixture) run(t *testing.T, extra ...string) (code int, stdout []string, stderr string) {
	t.Helper()
	args := append([]string{"ai", "query", "--config", f.config, "--db-path", f.dbPath}, extra...)
	args = append(args, "--", "what does this do?")
	p := startCLI(t, args...)
	_ = p.stdin.Close()
	for line := range p.lines {
		stdout = append(stdout, line)
	}
	code = exitCode(p.wait())
	return code, stdout, p.stderr.String()
}

// TestAIQueryReadFolder_RefusesAFolderThatIsNoWorkbench: --read-folder takes
// only a workbench folder (exit 2, message on stderr, no provider started).
func TestAIQueryReadFolder_RefusesAFolderThatIsNoWorkbench(t *testing.T) {
	f := newReadFolderFixture(t)
	sub := filepath.Join(f.folder, "sub")
	require.NoError(t, os.Mkdir(sub, 0o755))

	for name, dir := range map[string]string{
		"unbound folder":   t.TempDir(),
		"workbench subdir": sub,
		"missing folder":   filepath.Join(f.folder, "gone"),
		"a file":           f.config,
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder", dir)
			assert.Equal(t, 2, code)
			assert.Contains(t, stderr, "--read-folder")
			assert.Empty(t, stdout, "no provider ran")
		})
	}
}

// A read-folder run never mounts the chat write tools.
func TestAIQueryReadFolder_RefusesToolsChat(t *testing.T) {
	f := newReadFolderFixture(t)
	code, stdout, stderr := f.run(t, "--read-folder", f.folder, "--tools", "chat")
	assert.Equal(t, 2, code)
	assert.Contains(t, stderr, "--tools")
	assert.Empty(t, stdout)
}

// TestAIQueryReadFolder_RunsClaudeInTheFolder: a workbench folder, named
// through a symlink, runs claude with cwd = the folder, the read tools
// allowed and unhidden and everything else still hidden, no settings files.
func TestAIQueryReadFolder_RunsClaudeInTheFolder(t *testing.T) {
	f := newReadFolderFixture(t)
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(f.folder, link))

	code, stdout, stderr := f.run(t, "--read-folder", link)
	require.Equal(t, 0, code, stderr)
	text := firstText(t, stdout)
	parts := strings.Split(text, "|")
	require.Len(t, parts, 4, text)
	assert.Equal(t, f.folder, parts[0], "cwd")
	disallowed := strings.Split(parts[1], ",")
	for _, tool := range []string{"Read", "Grep", "Glob", "LS"} {
		assert.NotContains(t, disallowed, tool)
	}
	for _, tool := range []string{"Edit", "Write", "Bash", "WebFetch", "WebSearch", "Task"} {
		assert.Contains(t, disallowed, tool)
	}
	assert.Empty(t, parts[2], "--setting-sources is empty")
	assert.Equal(t, "ToolSearch,Read,Grep,Glob,LS", parts[3], "the --tools allowlist adds only the reads")
}

// Without --read-folder the run is today's: temp-dir cwd, read tools hidden.
func TestAIQueryReadFolder_AbsentKeepsTodaysRun(t *testing.T) {
	f := newReadFolderFixture(t)
	code, stdout, stderr := f.run(t)
	require.Equal(t, 0, code, stderr)
	parts := strings.Split(firstText(t, stdout), "|")
	require.Len(t, parts, 4)
	assert.NotEqual(t, f.folder, parts[0])
	assert.Contains(t, strings.Split(parts[1], ","), "Read")
	assert.Equal(t, "project,local", parts[2])
	assert.Equal(t, "ToolSearch", parts[3])
}

// The codex provider gets the folder as its working root under the
// read-only sandbox; ollama has no file tools at all.
func TestAIQueryReadFolder_ProviderWiring(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}}
	codexClient := newAIClientWithModel(cfg, "", "gpt-5.4")
	_, ok := codexClient.(readFolderConfigurable)
	assert.True(t, ok, "codex reads the folder with its own tools")
	_, ok = newAIClientWithModel(&config.Config{AI: config.AIConfig{Provider: "claude"}}, "", "m").(readFolderConfigurable)
	assert.True(t, ok, "claude reads the folder with its own tools")
	_, ok = newAIClientWithModel(&config.Config{AI: config.AIConfig{Provider: "ollama"}}, "", "m").(readFolderConfigurable)
	assert.False(t, ok, "ollama has no file tools: a read-folder run answers from the prompt alone")
}

func firstText(t *testing.T, lines []string) string {
	t.Helper()
	for _, line := range lines {
		var ev aiStreamEvent
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		if ev.Type == "error" {
			t.Fatalf("error event: %s", ev.Error)
		}
		if ev.Type == "text" {
			return ev.Text
		}
	}
	t.Fatalf("no text event in %v", lines)
	return ""
}

// readFolderRepo makes dir a main work tree (a ".git" directory, files only:
// the read-folder check never runs git) and returns its git dir.
func readFolderRepo(t *testing.T, dir string) string {
	t.Helper()
	gitDir := filepath.Join(dir, ".git")
	require.NoError(t, os.MkdirAll(gitDir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/main\n"), 0o644))
	return gitDir
}

// readFolderWorktree adds a linked work tree of the repository at gitDir in
// a new temp dir (resolved), laid out the way `git worktree add` writes it.
func readFolderWorktree(t *testing.T, gitDir, name string) string {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	dir := filepath.Join(base, name)
	admin := filepath.Join(gitDir, "worktrees", name)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	require.NoError(t, os.MkdirAll(admin, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(admin, "HEAD"), []byte("ref: refs/heads/"+name+"\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(admin, "commondir"), []byte("../..\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(admin, "gitdir"), []byte(filepath.Join(dir, ".git")+"\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".git"), []byte("gitdir: "+admin+"\n"), 0o644))
	return dir
}

// readFolderSessions numbers the fixture sessions' agent ids.
var readFolderSessions atomic.Int64

// recordWorktree records root in the ledger of a new session of
// the workbench bound to folder.
func (f readFolderFixture) recordWorktree(t *testing.T, folder, root string) {
	t.Helper()
	database, err := db.Open(f.dbPath)
	require.NoError(t, err)
	defer func() { _ = database.Close() }()
	wb, err := database.WorkbenchByFolder(folder)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, wb.ID, root, fmt.Sprintf("11111111-2222-4333-8444-%012d", readFolderSessions.Add(1)))
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = database.RecordSessionWorktree(context.Background(), nil, row, root, "b",
		db.AgentStateStamp(time.Now()))
	require.NoError(t, err)
}

// TestAIQueryReadFolder_AcceptsARegisteredSessionWorktree (owner, ask #560):
// a session worktree of the workbench, recorded in its ledger, is a read
// folder too — named directly or through a symlink, the run's cwd is its
// real path.
func TestAIQueryReadFolder_AcceptsARegisteredSessionWorktree(t *testing.T) {
	f := newReadFolderFixture(t)
	wt := readFolderWorktree(t, readFolderRepo(t, f.folder), "feature")
	f.recordWorktree(t, f.folder, wt)
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(wt, link))

	for name, dir := range map[string]string{"real path": wt, "symlink": link} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder", dir)
			require.Equal(t, 0, code, stderr)
			parts := strings.Split(firstText(t, stdout), "|")
			require.Len(t, parts, 4)
			assert.Equal(t, wt, parts[0], "cwd")
			assert.Empty(t, parts[2], "--setting-sources is empty")
			assert.Equal(t, "ToolSearch,Read,Grep,Glob,LS", parts[3])
		})
	}
	t.Run("the workbench folder still", func(t *testing.T) {
		code, stdout, stderr := f.run(t, "--read-folder", f.folder)
		require.Equal(t, 0, code, stderr)
		assert.Equal(t, f.folder, strings.Split(firstText(t, stdout), "|")[0])
	})
}

// Everything else stays refused: a worktree no session recorded, a
// recorded root that is no worktree of the workbench's repository (another
// workbench's), a folder inside a recorded worktree (named directly or
// through a symlink), a sibling of one, a recorded root later replaced by a
// symlink, a recorded main checkout of the workbench's repository (the
// workbench bound to a subfolder of it), and recorded folders an agent
// dressed up as worktrees of the workbench's repository: a ".git" file
// pointing at its git dir, one reusing another worktree's admin dir, and a
// ".git" symlink to its git dir.
func TestAIQueryReadFolder_RefusesWhatIsNoRegisteredWorktree(t *testing.T) {
	f := newReadFolderFixture(t)
	gitDir := readFolderRepo(t, f.folder)
	wt := readFolderWorktree(t, gitDir, "feature")
	f.recordWorktree(t, f.folder, wt)
	unrecorded := readFolderWorktree(t, gitDir, "other")

	// Another workbench, its own repository and worktree; a session of the
	// first workbench recorded that worktree (its agent cd'd there).
	other, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	database, err := db.Open(f.dbPath)
	require.NoError(t, err)
	_, err = database.CreateWorkbench("beta", other)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	foreign := readFolderWorktree(t, readFolderRepo(t, other), "foreign")
	f.recordWorktree(t, f.folder, foreign)

	sub := filepath.Join(wt, "pkg")
	require.NoError(t, os.Mkdir(sub, 0o755))
	linkIn := filepath.Join(t.TempDir(), "into")
	require.NoError(t, os.Symlink(sub, linkIn))
	sibling := filepath.Join(filepath.Dir(wt), "sibling")
	require.NoError(t, os.Mkdir(sibling, 0o755))

	replaced := readFolderWorktree(t, gitDir, "replaced")
	f.recordWorktree(t, f.folder, replaced)
	require.NoError(t, os.RemoveAll(replaced))
	require.NoError(t, os.Symlink(unrecorded, replaced))

	// A workbench bound to a subfolder of a repository; a session of it
	// recorded the repository root (its main checkout).
	repoRoot, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	readFolderRepo(t, repoRoot)
	app := filepath.Join(repoRoot, "app")
	require.NoError(t, os.Mkdir(app, 0o755))
	database, err = db.Open(f.dbPath)
	require.NoError(t, err)
	_, err = database.CreateWorkbench("gamma", app)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	f.recordWorktree(t, app, repoRoot)

	plant := func(name, gitEntry string, symlink bool) string {
		base, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)
		dir := filepath.Join(base, name)
		require.NoError(t, os.Mkdir(dir, 0o755))
		if symlink {
			require.NoError(t, os.Symlink(gitEntry, filepath.Join(dir, ".git")))
		} else {
			require.NoError(t, os.WriteFile(filepath.Join(dir, ".git"), []byte("gitdir: "+gitEntry+"\n"), 0o644))
		}
		f.recordWorktree(t, f.folder, dir)
		return dir
	}
	atGitDir := plant("at-git-dir", gitDir, false)
	// ...with a back-pointer forged in the git dir too: no commondir.
	require.NoError(t, os.WriteFile(filepath.Join(gitDir, "gitdir"), []byte(filepath.Join(atGitDir, ".git")+"\n"), 0o644))
	reusedAdmin := plant("reused-admin", filepath.Join(gitDir, "worktrees", "feature"), false)
	symlinked := plant("symlinked", gitDir, true)

	for name, dir := range map[string]string{
		"recorded root replaced by a symlink": replaced,
		"recorded main checkout":              repoRoot,
		"forged pointer at the git dir":       atGitDir,
		"forged pointer at another admin dir": reusedAdmin,
		"git dir symlinked into a folder":     symlinked,
		"unrecorded worktree":                 unrecorded,
		"another workbench's worktree":        foreign,
		"folder inside a worktree":            sub,
		"symlink into a worktree":             linkIn,
		"sibling of a recorded worktree":      sibling,
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder", dir)
			assert.Equal(t, 2, code)
			assert.Contains(t, stderr, "--read-folder")
			assert.Empty(t, stdout, "no provider ran")
		})
	}
}
