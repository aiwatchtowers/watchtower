package coach

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchmethod"
)

// git runs git in dir for a test's own setup (the coach itself never runs
// git: TestCOACH01_NoGitWrites), with the owner's config kept out.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	c := exec.Command(bin, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com")
	var stderr bytes.Buffer
	c.Stderr = &stderr
	out, err := c.Output()
	require.NoError(t, err, "git %s: %s", strings.Join(args, " "), stderr.String())
	return strings.TrimSpace(string(out))
}

// repoFolderWith is a git repository (symlinks resolved, as projects stores
// it) whose one commit holds files (relative path → text, mode 0644).
func repoFolderWith(t *testing.T, files map[string]string) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	git(t, dir, "init", "-q", "-b", "main")
	files["README.md"] = "acme\n"
	for rel, text := range files {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
		require.NoError(t, os.WriteFile(p, []byte(text), 0o644))
	}
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "init")
	return dir
}

// fullRepo holds every repository file but AGENTS.md.
func fullRepo(t *testing.T) string {
	return repoFolderWith(t, map[string]string{
		"CLAUDE.md":                     "Run tests.\n",
		".claude/skills/a/SKILL.md":     "Read the plan.\n",
		".agents/skills/b/SKILL.md":     "Read the board.\n",
		workbenchmethod.FileRel:         "# Workflow\n",
		".claude/skills/mine/SKILL.md":  "---\nname: mine\n" + devpack.MarkerKey + ": 1\n---\nBody.\n",
		".claude/skills/other/SKILL.md": "Other.\n",
	})
}

// gitState is a RepoState over the test's own git: what `git status
// --porcelain=v1 -z -- <rel>` says; calls counts its calls.
type gitState struct{ calls int }

func (g *gitState) read(t *testing.T) func(folder, rel string) (RepoFileState, error) {
	return func(folder, rel string) (RepoFileState, error) {
		g.calls++
		c := exec.Command("git", "rev-parse", "--is-inside-work-tree")
		c.Dir = folder
		if out, err := c.Output(); err != nil || strings.TrimSpace(string(out)) != "true" {
			return RepoFileState{}, nil
		}
		return RepoFileState{Git: true, Dirty: git(t, folder, "status", "--porcelain=v1", "-z", "--", rel) != ""}, nil
	}
}

// repoApplier is an Applier whose RepoState reads the real git state.
func repoApplier(t *testing.T, d dbs) (*Applier, *gitState) {
	t.Helper()
	g := &gitState{}
	a := newApplier(t, d)
	a.RepoState = g.read(t)
	return a, g
}

func repoWorkbench(t *testing.T, d dbs, folder string) int64 {
	t.Helper()
	wb, err := d.CreateWorkbench("acme-"+filepath.Base(folder), folder)
	require.NoError(t, err)
	return wb
}

func repoProposal(dest string, wb int64, skill, before, after string) db.CoachProposal {
	return db.CoachProposal{Destination: dest, WorkbenchID: wb, Skill: skill, Kind: "replace",
		BeforeText: before, AfterText: after}
}

func TestRepoRelPath(t *testing.T) {
	for _, c := range []struct{ dest, skill, want string }{
		{DestRepoClaudeMD, "", "CLAUDE.md"},
		{DestRepoAgentsMD, "", "AGENTS.md"},
		{DestRepoClaudeSkill, "a", ".claude/skills/a/SKILL.md"},
		{DestRepoCodexSkill, "a", ".agents/skills/a/SKILL.md"},
		{DestRepoWorkflow, "", workbenchmethod.FileRel},
	} {
		got, ok := RepoRelPath(c.dest, c.skill)
		require.True(t, ok, c.dest)
		assert.Equal(t, c.want, got, c.dest)
	}
	assert.Equal(t, ".watchtower/workflow.md", workbenchmethod.FileRel)
	for _, bad := range []string{"", "a/b", "..", ".hidden", "a|b"} {
		_, ok := RepoRelPath(DestRepoClaudeSkill, bad)
		assert.False(t, ok, bad)
		_, ok = RepoRelPath(DestRepoCodexSkill, bad)
		assert.False(t, ok, bad)
	}
	for _, dest := range []string{DestClaudeMDUser, DestCodexAgentsMDUser, "repo_readme", ""} {
		_, ok := RepoRelPath(dest, "")
		assert.False(t, ok, dest)
	}
}

func TestValidateChatProposal_RepoArgs(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	noFlow := repoFolderWith(t, map[string]string{"CLAUDE.md": "x\n"})
	wbNoFlow := repoWorkbench(t, d, noFlow)
	plain := t.TempDir()
	wbPlain := repoWorkbench(t, d, plain)
	g := &gitState{}
	env := Env{Home: t.TempDir(), RepoState: g.read(t)}

	edit := func(dest string, wb int64, skill string) ChatEdit {
		return ChatEdit{Destination: dest, WorkbenchID: wb, Skill: skill, Kind: "add", Replace: "Check the board.",
			Title: "Check the board first", Why: "The owner asked for it twice.", Metric: "corrections",
			Evidence: []string{"c7"}}
	}
	with := func(e ChatEdit, f func(e *ChatEdit)) ChatEdit { f(&e); return e }
	for _, c := range []struct {
		name string
		edit ChatEdit
		want string
	}{
		{"no workbench_id", edit(DestRepoClaudeMD, 0, ""), "repo_claude_md needs workbench_id"},
		{"missing workbench", edit(DestRepoClaudeMD, 999, ""), "workbench 999 not found"},
		{"prompt_id set", with(edit(DestRepoClaudeMD, wb, ""), func(e *ChatEdit) { e.PromptID = "digest.channel" }),
			"repo_claude_md takes no prompt_id"},
		{"skill missing", edit(DestRepoClaudeSkill, wb, ""), "repo_claude_skill needs skill"},
		{"skill on CLAUDE.md", edit(DestRepoClaudeMD, wb, "a"), "repo_claude_md takes no skill"},
		{"skill with a slash", edit(DestRepoCodexSkill, wb, "a/b"), `"a/b" is not a skill name`},
		{"skill ..", edit(DestRepoClaudeSkill, wb, ".."), `".." is not a skill name`},
		{"missing skill", edit(DestRepoClaudeSkill, wb, "zzz"), "skill zzz not found"},
		{"missing codex skill", edit(DestRepoCodexSkill, wb, "a"), "skill a not found"},
		{"missing workflow.md", edit(DestRepoWorkflow, wbNoFlow, ""), ".watchtower/workflow.md not found"},
		{"pack skill copy", edit(DestRepoClaudeSkill, wb, "mine"), "mine is a Watchtower pack skill: propose a pack_overlay"},
		{"pack skill name", edit(DestRepoClaudeSkill, wb, devpack.WorkbenchSkillName),
			devpack.WorkbenchSkillName + " is a Watchtower pack skill: propose a pack_overlay"},
		{"not a git repository", edit(DestRepoClaudeMD, wbPlain, ""), RepoNotGitLine},
	} {
		_, err := ValidateChatProposal(context.Background(), d.DB, c.edit, env)
		require.Error(t, err, c.name)
		assert.ErrorIs(t, err, ErrRefused, c.name)
		assert.Equal(t, c.want, err.Error(), c.name)
		assert.NotContains(t, err.Error(), folder, c.name)
	}

	// Each of the five passes, CLAUDE.md even uncommitted (Accept checks
	// that), AGENTS.md missing (created by Accept, before "").
	require.NoError(t, os.WriteFile(filepath.Join(folder, "CLAUDE.md"), []byte("Run tests.\nOwner's draft.\n"), 0o644))
	for _, e := range []ChatEdit{edit(DestRepoClaudeMD, wb, ""), edit(DestRepoAgentsMD, wb, ""),
		edit(DestRepoClaudeSkill, wb, "a"), edit(DestRepoCodexSkill, wb, "b"), edit(DestRepoWorkflow, wb, "")} {
		p, err := ValidateChatProposal(context.Background(), d.DB, e, env)
		require.NoError(t, err, e.Destination)
		assert.Equal(t, wb, p.WorkbenchID, e.Destination)
		assert.Equal(t, e.Skill, p.Skill, e.Destination)
		assert.True(t, strings.HasSuffix(p.AfterText, "Check the board."), e.Destination)
		if e.Destination == DestRepoAgentsMD {
			assert.Empty(t, p.BeforeText)
		}
	}
	// A symlinked folder on the way is refused before git reads the path.
	other := t.TempDir()
	writeFile(t, filepath.Join(other, "skills", "x", "SKILL.md"), "X")
	require.NoError(t, os.RemoveAll(filepath.Join(noFlow, ".claude")))
	require.NoError(t, os.Symlink(other, filepath.Join(noFlow, ".claude")))
	calls := g.calls
	_, err := ValidateChatProposal(context.Background(), d.DB, edit(DestRepoClaudeSkill, wbNoFlow, "x"), env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, "SKILL.md is a symlink, not a regular file, too large or not text", err.Error())
	assert.Equal(t, calls, g.calls, "no git read through a link")
}

func TestAccept_RepoFileWritesAndRunsNoGitWrite(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	head := git(t, folder, "rev-parse", "HEAD")
	a, _ := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))

	r, err := a.Accept(id, "")
	require.NoError(t, err)
	assert.Equal(t, "CLAUDE.md", r.WrittenPath)
	assert.Equal(t, "Run package tests only.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))
	fi, err := os.Stat(filepath.Join(folder, "CLAUDE.md"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o644), fi.Mode().Perm(), "mode kept")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	assert.Equal(t, "M CLAUDE.md", git(t, folder, "status", "--porcelain=v1"), "modified in the work tree only")
	assert.Empty(t, git(t, folder, "diff", "--cached"), "nothing staged")
	assert.Equal(t, head, git(t, folder, "rev-parse", "HEAD"), "no commit")

	// A skill: the written path names it.
	id = propose(t, d, repoProposal(DestRepoCodexSkill, wb, "b", "Read the board.\n", "Read the board first.\n"))
	r, err = a.Accept(id, "")
	require.NoError(t, err)
	assert.Equal(t, ".agents/skills/b/SKILL.md", r.WrittenPath)
	// Every other destination writes no path.
	id = propose(t, d, db.CoachProposal{Destination: DestChat, BeforeText: "", AfterText: "Be brief."})
	r, err = a.Accept(id, "")
	require.NoError(t, err)
	assert.Empty(t, r.WrittenPath)
}

func TestAccept_RepoFileDirtyRefused(t *testing.T) {
	for _, c := range []struct {
		name  string
		dirty func(t *testing.T, folder string)
	}{
		{"unstaged", func(t *testing.T, folder string) {
			writeFile(t, filepath.Join(folder, "CLAUDE.md"), "Run tests.\n")
			require.NoError(t, os.Chmod(filepath.Join(folder, "CLAUDE.md"), 0o755))
		}},
		{"staged", func(t *testing.T, folder string) {
			writeFile(t, filepath.Join(folder, "CLAUDE.md"), "Run tests.\nStaged.\n")
			git(t, folder, "add", "CLAUDE.md")
			writeFile(t, filepath.Join(folder, "CLAUDE.md"), "Run tests.\n")
		}},
		{"untracked", func(t *testing.T, folder string) {
			git(t, folder, "rm", "-q", "--cached", "CLAUDE.md")
			git(t, folder, "commit", "-q", "-m", "untrack")
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := openDBs(t)
			folder := fullRepo(t)
			wb := repoWorkbench(t, d, folder)
			a, _ := repoApplier(t, d)
			id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))
			c.dirty(t, folder)
			_, err := a.Accept(id, "")
			require.ErrorIs(t, err, ErrRepoDirty)
			assert.Contains(t, err.Error(), "CLAUDE.md has uncommitted changes — commit or discard them, then press Accept again.")
			assert.NotContains(t, err.Error(), folder)
			assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")), "file untouched")
			assert.Equal(t, "open", proposal(t, d, id).Status)
		})
	}
}

func TestAccept_RepoFileIgnoredIsClean(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{".gitignore": "AGENTS.md\n"})
	writeFile(t, filepath.Join(folder, "AGENTS.md"), "Local notes.\n")
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoAgentsMD, wb, "", "Local notes.\n", "Local notes.\nRun tests.\n"))
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, "Local notes.\nRun tests.\n", readFile(t, filepath.Join(folder, "AGENTS.md")))
}

func TestAccept_RepoFolderNotGitRefused(t *testing.T) {
	d := openDBs(t)
	folder := t.TempDir()
	writeFile(t, filepath.Join(folder, "CLAUDE.md"), "Run tests.\n")
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))
	err := a.acceptErr(id, "")
	require.ErrorIs(t, err, ErrRepoNotGit)
	assert.Contains(t, err.Error(), RepoNotGitLine)
	assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestAccept_RepoClaudeMDCreatedAndRollbackDeletes(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{})
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	path := filepath.Join(folder, "CLAUDE.md")

	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "", "Run tests.\n"))
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, "Run tests.\n", readFile(t, path))
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o644), fi.Mode().Perm(), "a repository file's mode")
	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	assert.NoFileExists(t, path, "a created file goes again")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
	assert.Empty(t, git(t, folder, "status", "--porcelain=v1"))

	// Changed by the owner since: kept, with the diff.
	id = propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "", "Run lint.\n"))
	require.NoError(t, a.acceptErr(id, ""))
	writeFile(t, path, "Run lint.\nMine.\n")
	diff, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Contains(t, diff, "+Mine.")
	assert.Equal(t, "Run lint.\nMine.\n", readFile(t, path))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

func TestAccept_RepoSymlinkedFolderRefused(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{})
	other := t.TempDir()
	writeFile(t, filepath.Join(other, "skills", "a", "SKILL.md"), "Read the plan.\n")
	require.NoError(t, os.Symlink(other, filepath.Join(folder, ".claude")))
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeSkill, wb, "a", "Read the plan.\n", "Read it twice.\n"))
	err := a.acceptErr(id, "")
	require.ErrorIs(t, err, errUnsafeFile)
	assert.Zero(t, g.calls, "git never reads a path through a link")
	assert.Equal(t, "Read the plan.\n", readFile(t, filepath.Join(other, "skills", "a", "SKILL.md")))
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestAccept_RepoAgentWritesBetweenCheckAndRename_IsStale(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	path := filepath.Join(folder, ".claude", "skills", "a", "SKILL.md")
	id := propose(t, d, repoProposal(DestRepoClaudeSkill, wb, "a", "Read the plan.\n", "Read it twice.\n"))

	// The writer re-reads just before the rename.
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	writeFile(t, path, "The agent's edit.\n")
	_, err = a.writeDestination(p, cur, "Read it twice.\n", applyNow)
	require.ErrorIs(t, err, ErrStale)
	assert.Equal(t, "The agent's edit.\n", readFile(t, path))

	// Through Accept: the agent writes right after the git check said clean.
	writeFile(t, path, "Read the plan.\n")
	state := a.RepoState
	a.RepoState = func(folder, rel string) (RepoFileState, error) {
		st, err := state(folder, rel)
		writeFile(t, path, "The agent's edit.\n")
		return st, err
	}
	require.ErrorIs(t, a.acceptErr(id, ""), ErrStale)
	assert.Equal(t, "superseded", proposal(t, d, id).Status)
	assert.Equal(t, "The agent's edit.\n", readFile(t, path))
}

func TestAccept_RepoWorkbenchDeletedAfterWrite_Undone(t *testing.T) {
	d := openDBs(t)
	for _, c := range []struct{ name, before string }{{"existing", "Run tests.\n"}, {"created", ""}} {
		folder := repoFolderWith(t, map[string]string{})
		path := filepath.Join(folder, "CLAUDE.md")
		if c.before != "" {
			writeFile(t, path, c.before)
			git(t, folder, "add", "CLAUDE.md")
			git(t, folder, "commit", "-q", "-m", "claude")
		}
		wb := repoWorkbench(t, d, folder)
		a, _ := repoApplier(t, d)
		id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", c.before, "Run lint.\n"))
		// accept's own steps, with the workbench deleted between the write and
		// the status compare-and-set.
		p := proposal(t, d, id)
		cur, err := a.readCurrent(p)
		require.NoError(t, err, c.name)
		w, err := a.writeDestination(p, cur, p.AfterText, applyNow)
		require.NoError(t, err, c.name)
		require.NoError(t, d.DeleteWorkbench(wb), c.name)
		require.ErrorIs(t, d.MarkCoachAccepted(id, w.result, nil, 0, applyNow), db.ErrCoachStateChanged, c.name)
		require.NoError(t, w.undo(), c.name)
		if c.before == "" {
			assert.NoFileExists(t, path, c.name)
		} else {
			assert.Equal(t, c.before, readFile(t, path), c.name)
		}
		assert.Empty(t, git(t, folder, "status", "--porcelain=v1"), c.name)
	}
}

// Accept "killed" after the write and before the status write: the file holds
// the after-text, uncommitted, so the next Accept is refused as dirty and the
// card stays open; once the owner commits the edit, Accept records it (the
// file already holds the after-text: every file destination's recovery).
func TestAccept_RepoKilledBeforeStatusCAS_NextAccept(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	path := filepath.Join(folder, "CLAUDE.md")
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	_, err = a.writeDestination(p, cur, p.AfterText, applyNow)
	require.NoError(t, err)

	require.ErrorIs(t, a.acceptErr(id, ""), ErrRepoDirty)
	assert.Equal(t, "open", proposal(t, d, id).Status)
	assert.Equal(t, "Run lint.\n", readFile(t, path), "the file keeps the edit")

	git(t, folder, "commit", "-q", "-am", "owner commits")
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
	assert.Equal(t, "Run lint.\n", readFile(t, path))
}

func TestAccept_RepoFolderGoneWithLiveWorkbench(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	require.NoError(t, os.RemoveAll(folder))
	err := a.acceptErr(id, "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "workbench folder not found")
	assert.NotContains(t, err.Error(), folder)
	assert.Zero(t, g.calls, "no git read")
	assert.NoDirExists(t, folder, "nothing written")
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestAccept_RepoSeamsNotWired(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a := newApplier(t, d) // no RepoState
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	err := a.acceptErr(id, "")
	require.ErrorIs(t, err, errRepoNotWired)
	assert.Contains(t, err.Error(), "repo_* accept: git state reader not wired")
	assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))
	assert.Equal(t, "open", proposal(t, d, id).Status)

	e := ChatEdit{Destination: DestRepoClaudeMD, WorkbenchID: wb, Kind: "add", Replace: "Run lint.",
		Title: "t", Why: "w", Metric: "corrections"}
	_, err = ValidateChatProposal(context.Background(), d.DB, e, Env{Home: t.TempDir()})
	require.ErrorIs(t, err, errRepoNotWired)
	assert.False(t, errors.Is(err, ErrRefused), "an internal error, not the model's")
}

func TestRollback_RepoAfterOwnerCommit(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	path := filepath.Join(folder, workbenchmethod.FileRel)
	id := propose(t, d, repoProposal(DestRepoWorkflow, wb, "", "# Workflow\n", "# Workflow\nPlans first.\n"))
	require.NoError(t, a.acceptErr(id, ""))
	git(t, folder, "commit", "-q", "-am", "owner commits")
	head := git(t, folder, "rev-parse", "HEAD")
	calls := g.calls

	_, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, "# Workflow\n", readFile(t, path))
	assert.Equal(t, calls, g.calls, "Rollback runs no git check")
	assert.Equal(t, "M .watchtower/workflow.md", git(t, folder, "status", "--porcelain=v1"))
	assert.Equal(t, head, git(t, folder, "rev-parse", "HEAD"))
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestRollback_RepoChangedSince(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	path := filepath.Join(folder, ".claude", "skills", "a", "SKILL.md")
	id := propose(t, d, repoProposal(DestRepoClaudeSkill, wb, "a", "Read the plan.\n", "Read it twice.\n"))
	require.NoError(t, a.acceptErr(id, ""))
	writeFile(t, path, "Read it twice.\nThe owner's line.\n")
	diff, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Contains(t, diff, "+The owner's line.")
	assert.NotContains(t, err.Error(), folder)
	assert.Equal(t, "Read it twice.\nThe owner's line.\n", readFile(t, path))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// The repository files take the skill budget, whatever kind they are.
func TestBudgetOf_RepoFiles(t *testing.T) {
	for _, dest := range repoDestinationsForTest {
		assert.Equal(t, skillBudget(10), BudgetOf(dest, strings.Repeat("x", 10)), dest)
	}
}
