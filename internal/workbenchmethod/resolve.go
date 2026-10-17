package workbenchmethod

import (
	"errors"
	"time"

	"watchtower/internal/db"
)

// Source is where an effective value came from.
type Source string

const (
	SourceDefault  Source = "default"
	SourcePersonal Source = "personal"
	SourceFile     Source = "file"
)

// Label is the brief's word for s (spec §6: "personal", "folder file").
func (s Source) Label() string {
	switch s {
	case SourcePersonal:
		return "personal"
	case SourceFile:
		return "folder file"
	case SourceDefault:
	}
	return "default"
}

// Sources says where each effective value came from.
type Sources struct {
	Preset, AskGuard, FinishCheck Source
}

// Effective is the methodology a workbench session runs under. Err is a
// database failure: the values are then the built-in defaults (PROJ-13).
type Effective struct {
	Preset      string
	AskGuard    string
	FinishCheck string
	Sources     Sources
	File        File
	Err         error
}

// FinishOn reports whether the finish check runs (any value but "off").
func (e Effective) FinishOn() bool { return e.FinishCheck != FinishOff }

// Defaults is the built-in methodology: watchtower-flow, strict, on.
func Defaults() Effective {
	return Effective{
		Preset: PresetFlow, AskGuard: AskGuardStrict, FinishCheck: FinishOn,
		Sources: Sources{Preset: SourceDefault, AskGuard: SourceDefault, FinishCheck: SourceDefault},
	}
}

// Combine applies the precedence (spec §3). The preset: a valid personal
// value, else the file's (only a file read without error counts), else the
// default. The ask guard and the finish check: a valid personal value, else
// the default — never the file's (board #558): the folder file is repo
// content that any clone, a pulled branch or the agent's own worktree edit
// can change, so it never weakens a check. FileIgnored names what it asked for.
func Combine(personal db.WorkbenchMethodology, f File) Effective {
	e := Defaults()
	e.File = f
	if Valid("preset", personal.Preset) {
		e.Preset, e.Sources.Preset = personal.Preset, SourcePersonal
	} else if f.Present && f.Err == nil && Valid("preset", f.Preset) {
		e.Preset, e.Sources.Preset = f.Preset, SourceFile
	}
	if Valid("ask_guard", personal.AskGuard) {
		e.AskGuard, e.Sources.AskGuard = personal.AskGuard, SourcePersonal
	}
	if Valid("finish_check", personal.FinishCheck) {
		e.FinishCheck, e.Sources.FinishCheck = personal.FinishCheck, SourcePersonal
	}
	return e
}

// checkValue is one frontmatter key ("ask_guard", "finish_check") and its value.
type checkValue struct{ key, value string }

// weakerChecks is f's check settings that are weaker than the defaults;
// empty for a refused file or one that asks for nothing weaker.
func weakerChecks(f File) (out []checkValue) {
	if !f.Present || f.Err != nil {
		return nil
	}
	if Valid("ask_guard", f.AskGuard) && f.AskGuard != AskGuardStrict {
		out = append(out, checkValue{"ask_guard", f.AskGuard})
	}
	if Valid("finish_check", f.FinishCheck) && f.FinishCheck != FinishOn {
		out = append(out, checkValue{"finish_check", f.FinishCheck})
	}
	return out
}

// FileIgnored lists, as "key: value" ("ask_guard: off"), the folder file's
// check settings that would weaken a check the owner has no personal value
// for, and so were ignored (board #558); with a personal value the file
// would not have applied anyway, so it is not listed. Never nil.
func (e Effective) FileIgnored() []string {
	out := []string{}
	for _, c := range weakerChecks(e.File) {
		src := e.Sources.AskGuard
		if c.key == "finish_check" {
			src = e.Sources.FinishCheck
		}
		if src != SourcePersonal {
			out = append(out, c.key+": "+c.value)
		}
	}
	return out
}

// CarryOverFileChecks is the one-time upgrade step of board #558: for each
// workbench that existed at migration 00131 and is still carry-pending, a
// check its folder's workflow.md sets weaker than the default becomes the
// owner's personal setting where none is set, so a setup that worked before
// the file stopped counting keeps working, and the mark is cleared
// (db.CarryWorkflowChecks: one statement, so a value the owner sets meanwhile
// is never overwritten). Workbenches created later, and a fresh install,
// have no mark: their files are never copied. The file is read before the
// write, outside any transaction. It returns the ids it processed; an error
// stops it, and the next run picks up the rest.
func CarryOverFileChecks(database *db.DB, now time.Time) ([]int64, error) {
	pending, err := database.ListWorkbenchesCarryPending()
	if err != nil {
		return nil, err
	}
	stamp := now.UTC().Format(time.RFC3339)
	var done []int64
	for _, w := range pending {
		var askGuard, finishCheck string
		for _, c := range weakerChecks(ReadFile(w.FolderPath)) {
			if c.key == "ask_guard" {
				askGuard = c.value
			} else {
				finishCheck = c.value
			}
		}
		ok, err := database.CarryWorkflowChecks(w.ID, askGuard, finishCheck, stamp)
		if err != nil {
			return done, err
		}
		if ok {
			done = append(done, w.ID)
		}
	}
	return done, nil
}

// Resolve is workbench workbenchID's effective methodology with folder's
// workflow.md ("" = the workbench's own folder). A database failure — no
// such workbench, a schema without the 00123 columns, a lock — resolves to
// Defaults with Err set: strict and on, never weaker (PROJ-13).
func Resolve(database *db.DB, workbenchID int64, folder string) Effective {
	personal, err := database.GetWorkbenchMethodology(workbenchID)
	if err == nil && folder == "" {
		var w *db.Workbench
		if w, err = database.GetWorkbench(workbenchID); err == nil {
			folder = w.FolderPath
		}
	}
	if err != nil {
		e := Defaults()
		e.Err = err
		return e
	}
	return Combine(personal, ReadFile(folder))
}

// ResolveSession is Resolve for a hook or brief running in Desktop terminal
// row sessionRowID (0 = outside one): the row's folder when it is a row of
// this workbench — a session worktree reads its own workflow.md, spec §5 —
// else the workbench folder.
func ResolveSession(database *db.DB, workbenchID, sessionRowID int64) Effective {
	folder, err := sessionFolder(database, workbenchID, sessionRowID)
	if err != nil {
		e := Defaults()
		e.Err = err
		return e
	}
	return Resolve(database, workbenchID, folder)
}

// sessionFolder is the row's folder; "" (the workbench folder) for no row, a
// gone row or another workbench's row. Any other read error is returned: it
// must not fall back to a folder file that may say off.
func sessionFolder(database *db.DB, workbenchID, rowID int64) (string, error) {
	if rowID <= 0 {
		return "", nil
	}
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != workbenchID {
		return "", nil
	}
	return row.FolderPath, nil
}
