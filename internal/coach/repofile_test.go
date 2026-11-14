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
		// Outside a work tree rev-parse fails: that is the "not git" answer.
		if out, _ := c.Output(); strings.TrimSpace(string(out)) != "true" {
			return RepoFileState{}, nil
		}
		// As workbenchgit.PathStatus: a listed path, ignored ones included, is dirty.
		return RepoFileState{Git: true, Dirty: git(t, folder, "status", "--porcelain=v1", "-z", "--ignored=matching", "--", rel) != ""}, nil
	}
}

// repoApplier is an Applier whose RepoState reads the real git state.
func repoApplier(t *testing.T, d dbs) (*Applier, *gitState) {
	t.Helper()
	g := &gitState{}
	a := newApplier(t, d)
	a.RepoState = g.read(t)
	a.RepoBranch = func(folder string) (string, error) { return gitBranch(t, folder), nil }
	return a, g
}

// gitBranch is the branch checked out in folder the way cmd's RepoBranch
// names it: "detached:<short sha>" for a detached HEAD.
func gitBranch(t *testing.T, folder string) string {
	t.Helper()
	if b := git(t, folder, "branch", "--show-current"); b != "" {
		return b
	}
	return "detached:" + git(t, folder, "rev-parse", "--short=7", "HEAD")
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

// COACH-01 amendment: Accept writes no repository file and runs no git; a
// non-repository destination is still written by Accept.
func TestAccept_RepoFileWritesAndRunsNoGitWrite(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)

	id = propose(t, d, repoProposal(DestRepoCodexSkill, wb, "b", "Read the board.\n", "Read the board first.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	// Every other destination is still written by Accept, with no path.
	id = propose(t, d, db.CoachProposal{Destination: DestChat, BeforeText: "", AfterText: "Be brief."})
	r, err := a.Accept(id, "")
	require.NoError(t, err)
	assert.Empty(t, r.WrittenPath)
}

// COACH-01 amendment: a dirty file is refused like a clean one — Accept never
// reaches the git check, the session does the change.
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
			a, g := repoApplier(t, d)
			id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))
			c.dirty(t, folder)
			requireSessionRefusal(t, a, d, g, id, folder)
			assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")), "file untouched")
		})
	}
}

// COACH-01 amendment: an ignored path's local text is never overwritten —
// Accept is refused before any write (ask #1236 kept).
func TestAccept_RepoFileIgnoredRefused(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{".gitignore": "AGENTS.md\n"})
	writeFile(t, filepath.Join(folder, "AGENTS.md"), "Local notes.\n")
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoAgentsMD, wb, "", "Local notes.\n", "Local notes.\nRun tests.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Equal(t, "Local notes.\n", readFile(t, filepath.Join(folder, "AGENTS.md")))
}

// COACH-01 amendment: a folder that is not a git work tree is refused like any
// other — no file is written there.
func TestAccept_RepoFolderNotGitRefused(t *testing.T) {
	d := openDBs(t)
	folder := t.TempDir()
	writeFile(t, filepath.Join(folder, "CLAUDE.md"), "Run tests.\n")
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run package tests only.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))
}

// COACH-01 amendment: Accept never creates CLAUDE.md. A row accepted before
// sessions (the file created by the old Accept) still rolls back by deleting
// the created file, and keeps a file the owner changed since.
func TestAccept_RepoClaudeMDCreatedAndRollbackDeletes(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{})
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	path := filepath.Join(folder, "CLAUDE.md")

	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "", "Run tests.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.NoFileExists(t, path, "nothing created")

	legacyAccept(t, a, d, id)
	assert.Equal(t, "Run tests.\n", readFile(t, path))
	_, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.NoFileExists(t, path, "a created file goes again")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
	assert.Empty(t, git(t, folder, "status", "--porcelain=v1"))

	// Changed by the owner since: kept, with the diff.
	id = propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "", "Run lint.\n"))
	legacyAccept(t, a, d, id)
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
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Zero(t, g.calls, "git never reads a path through a link")
	assert.Equal(t, "Read the plan.\n", readFile(t, filepath.Join(other, "skills", "a", "SKILL.md")))
}

func TestAccept_RepoAgentWritesBetweenCheckAndRename_IsStale(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	path := filepath.Join(folder, ".claude", "skills", "a", "SKILL.md")
	id := propose(t, d, repoProposal(DestRepoClaudeSkill, wb, "a", "Read the plan.\n", "Read it twice.\n"))

	// The writer (kept for rows accepted before sessions) re-reads just
	// before the rename.
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	writeFile(t, path, "The agent's edit.\n")
	_, err = a.writeDestination(p, cur, "Read it twice.\n", applyNow)
	require.ErrorIs(t, err, ErrStale)
	assert.Equal(t, "The agent's edit.\n", readFile(t, path))

	// Through Accept (COACH-01 amendment): refused before any git check or
	// write, so the agent's edit is never at risk and the proposal stays open.
	writeFile(t, path, "Read the plan.\n")
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Equal(t, "Read the plan.\n", readFile(t, path))
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
		require.ErrorIs(t, d.MarkCoachAccepted(id, w.result, "", nil, 0, applyNow), db.ErrCoachStateChanged, c.name)
		require.NoError(t, w.undo(), c.name)
		if c.before == "" {
			assert.NoFileExists(t, path, c.name)
		} else {
			assert.Equal(t, c.before, readFile(t, path), c.name)
		}
		assert.Empty(t, git(t, folder, "status", "--porcelain=v1"), c.name)
	}
}

// An old Accept "killed" after the write and before the status write left the
// file holding the after-text. COACH-01 amendment: the next Accept no longer
// records it — it is refused like any repository Accept, the card stays open
// and the file keeps the edit (the session or the owner takes it from there).
func TestAccept_RepoKilledBeforeStatusCAS_NextAccept(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	path := filepath.Join(folder, "CLAUDE.md")
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	_, err = a.writeDestination(p, cur, p.AfterText, applyNow)
	require.NoError(t, err)

	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Equal(t, "Run lint.\n", readFile(t, path), "the file keeps the edit")

	git(t, folder, "commit", "-q", "-am", "owner commits")
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Equal(t, "Run lint.\n", readFile(t, path))
}

func TestAccept_RepoFolderGoneWithLiveWorkbench(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	require.NoError(t, os.RemoveAll(folder))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Zero(t, g.calls, "no git read")
	assert.NoDirExists(t, folder, "nothing written")
}

func TestAccept_RepoSeamsNotWired(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a := newApplier(t, d) // no RepoState
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	// COACH-01 amendment: Accept needs no git seam — it is refused first.
	requireSessionRefusal(t, a, d, nil, id, folder)
	noBranch, g := repoApplier(t, d)
	noBranch.RepoBranch = nil
	requireSessionRefusal(t, noBranch, d, g, id, folder)
	assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))

	e := ChatEdit{Destination: DestRepoClaudeMD, WorkbenchID: wb, Kind: "add", Replace: "Run lint.",
		Title: "t", Why: "w", Metric: "corrections"}
	_, err := ValidateChatProposal(context.Background(), d.DB, e, Env{Home: t.TempDir()})
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
	legacyAccept(t, a, d, id) // a row accepted before sessions
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
	legacyAccept(t, a, d, id) // a row accepted before sessions
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

// A created CLAUDE.md the owner has changed since is never deleted, not even
// by a forced Rollback (spec §4.3a, ask #1169).
func TestRollback_RepoCreatedFileForcedKeepsOwnerText(t *testing.T) {
	d := openDBs(t)
	folder := repoFolderWith(t, map[string]string{})
	wb := repoWorkbench(t, d, folder)
	a, _ := repoApplier(t, d)
	path := filepath.Join(folder, "CLAUDE.md")
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "", "Run tests.\n"))
	legacyAccept(t, a, d, id) // a row accepted before sessions
	writeFile(t, path, "Run tests.\nMine.\n")
	_, err := a.Rollback(id, true)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Equal(t, "Run tests.\nMine.\n", readFile(t, path))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// A failed git state read refuses at propose (never clean); COACH-01
// amendment: Accept reads no git state at all, it is refused first.
func TestAccept_RepoStateErrorRefuses(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	reads := 0
	failing := func(string, string) (RepoFileState, error) {
		reads++
		return RepoFileState{Git: true}, errors.New("fatal: simulated status failure")
	}
	a, _ := repoApplier(t, d)
	a.RepoState = failing
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	requireSessionRefusal(t, a, d, nil, id, folder)
	assert.Zero(t, reads, "no git state read")
	assert.Equal(t, "Run tests.\n", readFile(t, filepath.Join(folder, "CLAUDE.md")))

	e := ChatEdit{Destination: DestRepoClaudeMD, WorkbenchID: wb, Kind: "add", Replace: "Run lint.",
		Title: "t", Why: "w", Metric: "corrections"}
	_, err := ValidateChatProposal(context.Background(), d.DB, e, Env{Home: t.TempDir(), RepoState: failing})
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrRefused), "a failed read is an error, not a refusal")
}

// COACH-01 amendment: Accept writes nothing, so a lost status write has
// nothing to undo — the file stays as it was (or absent) and git is clean.
func TestAccept_RepoStatusCASFailsThroughAccept_Undone(t *testing.T) {
	d := openDBs(t)
	for _, c := range []struct{ name, before string }{{"existing", "Run tests.\n"}, {"created", ""}} {
		files := map[string]string{}
		if c.before != "" {
			files["CLAUDE.md"] = c.before
		}
		folder := repoFolderWith(t, files)
		path := filepath.Join(folder, "CLAUDE.md")
		wb := repoWorkbench(t, d, folder)
		a, g := repoApplier(t, d)
		id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", c.before, "Run lint ("+c.name+").\n"))
		_, err := d.Exec(`CREATE TRIGGER coach_lost_row BEFORE UPDATE OF status ON coach_proposals
			WHEN NEW.status = 'accepted' BEGIN SELECT RAISE(IGNORE); END`)
		require.NoError(t, err)
		requireSessionRefusal(t, a, d, g, id, folder)
		_, err = d.Exec(`DROP TRIGGER coach_lost_row`)
		require.NoError(t, err)
		if c.before == "" {
			assert.NoFileExists(t, path, c.name)
		} else {
			assert.Equal(t, c.before, readFile(t, path), c.name)
		}
		assert.Empty(t, git(t, folder, "status", "--porcelain=v1"), c.name)
	}
}

// COACH-01 amendment: Accept of a repository proposal writes nothing, so it
// records no branch (the session's branch is recorded by AcceptWithSession);
// every other destination still stores none.
func TestAccept_RepoRecordsBranch(t *testing.T) {
	d := openDBs(t)
	folder := fullRepo(t)
	wb := repoWorkbench(t, d, folder)
	a, g := repoApplier(t, d)

	git(t, folder, "switch", "-q", "-c", "feature/x")
	id := propose(t, d, repoProposal(DestRepoClaudeMD, wb, "", "Run tests.\n", "Run lint.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Empty(t, proposal(t, d, id).WrittenBranch)

	git(t, folder, "switch", "-q", "--detach")
	id = propose(t, d, repoProposal(DestRepoWorkflow, wb, "", "# Workflow\n", "# Workflow\nReview first.\n"))
	requireSessionRefusal(t, a, d, g, id, folder)
	assert.Empty(t, proposal(t, d, id).WrittenBranch)

	// Every other destination stores no branch.
	id = propose(t, d, db.CoachProposal{Destination: DestChat, BeforeText: "", AfterText: "Be brief."})
	r, err := a.Accept(id, "")
	require.NoError(t, err)
	assert.Empty(t, r.WrittenBranch)
	assert.Empty(t, proposal(t, d, id).WrittenBranch)
}

// folderSnapshot is every file under folder outside .git, by relative path,
// plus the folder's HEAD and git status: what a refused Accept must leave
// byte-identical.
func folderSnapshot(t *testing.T, folder string) map[string]string {
	t.Helper()
	out := map[string]string{}
	if _, err := os.Stat(folder); err != nil {
		return out
	}
	root, err := os.OpenRoot(folder)
	require.NoError(t, err)
	defer func() { _ = root.Close() }()
	require.NoError(t, filepath.WalkDir(folder, func(path string, e os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if e.IsDir() && e.Name() == ".git" {
			return filepath.SkipDir
		}
		rel, _ := filepath.Rel(folder, path)
		if e.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			out[rel] = "link:" + target
			return err
		}
		if e.IsDir() {
			out[rel+"/"] = ""
			return nil
		}
		b, err := root.ReadFile(rel)
		fi, ferr := e.Info()
		if ferr != nil {
			return ferr
		}
		out[rel] = fi.Mode().Perm().String() + ":" + string(b)
		return err
	}))
	if _, err := os.Stat(filepath.Join(folder, ".git")); err == nil {
		out["@HEAD"] = git(t, folder, "rev-parse", "HEAD")
		out["@status"] = git(t, folder, "status", "--porcelain=v1", "--ignored=matching")
	}
	return out
}

// requireSessionRefusal is the COACH-01 amendment (spec 2026-11-12, "Contracts
// touched"): a repository proposal is never written by Accept — it is
// accepted through a workbench session — so Accept is refused with the
// session message, the proposal stays open, nothing under folder changes or
// is created, and no git state is read (g may be nil).
func requireSessionRefusal(t *testing.T, a *Applier, d dbs, g *gitState, id int64, folder string) {
	t.Helper()
	before := folderSnapshot(t, folder)
	calls := 0
	if g != nil {
		calls = g.calls
	}
	r, err := a.Accept(id, "")
	require.ErrorIs(t, err, ErrRefused)
	assert.Contains(t, err.Error(), "Accept it in Watchtower — it starts a session")
	assert.NotContains(t, err.Error(), folder)
	assert.Equal(t, AcceptResult{}, r)
	assert.Equal(t, before, folderSnapshot(t, folder), "byte-identical, nothing created")
	if g != nil {
		assert.Equal(t, calls, g.calls, "no git read")
	}
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

// legacyAccept is how a repository proposal was accepted before sessions
// (via_session = 0): the file written by the Applier, then the status. Rows
// accepted that way keep the file Rollback, which these tests pin.
func legacyAccept(t *testing.T, a *Applier, d dbs, id int64) {
	t.Helper()
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	w, err := a.writeDestination(p, cur, p.AfterText, applyNow)
	require.NoError(t, err)
	require.NoError(t, d.MarkCoachAccepted(id, w.result, "", nil, 0, applyNow))
}
