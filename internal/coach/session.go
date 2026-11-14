package coach

import (
	"errors"
	"fmt"
	"path/filepath"

	"watchtower/internal/agentfiles"
	"watchtower/internal/db"
)

// A repository change (repo_*) or the memory index (claude_memory_index) is
// carried out by a workbench session the Desktop starts with Brief (spec
// 2026-11-12 part 3, C6, C10): Watchtower writes no git and no repository
// file for it (COACH-01). The Applier only records the Accept with that
// session (AcceptWithSession), starts it again (Restart), closes it when it
// ended with nothing to measure (Dismiss) and rolls a memory change back from
// the stored copy.

// sessionDestinations are the destinations a session carries out.
var sessionDestinations = map[string]bool{DestRepoClaudeMD: true, DestRepoAgentsMD: true,
	DestRepoClaudeSkill: true, DestRepoCodexSkill: true, DestRepoWorkflow: true, DestMemoryIndex: true}

// IsSessionDestination reports whether a proposal of destination is accepted
// by starting a workbench session (AcceptWithSession), not by Accept.
func IsSessionDestination(destination string) bool { return sessionDestinations[destination] }

var (
	errAcceptStartsSession = refuse("Accept it in Watchtower — it starts a session")
	errRollbackBySession   = refuse("Roll it back with a session: Watchtower opens one")
	errNoSessionNeeded     = refuse("this change is applied by Accept, not by a session")
	errMemoryNotWritten    = refuse("nothing to roll back: the session did not write the memory index")
	errMemoryChangedSince  = refuse("the memory index changed since — roll it back by hand")

	errMemoryChanged = errors.New("MEMORY.md changed while it was being written")
	errMemoryMissing = errors.New("the memory index is gone")
)

// memoryIndexKind is the project's auto-memory index, MEMORY.md.
var memoryIndexKind = textFile{label: "MEMORY.md", tmp: ".MEMORY.md.coach-*",
	notRegular: fmt.Errorf("MEMORY.md %w", errUnsafeFile), tooBig: fmt.Errorf("MEMORY.md %w", errUnsafeFile),
	changed: errMemoryChanged, missing: errMemoryMissing}

// MemoryIndexPath is the auto-memory index Claude Code keeps for a project
// folder: <home>/.claude/projects/<slug of folder>/memory/MEMORY.md (a
// worktree's sessions share the main folder's).
func MemoryIndexPath(home, folder string) string {
	return filepath.Join(home, ".claude", memoryIndexRel(folder))
}

func memoryIndexRel(folder string) string {
	return filepath.Join("projects", agentfiles.Slug(folder), "memory", "MEMORY.md")
}

// memoryIndex is p's MEMORY.md (p's workbench folder's project), below the
// home's .claude, no folder of the way a symlink.
func (a *Applier) memoryIndex(p db.CoachProposal) (userFile, error) {
	if a.Home == "" {
		return userFile{}, errors.New("no home folder")
	}
	w, err := a.DB.GetWorkbench(p.WorkbenchID)
	if err != nil {
		return userFile{}, err
	}
	return under(memoryIndexKind, filepath.Join(a.Home, ".claude"), memoryIndexRel(w.FolderPath), false)
}

// sessionLink is what an Accept or a Restart of p through session sessionID
// records: the baseline measured now and, for the memory index, the index as
// it reads now (the copy Rollback restores, so an owner's or auto-memory's
// line added since the proposal is not lost).
func (a *Applier) sessionLink(p db.CoachProposal, sessionID int64) (db.CoachSessionLink, error) {
	if !sessionDestinations[p.Destination] {
		return db.CoachSessionLink{}, errNoSessionNeeded
	}
	if p.WorkbenchID == 0 {
		return db.CoachSessionLink{}, errors.New("this proposal names no workbench")
	}
	l := db.CoachSessionLink{SessionID: sessionID, WorkbenchID: p.WorkbenchID}
	var err error
	if l.Baseline, l.N, err = a.baseline(p, a.now()); err != nil {
		return db.CoachSessionLink{}, fmt.Errorf("measuring the baseline: %w", err)
	}
	if p.Destination == DestMemoryIndex {
		u, err := a.memoryIndex(p)
		if err != nil {
			return db.CoachSessionLink{}, err
		}
		text, err := u.readText()
		if err != nil {
			return db.CoachSessionLink{}, err
		}
		l.Before = &text
	}
	return l, nil
}

// sessionErr names proposal id in err; a session not of the proposal's
// workbench is a refusal.
func sessionErr(id, sessionID int64, p db.CoachProposal, err error) error {
	if errors.Is(err, db.ErrCoachSessionNotFound) {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination,
			refuse("session %d is not a session of this proposal's workbench", sessionID))
	}
	return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
}

// AcceptWithSession records the owner's Accept of an open repository or
// memory proposal carried out by workbench session sessionID, which the
// Desktop has just started with Brief: one compare-and-set open → accepted
// that stores the session, its branch when it already has a worktree branch,
// the baseline and, for the memory index, the index as it reads now. Nothing
// else is written. Another destination, or a session not of the proposal's
// workbench, is refused; a proposal no longer open is db.ErrCoachStateChanged.
func (a *Applier) AcceptWithSession(id, sessionID int64) error {
	p, err := a.DB.GetCoachProposal(id)
	if err != nil {
		return err
	}
	if p.Status != "open" {
		return fmt.Errorf("coach proposal %d is %s, not open: %w", id, p.Status, db.ErrCoachStateChanged)
	}
	l, err := a.sessionLink(p, sessionID)
	if err != nil {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if err := a.DB.AcceptCoachThroughSession(id, l, a.now()); err != nil {
		return sessionErr(id, sessionID, p, err)
	}
	return nil
}

// Restart moves an accepted session row that ended with nothing to measure
// (no measure_from, no verdict, no open or merged PR) to the new session
// sessionID: everything AcceptWithSession records except the status flip, in
// one compare-and-set. decided_at becomes now, so the wait for a merge
// restarts with the new session. A row with a PR is
// db.ErrCoachSessionHasPR; any other row db.ErrCoachStateChanged.
func (a *Applier) Restart(id, sessionID int64) error {
	p, err := a.DB.GetCoachProposal(id)
	if err != nil {
		return err
	}
	l, err := a.sessionLink(p, sessionID)
	if err != nil {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if err := a.DB.RestartCoachSession(id, l, a.now()); err != nil {
		return sessionErr(id, sessionID, p, err)
	}
	return nil
}

// Dismiss closes an accepted session row that ended with nothing to measure
// now, as too_little_data (Decline is for open rows only). Any other row is
// db.ErrCoachStateChanged.
func (a *Applier) Dismiss(id int64) error {
	if err := a.DB.DismissCoachSession(id, a.now()); err != nil {
		return fmt.Errorf("dismissing coach proposal %d: %w", id, err)
	}
	return nil
}

// Reapply turns a settings change off again after someone turned it back on
// outside Watchtower (verdict reverted_outside): a per-key compare-and-set
// from the proposal's before-text to its after-text, then the verdict is
// cleared and the window measures from now. A key holding anything else is
// ErrStale with nothing written; a row that is not accepted with that
// verdict is db.ErrCoachStateChanged.
func (a *Applier) Reapply(id int64) error {
	p, err := a.DB.GetCoachProposal(id)
	if err != nil {
		return err
	}
	if p.Status != "accepted" || p.Verdict != "reverted_outside" {
		return fmt.Errorf("coach proposal %d is not a change turned back on: %w", id, db.ErrCoachStateChanged)
	}
	switch p.Destination {
	case DestPluginOff, DestMCPServerOff, DestConnectorsOff:
	default:
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, errNotSupported)
	}
	if IsProtected(p.Destination, p.SourceKey) {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, errProtected)
	}
	w, err := a.writeSettingsKey(p, CurrentText{Text: p.BeforeText}, p.AfterText)
	if err != nil {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if err := a.DB.ReapplyCoachProposal(id, a.now()); err != nil {
		err = fmt.Errorf("reapplying coach proposal %d: %w", id, err)
		if uerr := w.undo(); uerr != nil {
			return errors.Join(err, fmt.Errorf("restoring %s of coach proposal %d: %w", p.Destination, id, uerr))
		}
		return err
	}
	return nil
}

// rollbackSession is Rollback for a session destination. A repository change
// accepted through a session is reverted by another session (the Desktop's
// Revert…, RevertBrief), never here. The memory index gets the copy read at
// Accept back, only while it still holds what the session wrote (after_text,
// recorded when the session ended): not written yet, or changed since, is
// refused even with force. The archive file the session made stays.
func (a *Applier) rollbackSession(p db.CoachProposal) error {
	if p.Destination != DestMemoryIndex {
		return errRollbackBySession
	}
	if p.AfterText == "" {
		return errMemoryNotWritten
	}
	u, err := a.memoryIndex(p)
	if err != nil {
		return err
	}
	cur, err := u.readText()
	if errors.Is(err, errMemoryMissing) || err == nil && cur != p.AfterText {
		return errMemoryChangedSince
	}
	if err != nil {
		return err
	}
	if err := u.replaceText(p.AfterText, p.BeforeText); err != nil {
		if errors.Is(err, errMemoryChanged) {
			return errMemoryChangedSince
		}
		return err
	}
	return nil
}
