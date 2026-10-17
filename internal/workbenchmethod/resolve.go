package workbenchmethod

import (
	"errors"

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

// Combine applies the precedence (spec §3): a valid personal value, else the
// file's (only a file read without error counts), else the default. The
// folder file is repo content — any clone or branch, or the agent editing its
// own worktree, can change it — so only its preset applies: the ask guard and
// the finish check come from the owner's personal setting or the default,
// never from the file (board #558); FileIgnored names what the file asked for.
func Combine(personal db.WorkbenchMethodology, f File) Effective {
	e := Defaults()
	e.File = f
	fileOK := f.Present && f.Err == nil
	pick := func(key, mine, theirs string, value *string, src *Source) {
		switch {
		case Valid(key, mine):
			*value, *src = mine, SourcePersonal
		case fileOK && Valid(key, theirs):
			*value, *src = theirs, SourceFile
		}
	}
	pick("preset", personal.Preset, f.Preset, &e.Preset, &e.Sources.Preset)
	pick("ask_guard", personal.AskGuard, "", &e.AskGuard, &e.Sources.AskGuard)
	pick("finish_check", personal.FinishCheck, "", &e.FinishCheck, &e.Sources.FinishCheck)
	return e
}

// FileIgnored lists the folder file's check settings that would weaken a
// check and were ignored, as "key: value" ("ask_guard: off"); nil when the
// file asks for none (a refused file asks for nothing). Only the owner's
// personal setting weakens a check (board #558).
func (e Effective) FileIgnored() []string {
	if !e.File.Present || e.File.Err != nil {
		return nil
	}
	var out []string
	if Valid("ask_guard", e.File.AskGuard) && e.File.AskGuard != AskGuardStrict {
		out = append(out, "ask_guard: "+e.File.AskGuard)
	}
	if e.File.FinishCheck == FinishOff {
		out = append(out, "finish_check: "+FinishOff)
	}
	return out
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
