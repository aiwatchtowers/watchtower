package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/tools"
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
// read-only sandbox; ollama has no file tools at all, so its run is refused.
func TestAIQueryReadFolder_ProviderWiring(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}}
	codexClient := buildQuerier(cfg, transport.Options{Model: "gpt-5.4", ReadFolder: "/work"})
	assert.Contains(t, codexClient.(*codex.Client).ArgsForTest("sys", "user"), "/work", "codex reads the folder with its own tools")
	assert.True(t, providers.ByID("claude").Caps.ReadsFolder(), "claude reads the folder with its own tools")
	assert.False(t, providers.ByID("ollama").Caps.ReadsFolder(), "ollama has no file tools: a read-folder run is refused (TestAIQuery_ReadFolderWithoutFileToolsIsRefused)")
}

// TestAIQuery_ReadFolderWithoutFileToolsIsRefused (L9): a provider with no
// file tools refuses --read-folder before any model call — non-zero exit and
// a v2 error with reason required_capability_missing — instead of quietly
// answering from the prompt alone.
func TestAIQuery_ReadFolderWithoutFileToolsIsRefused(t *testing.T) {
	f := newReadFolderFixture(t)
	var hits atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		http.Error(w, "must not be called", http.StatusTeapot)
	}))
	t.Cleanup(model.Close)
	require.NoError(t, os.WriteFile(f.config, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
ai:
  provider: ollama
  ollama_url: %q
  models:
    strong: llama
`, model.URL), 0o600))

	code, stdout, stderr := f.run(t, "--read-folder", f.folder, "--events", "v2")
	assert.NotEqual(t, 0, code, "the refusal is a failed command")
	assert.Contains(t, stderr, "read")
	assert.Zero(t, hits.Load(), "no model call")

	var errEv *chat.Event
	for _, line := range stdout {
		var ev chat.Event
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		if ev.Type == chat.EventError {
			errEv = &ev
		}
		assert.NotEqual(t, chat.EventTextDelta, ev.Type, "no answer from the prompt alone")
	}
	require.NotNil(t, errEv, "a v2 error event: %v", stdout)
	assert.Equal(t, "required_capability_missing", errEv.Reason)
	assert.False(t, errEv.Retryable)
	assert.NotEmpty(t, errEv.Message)

	// v1: the same refusal as an error event, then done.
	code, stdout, _ = f.run(t, "--read-folder", f.folder)
	assert.NotEqual(t, 0, code)
	assert.Zero(t, hits.Load(), "no model call")
	var types []string
	var v1Err aiStreamEvent
	for _, line := range stdout {
		var ev aiStreamEvent
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		types = append(types, ev.Type)
		if ev.Type == "error" {
			v1Err = ev
		}
	}
	assert.Equal(t, []string{"error", "done"}, types)
	assert.Equal(t, "required_capability_missing", v1Err.Reason)
	assert.False(t, v1Err.Retryable)
}

// With fallback routing on, the router's leaf refuses the same way: a
// capability error with the required_capability_missing reason, not an
// untyped retryable one.
func TestAIQuery_ReadFolderRoutedLeafWithoutFileToolsIsRefused(t *testing.T) {
	p := &toolRouteProvider{readFolder: t.TempDir()}
	err := p.checkLeaf("ollama")
	var failure *providers.Failure
	require.ErrorAs(t, err, &failure)
	assert.Equal(t, providers.Capability, failure.Category)
	assert.Equal(t, "ollama", failure.Provider)
	_, reason, retry := queryErrorClass(err)
	assert.Equal(t, "required_capability_missing", reason)
	assert.False(t, retry)
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

// addAsk files an ask of kind/docType on the fixture's workbench, bound to a
// new claude session whose recorded working directory is cwd ("" = none,
// and no session when bound is false); it returns the ask id.
func (f readFolderFixture) addAsk(t *testing.T, kind, docType string, bound bool, cwd string) int64 {
	t.Helper()
	database, err := db.Open(f.dbPath)
	require.NoError(t, err)
	defer func() { _ = database.Close() }()
	wb, err := database.WorkbenchByFolder(f.folder)
	require.NoError(t, err)
	ask := db.OwnerAsk{WorkbenchID: wb.ID, Kind: kind, Title: "Spec", DocType: docType}
	if kind == "review" {
		ask.DocPath, ask.DocSnapshot = "docs/x-design.md", "# X\n"
	}
	if bound {
		var cwdArg any
		if cwd != "" {
			cwdArg = cwd
		}
		res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_cwd)
			VALUES (?, 'claude', 's', ?, 'agent-1', ?)`, wb.ID, f.folder, cwdArg)
		require.NoError(t, err)
		sid, err := res.LastInsertId()
		require.NoError(t, err)
		ask.SessionID = sql.NullInt64{Int64: sid, Valid: true}
	}
	var id int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		id, _, err = database.InsertOwnerAsk(tx, ask)
		return err
	}))
	return id
}

// TestAIQueryReadFolderAsk_ReadsTheReviewersFolder: --read-folder-ask N runs
// in the folder specreview.ReadFolder gives the reviewer of ask N — the
// session's recorded working directory (its worktree), else the workbench
// folder — symlink-resolved.
func TestAIQueryReadFolderAsk_ReadsTheReviewersFolder(t *testing.T) {
	f := newReadFolderFixture(t)
	worktree, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	// A recorded cwd that is now a symlink: the reviewer reads the same raw
	// path, so both end up in its target.
	link := filepath.Join(t.TempDir(), "moved")
	require.NoError(t, os.Symlink(worktree, link))

	for name, tc := range map[string]struct {
		ask  int64
		want string
	}{
		"session worktree":     {f.addAsk(t, "review", "spec", true, worktree), worktree},
		"no recorded cwd":      {f.addAsk(t, "review", "plan", true, ""), f.folder},
		"no session":           {f.addAsk(t, "review", "spec", false, ""), f.folder},
		"cwd gone":             {f.addAsk(t, "review", "spec", true, filepath.Join(worktree, "gone")), f.folder},
		"cwd is now a symlink": {f.addAsk(t, "review", "spec", true, link), worktree},
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder-ask", strconv.FormatInt(tc.ask, 10))
			require.Equal(t, 0, code, stderr)
			parts := strings.Split(firstText(t, stdout), "|")
			require.Len(t, parts, 4)
			assert.Equal(t, tc.want, parts[0], "cwd")
			assert.Equal(t, "ToolSearch,Read,Grep,Glob,LS", parts[3], "a read-folder run")
		})
	}
}

// TestAIQueryReadFolderAsk_Refusals: no provider runs (exit 2) for an ask
// that is not a spec/plan review, an unknown ask, or the flag combined with
// --read-folder or --tools.
func TestAIQueryReadFolderAsk_Refusals(t *testing.T) {
	f := newReadFolderFixture(t)
	review := strconv.FormatInt(f.addAsk(t, "review", "spec", false, ""), 10)
	for name, tc := range map[string]struct {
		args []string
		text string
	}{
		"question ask":     {[]string{"--read-folder-ask", strconv.FormatInt(f.addAsk(t, "question", "", false, ""), 10)}, "not a spec or plan review"},
		"other review":     {[]string{"--read-folder-ask", strconv.FormatInt(f.addAsk(t, "review", "other", false, ""), 10)}, "not a spec or plan review"},
		"unknown ask":      {[]string{"--read-folder-ask", "999999"}, "--read-folder-ask 999999"},
		"with read-folder": {[]string{"--read-folder-ask", review, "--read-folder", f.folder}, "not both"},
		"with tools":       {[]string{"--read-folder-ask", review, "--tools", "chat"}, "without --tools"},
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, tc.args...)
			assert.Equal(t, 2, code)
			assert.Contains(t, stderr, tc.text)
			assert.Empty(t, stdout, "no provider ran")
		})
	}
}

// resolveReviewReadFolder hands the provider the symlink-resolved path (the
// stub's `pwd -P` cannot tell a link from its target).
func TestResolveReviewReadFolder_ResolvesASymlinkedCwd(t *testing.T) {
	f := newReadFolderFixture(t)
	worktree, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	link := filepath.Join(t.TempDir(), "moved")
	require.NoError(t, os.Symlink(worktree, link))
	got, err := resolveReviewReadFolder(f.dbPath, f.addAsk(t, "review", "spec", true, link))
	require.NoError(t, err)
	assert.Equal(t, worktree, got)
}

// roundFixture is newReadFolderFixture plus a git repository (main + a
// feature branch) with an "app" subfolder, a linked worktree of it on the
// feature branch, and a session on a workbench bound to folder (the repo's
// top or its app subfolder) whose agent works in the worktree at cwd.
type roundFixture struct {
	readFolderFixture
	repo, worktree string
}

func newRoundFixture(t *testing.T) roundFixture {
	t.Helper()
	f := newReadFolderFixture(t)
	repo := gitBranchRepo(t)
	require.NoError(t, os.MkdirAll(filepath.Join(repo, "app"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "app", "main.go"), []byte("package app\n"), 0o644))
	reviewGit(t, repo, "add", "app")
	reviewGit(t, repo, "commit", "-q", "-m", "app")
	wt := filepath.Join(t.TempDir(), "wt")
	reviewGit(t, repo, "worktree", "add", "-q", wt, "feature")
	wt, err := filepath.EvalSymlinks(wt)
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(filepath.Join(wt, "app"), 0o755))
	return roundFixture{readFolderFixture: f, repo: repo, worktree: wt}
}

// startRound records a round the way `workbench review start` does: the
// session's review place from tools.ResolveReviewSource, its folder stored
// as review_rounds.folder_root. A workbench bound to folder is created on
// first use; the session's agent works in cwd; branch, when set, is the
// session's ticket branch. It returns the round's id and source.
func (f roundFixture) startRound(t *testing.T, folder, cwd, branch string) (int64, string) {
	t.Helper()
	database, err := db.Open(f.dbPath)
	require.NoError(t, err)
	defer func() { _ = database.Close() }()
	wb, err := database.WorkbenchByFolder(folder)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		_, err = database.CreateWorkbench("app", folder)
		require.NoError(t, err)
		wb, err = database.WorkbenchByFolder(folder)
	}
	require.NoError(t, err)
	s := reviewSession(t, database, wb.ID, folder)
	_, err = database.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-16T10:00:00Z' WHERE id = ?`, cwd, s)
	require.NoError(t, err)
	if branch != "" {
		ticketTarget(t, database, wb.ID, s, 0, branch, true)
	}
	src, _, err := tools.ResolveReviewSource(context.Background(), database, wb, s)
	require.NoError(t, err)
	id, err := database.CreateReviewRound(db.ReviewRound{ProjectID: wb.ID, SessionID: sql.NullInt64{Int64: s, Valid: true},
		Source: src.Source(), Branch: src.Branch(), FolderRoot: src.Folder, BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	return id, src.Source()
}

// setRoundFolder overwrites round id's recorded folder.
func (f readFolderFixture) setRoundFolder(t *testing.T, id int64, folder string) {
	t.Helper()
	database, err := db.Open(f.dbPath)
	require.NoError(t, err)
	defer func() { _ = database.Close() }()
	_, err = database.Exec(`UPDATE review_rounds SET folder_root = ? WHERE id = ?`, folder, id)
	require.NoError(t, err)
}

// TestAIQueryReadFolderRound_ReadsTheRoundsFolder (owner, ask #611):
// --read-folder-round N runs in the folder review round N was taken from —
// the session's worktree, the workbench's subfolder inside it, or for a
// branch-tip round the session's folder — symlink-resolved.
func TestAIQueryReadFolderRound_ReadsTheRoundsFolder(t *testing.T) {
	f := newRoundFixture(t)
	app := filepath.Join(f.repo, "app")
	inWorktree, source := f.startRound(t, f.repo, f.worktree, "")
	require.Equal(t, db.ReviewSourceFolder, source)
	subfolder, _ := f.startRound(t, app, filepath.Join(f.worktree, "app"), "")
	tip, source := f.startRound(t, f.repo, f.repo, "feature")
	require.Equal(t, db.ReviewSourceBranch, source, "the folder is on main: the round reads the branch tip")
	moved, _ := f.startRound(t, f.repo, f.worktree, "")
	link := filepath.Join(t.TempDir(), "moved")
	require.NoError(t, os.Symlink(f.worktree, link))
	f.setRoundFolder(t, moved, link)

	for name, tc := range map[string]struct {
		round int64
		want  string
	}{
		"session worktree":                 {inWorktree, f.worktree},
		"subfolder workbench in worktree":  {subfolder, filepath.Join(f.worktree, "app")},
		"branch-tip round":                 {tip, f.repo},
		"recorded folder is now a symlink": {moved, f.worktree},
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder-round", strconv.FormatInt(tc.round, 10))
			require.Equal(t, 0, code, stderr)
			parts := strings.Split(firstText(t, stdout), "|")
			require.Len(t, parts, 4)
			assert.Equal(t, tc.want, parts[0], "cwd")
			assert.Equal(t, "ToolSearch,Read,Grep,Glob,LS", parts[3], "a read-folder run")
		})
	}

	// --read-folder itself still takes only a workbench folder: the round's
	// worktree is refused there.
	code, stdout, stderr := f.run(t, "--read-folder", f.worktree)
	assert.Equal(t, 2, code)
	assert.Contains(t, stderr, "not a workbench folder")
	assert.Empty(t, stdout)
}

// TestAIQueryReadFolderRound_Refusals: no provider runs (exit 2, the flag and
// the id on stderr) for a bad id, an unknown round, a folder that is gone or
// not a directory, an unopenable database, or the flag combined with
// --read-folder, --read-folder-ask or --tools. Nothing falls back to the
// workbench folder.
func TestAIQueryReadFolderRound_Refusals(t *testing.T) {
	f := newRoundFixture(t)
	round := func(folder string) string {
		id, _ := f.startRound(t, f.repo, f.worktree, "")
		f.setRoundFolder(t, id, folder)
		return strconv.FormatInt(id, 10)
	}
	ok := round(f.worktree)
	gone := round(filepath.Join(f.worktree, "gone"))
	file := round(filepath.Join(f.repo, "README.md"))
	ask := strconv.FormatInt(f.addAsk(t, "review", "spec", false, ""), 10)
	for name, tc := range map[string]struct {
		args []string
		text string
	}{
		"negative id":       {[]string{"--read-folder-round", "-3"}, "--read-folder-round -3: not a review round id"},
		"unknown round":     {[]string{"--read-folder-round", "999999"}, "--read-folder-round 999999: no such review round"},
		"folder gone":       {[]string{"--read-folder-round", gone}, "--read-folder-round " + gone},
		"not a directory":   {[]string{"--read-folder-round", file}, "--read-folder-round " + file + ": not a directory"},
		"database unusable": {[]string{"--read-folder-round", ok, "--db-path", filepath.Join(f.config, "wt.db")}, "--read-folder-round: opening the database"},
		"with read-folder":  {[]string{"--read-folder-round", ok, "--read-folder", f.folder}, "give one of"},
		"with ask":          {[]string{"--read-folder-round", ok, "--read-folder-ask", ask}, "give one of"},
		"with tools":        {[]string{"--read-folder-round", ok, "--tools", "chat"}, "--read-folder-round runs without --tools"},
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, tc.args...)
			assert.Equal(t, 2, code)
			assert.Contains(t, stderr, tc.text)
			assert.Empty(t, stdout, "no provider ran")
		})
	}
}

// A round's folder on a provider with no file tools (ollama) is refused
// before any model call, as --read-folder is.
func TestAIQueryReadFolderRound_WithoutFileToolsIsRefused(t *testing.T) {
	f := newRoundFixture(t)
	id, _ := f.startRound(t, f.repo, f.worktree, "")
	var hits atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		http.Error(w, "must not be called", http.StatusTeapot)
	}))
	t.Cleanup(model.Close)
	require.NoError(t, os.WriteFile(f.config, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
ai:
  provider: ollama
  ollama_url: %q
  models:
    strong: llama
`, model.URL), 0o600))

	code, stdout, _ := f.run(t, "--read-folder-round", strconv.FormatInt(id, 10))
	assert.NotEqual(t, 0, code)
	assert.Zero(t, hits.Load(), "no model call")
	require.NotEmpty(t, stdout)
	var ev aiStreamEvent
	require.NoError(t, json.Unmarshal([]byte(stdout[0]), &ev), stdout[0])
	assert.Equal(t, "error", ev.Type)
	assert.Equal(t, "required_capability_missing", ev.Reason)
}
