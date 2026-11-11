package coach

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"

	"watchtower/internal/db"
	"watchtower/internal/logredact"
	"watchtower/internal/workbenchmethod"
)

// The workbench repository files (spec §4.3a, owner ask #1165): five
// instruction files inside a workbench's own folder (projects.folder_path,
// never a session worktree), written by the owner's Accept on a chat proposal
// and committed by the owner. The coach never runs git: the git state of a
// file comes through the RepoState seam, which internal/coach leaves unset
// and cmd fills over workbenchgit (COACH-01, TestCOACH01_NoGitWrites).
// They follow the user files' rules (userfile.go) with the workbench folder
// as the root below which no folder may be a symlink. Errors name the
// relative path or the file's label, never the folder (FILES-01).

var (
	// ErrRepoDirty refuses an Accept whose file has uncommitted changes; the
	// error names the relative path (RepoDirtyLine).
	ErrRepoDirty = errors.New("has uncommitted changes")
	// ErrRepoNotGit refuses a repository file of a folder that is not a git
	// work tree (or a Mac without git): the change could not be reviewed.
	ErrRepoNotGit = errors.New("not a git repository")

	errRepoFolderNotFound = errors.New("workbench folder not found")
	errWorkflowNotFound   = errors.New(workbenchmethod.FileRel + " not found")
	// errRepoNotWired is an Applier or Env built without the git state
	// reader: a repository file is then never written or proposed unchecked.
	errRepoNotWired = errors.New("repo_* accept: git state reader not wired")
)

// RepoDirtyLine and RepoNotGitLine are the owner's sentences for the two
// refusals (RepoDirtyLine takes the relative path).
const (
	RepoDirtyLine  = "%s has uncommitted changes — commit or discard them, then press Accept again."
	RepoNotGitLine = "This workbench folder is not a git repository: Watchtower changes files here only where you can review and commit the change."
)

// RepoFileState is the git state of one workbench file, independent of
// workbenchgit (internal/coach imports no workbenchgit: TestCOACH01_NoGitWrites).
type RepoFileState struct{ Git, Dirty bool }

type repoDirtyError struct{ rel string }

func (e repoDirtyError) Error() string        { return fmt.Sprintf(RepoDirtyLine, e.rel) }
func (e repoDirtyError) Is(target error) bool { return target == ErrRepoDirty }

type repoNotGitError struct{}

func (repoNotGitError) Error() string        { return RepoNotGitLine }
func (repoNotGitError) Is(target error) bool { return target == ErrRepoNotGit }

// RepoRelPath is the file of a repository destination, relative to the
// workbench folder, with forward slashes: the only place the five paths are
// spelled. ok is false for another destination or a bad skill name.
func RepoRelPath(dest, skill string) (string, bool) {
	switch dest {
	case DestRepoClaudeMD:
		return "CLAUDE.md", true
	case DestRepoAgentsMD:
		return "AGENTS.md", true
	case DestRepoWorkflow:
		return workbenchmethod.FileRel, true
	case DestRepoClaudeSkill, DestRepoCodexSkill:
		if checkSkillName(skill) != nil {
			return "", false
		}
		top := ".claude"
		if dest == DestRepoCodexSkill {
			top = ".agents"
		}
		return path.Join(top, "skills", skill, "SKILL.md"), true
	}
	return "", false
}

var (
	repoClaudeMDKind = textFile{label: "CLAUDE.md", tmp: ".CLAUDE.md.coach-*",
		notRegular: fmt.Errorf("CLAUDE.md %w", errUnsafeFile), tooBig: fmt.Errorf("CLAUDE.md %w", errUnsafeFile),
		changed: errors.New("CLAUDE.md changed while it was being written"), createMode: 0o644, folderMustExist: true}
	repoAgentsMDKind = textFile{label: "AGENTS.md", tmp: ".AGENTS.md.coach-*",
		notRegular: agentsMDKind.notRegular, tooBig: agentsMDKind.tooBig, changed: agentsMDKind.changed,
		createMode: 0o644, folderMustExist: true}
	repoWorkflowKind = textFile{label: "workflow.md", tmp: ".workflow.md.coach-*",
		notRegular: fmt.Errorf("workflow.md %w", errUnsafeFile), tooBig: fmt.Errorf("workflow.md %w", errUnsafeFile),
		changed: errors.New("workflow.md changed while it was being written"), missing: errWorkflowNotFound}
)

// repoFolder is the workbench's own folder (projects.folder_path).
func repoFolder(d *db.DB, wb int64) (string, error) {
	w, err := d.GetWorkbench(wb)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return "", refuse("workbench %d not found", wb)
	}
	if err != nil {
		return "", err
	}
	return w.FolderPath, nil
}

// checkRepoRoot refuses a workbench folder that is gone or is not a folder.
func checkRepoRoot(folder string) error {
	fi, err := os.Lstat(folder)
	if errors.Is(err, fs.ErrNotExist) || (err == nil && !fi.IsDir()) {
		return errRepoFolderNotFound
	}
	if err != nil {
		return settingsErr("reading the workbench folder", err)
	}
	return nil
}

// repoFileOf is where a repository destination lives in folder: CLAUDE.md
// and AGENTS.md may be created (0644, in the folder itself), the skills and
// workflow.md must exist; a skill holding the devpack marker is refused.
func repoFileOf(folder, dest, skill string) (userFile, error) {
	rel, ok := RepoRelPath(dest, skill)
	if !ok {
		if skillDestinations[dest] {
			return userFile{}, errBadSkillName
		}
		return userFile{}, errNotSupported
	}
	if err := checkRepoRoot(folder); err != nil {
		return userFile{}, err
	}
	u := userFile{root: folder, path: filepath.Join(folder, filepath.FromSlash(rel))}
	switch dest {
	case DestRepoClaudeMD:
		u.kind, u.create = repoClaudeMDKind, true
	case DestRepoAgentsMD:
		u.kind, u.create = repoAgentsMDKind, true
	case DestRepoWorkflow:
		u.kind = repoWorkflowKind
	default:
		u.kind = skillFileKind
	}
	return u, nil
}

// repoFile is p's repository file.
func (a *Applier) repoFile(p db.CoachProposal) (userFile, error) {
	folder, err := repoFolder(a.DB, p.WorkbenchID)
	if err != nil {
		return userFile{}, err
	}
	return repoFileOf(folder, p.Destination, p.Skill)
}

// checkRepo is Accept's git check of a repository proposal, before the file
// is read: the folder (gone → refused before any git read), then the git
// state of the one path — not a work tree → ErrRepoNotGit, listed at all by
// `git status` → ErrRepoDirty, a failed read → refused, never taken as clean.
func (a *Applier) checkRepo(p db.CoachProposal) error {
	if a.RepoState == nil || a.RepoBranch == nil {
		return errRepoNotWired
	}
	folder, err := repoFolder(a.DB, p.WorkbenchID)
	if err != nil {
		return err
	}
	return repoGitCheck(a.RepoState, folder, p.Destination, p.Skill, true)
}

// writtenBranch is the branch a repository file was just written on, through
// the RepoBranch seam (checkRepo refused a nil one before the write); "" for
// any other destination, and when the folder or the branch cannot be read —
// the file is written by then, so a failed read never undoes it (spec §4.3a).
func (a *Applier) writtenBranch(p db.CoachProposal) string {
	if !repoDestinations[p.Destination] {
		return ""
	}
	folder, err := repoFolder(a.DB, p.WorkbenchID)
	if err == nil {
		var branch string
		if branch, err = a.RepoBranch(folder); err == nil {
			return branch
		}
	}
	log.Printf("coach: proposal %d written; reading its branch in workbench %d: %s", p.ID, p.WorkbenchID,
		logredact.Body([]byte(err.Error())))
	return ""
}

// repoGitCheck reads the git state of dest's file in folder: not a work tree
// → ErrRepoNotGit; with dirty, a listed path → ErrRepoDirty. A gone folder or
// a symlink between the folder and the file is refused first, so git never
// reads a path through a link.
func repoGitCheck(state func(folder, rel string) (RepoFileState, error), folder, dest, skill string, dirty bool) error {
	u, err := repoFileOf(folder, dest, skill)
	if err != nil {
		return err
	}
	if _, err := u.kind.checkFolders(u.root, u.path); err != nil {
		return err
	}
	rel, _ := RepoRelPath(dest, skill)
	st, err := state(folder, rel)
	if err != nil {
		return logredact.Errorf("reading the git state of %s: %s", rel, logredact.Text(err.Error()))
	}
	switch {
	case !st.Git:
		return repoNotGitError{}
	case dirty && st.Dirty:
		return repoDirtyError{rel: rel}
	}
	return nil
}

// readRepo reads p's repository file the way readCurrent reads a user file.
func (a *Applier) readRepo(p db.CoachProposal, t CurrentText) (CurrentText, error) {
	u, err := a.repoFile(p)
	if err != nil {
		return CurrentText{}, err
	}
	if t.Text, err = u.readText(); err != nil {
		return CurrentText{}, err
	}
	t.Budget = BudgetOf(p.Destination, t.Text)
	return t, nil
}

// writeRepoFile replaces the file's text cur.Text by after (ErrStale when it
// changed, re-read just before the rename). The undo puts cur.Text back, or
// removes a file this write created, only while the file still holds after.
func (a *Applier) writeRepoFile(p db.CoachProposal, cur CurrentText, after string) (written, error) {
	u, err := a.repoFile(p)
	if err != nil {
		return written{}, err
	}
	existed, err := u.kind.replace(u.root, u.path, cur.Text, after, u.create)
	if errors.Is(err, u.kind.changed) {
		return written{}, ErrStale
	}
	if err != nil {
		return written{}, err
	}
	return written{result: after, undo: func() error {
		if !existed {
			return u.removeIfStill(after)
		}
		return u.replaceText(after, cur.Text)
	}}, nil
}

// restoreRepoFile is Rollback of a repository file: no git check (the file is
// expected to show Accept's own change, committed or not). A CLAUDE.md or
// AGENTS.md Accept created (an empty before-text) is deleted again (owner,
// ask #1169), only while it still holds Accept's text — a changed one is
// ErrChangedSince even under force and never deleted; any other file gets its
// before-text back while it is still cur, the text Rollback read and showed.
func (a *Applier) restoreRepoFile(p db.CoachProposal, cur CurrentText) error {
	u, err := a.repoFile(p)
	if err != nil {
		return err
	}
	if u.create && p.BeforeText == "" {
		if cur.Text != p.AfterText {
			return ErrChangedSince
		}
		err = u.removeIfStill(cur.Text)
	} else {
		err = u.replaceText(cur.Text, p.BeforeText)
	}
	if errors.Is(err, u.kind.changed) {
		return ErrChangedSince
	}
	return err
}

// removeIfStill deletes u's file only while it holds text; a file already
// gone is left so; a changed one is u.kind.changed and kept.
func (u userFile) removeIfStill(text string) error {
	raw, _, exists, err := u.kind.read(u.root, u.path)
	if err != nil || !exists {
		return err
	}
	if string(raw) != text {
		return u.kind.changed
	}
	if err := os.Remove(u.path); err != nil {
		return settingsErr("removing "+u.kind.label, err)
	}
	return nil
}
