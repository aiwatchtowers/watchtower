package builtin

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// copyNotRegularNote is the sync note of an owner copy that is a symlink, a
// directory or a special file: it is never read, the shipped text is used.
const copyNotRegularNote = "the edited copy is not a regular file; using the built-in"

// SyncReport is what one Sync did, by built-in id.
type SyncReport struct {
	// Indexed: the built-ins whose row this sync wrote (new or changed).
	Indexed []string
	// Confirmed: the built-ins whose shipped text this sync confirmed.
	Confirmed []string
	// Overridden: the built-ins running from the owner's copy.
	Overridden []string
	// Errors: a built-in whose copy was not used, or that could not be
	// synced, with why.
	Errors map[string]string
}

// Sync brings every built-in's row in line with its source: the owner's copy
// <workspace>/automations/.builtin/<id>.md when it is a regular file, else
// the shipped text; it confirms a row whose text is byte-equal to the shipped
// text (the release is its confirmation, AUTO-06 as amended) and mirrors the
// built-in's on/off state from cfg. A built-in that cannot be synced is
// reported in Errors and the others still are; the error joins the database
// failures.
func Sync(ctx context.Context, d *db.DB, workspaceDir string, cfg *config.Config, now time.Time) (SyncReport, error) {
	rep := SyncReport{Errors: map[string]string{}}
	var errs []error
	for _, e := range registry {
		if err := ctx.Err(); err != nil {
			return rep, err
		}
		res, err := syncEntry(d, workspaceDir, cfg, e, now)
		if res.note != "" {
			rep.Errors[e.ID] = res.note
		}
		if err != nil {
			rep.Errors[e.ID] = err.Error()
			errs = append(errs, err)
			continue
		}
		if res.wrote {
			rep.Indexed = append(rep.Indexed, e.ID)
		}
		if res.confirmed {
			rep.Confirmed = append(rep.Confirmed, e.ID)
		}
		if res.row != nil && res.row.Overridden {
			rep.Overridden = append(rep.Overridden, e.ID)
		}
	}
	return rep, errors.Join(errs...)
}

// SyncOne syncs built-in id as Sync does and returns its row. A copy that is
// not used (not a regular file) is not an error here: the row then holds the
// shipped text, as Sync reports it.
func SyncOne(ctx context.Context, d *db.DB, workspaceDir string, cfg *config.Config, id string, now time.Time) (*db.Automation, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	e, ok := Lookup(id)
	if !ok {
		return nil, fmt.Errorf("unknown built-in automation %q", id)
	}
	res, err := syncEntry(d, workspaceDir, cfg, e, now)
	if err != nil {
		return nil, err
	}
	return res.row, nil
}

// syncResult is one built-in's sync.
type syncResult struct {
	row       *db.Automation // the row after the sync
	wrote     bool           // the row was inserted or changed
	confirmed bool           // the shipped text was confirmed
	note      string         // why the copy was not used
}

// source is the recipe bytes a built-in's row is indexed from.
type source struct {
	data        []byte
	contentHash string
	overridden  bool
	note        string
}

// sourceOf picks the bytes of e: the owner's copy when it is a regular file
// (read without following links), else the shipped bytes. A copy that is a
// symlink, directory or special file is never read; a copy that exists but
// cannot be read is an error, so the row keeps what it holds (never a silent
// fallback to the shipped text).
func sourceOf(workspaceDir string, e Entry) (source, error) {
	shipped := source{data: e.Recipe, contentHash: e.ShippedContentHash()}
	path := OwnerCopyPath(workspaceDir, e.ID)
	fi, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return shipped, nil
	case err != nil:
		return source{}, fmt.Errorf("built-in %s: reading the edited copy: %w", e.ID, err)
	case !fi.Mode().IsRegular():
		shipped.note = copyNotRegularNote
		return shipped, nil
	}
	data, hash, err := automations.ReadRecipeFile(path)
	if err != nil {
		return source{}, fmt.Errorf("built-in %s: %w", e.ID, err)
	}
	return source{data: data, contentHash: hash, overridden: true}, nil
}

func syncEntry(d *db.DB, workspaceDir string, cfg *config.Config, e Entry, now time.Time) (syncResult, error) {
	var res syncResult
	prev, err := d.GetBuiltinAutomation(e.ID)
	if errors.Is(err, db.ErrAutomationNotFound) {
		prev, err = nil, nil
	}
	if err != nil {
		return res, err
	}
	src, err := sourceOf(workspaceDir, e)
	if err != nil {
		return res, err
	}
	res.note = src.note
	cand, err := automations.IndexRow(e.ID, "builtin:"+e.ID, src.data, src.contentHash, scopeOf(e))
	if err != nil {
		return res, fmt.Errorf("built-in %s: %w", e.ID, err)
	}
	cand.BuiltinID, cand.Overridden = e.ID, src.overridden
	if src.overridden {
		// The copy's base is the shipped text it was made from: kept while
		// the row stays overridden, the current shipped text on 0 → 1.
		cand.BuiltinBaseHash = e.ShippedContentHash()
		if prev != nil && prev.Overridden && prev.BuiltinBaseHash != "" {
			cand.BuiltinBaseHash = prev.BuiltinBaseHash
		}
	}
	var id int64
	if prev != nil && sameRow(*prev, cand) {
		id = prev.ID
	} else {
		if id, err = d.UpsertBuiltinAutomation(cand); err != nil {
			return res, err
		}
		res.wrote = true
	}
	row, err := d.GetAutomation(id)
	if err != nil {
		return res, err
	}
	if !row.Confirmed() && row.ParseError == "" && row.ContentHash == e.ShippedContentHash() {
		if err := d.ConfirmShippedBuiltin(id, row.ContentHash, row.ApprovalHash, now); err != nil {
			return res, err
		}
		res.confirmed = true
	}
	if err := d.SetBuiltinEnabled(e.ID, e.Enabled(cfg), now); err != nil {
		return res, err
	}
	if res.row, err = d.GetAutomation(id); err != nil {
		return res, err
	}
	return res, nil
}

// rowFields is the part of a built-in's row its source determines.
type rowFields struct {
	Slug, Path, Name, TriggerKind, TriggerSpec, MissedPolicy string
	Concurrency, BudgetTokens, BudgetMinutes, PauseTimeout   int
	PermissionsJSON, OutputsJSON, RecipeText, ContentHash    string
	ApprovalHash, ParseError, BuiltinBaseHash                string
	Overridden, Removed                                      bool
}

func fieldsOf(a db.Automation) rowFields {
	return rowFields{
		a.Slug, a.Path, a.Name, a.TriggerKind, a.TriggerSpec, a.MissedPolicy,
		a.Concurrency, a.BudgetTokens, a.BudgetMinutes, a.PauseTimeoutHours,
		a.PermissionsJSON, a.OutputsJSON, a.RecipeText, a.ContentHash,
		a.ApprovalHash, a.ParseError, a.BuiltinBaseHash,
		a.Overridden, a.RemovedAt != nil,
	}
}

// sameRow reports whether the upsert of cand would leave prev as it is, so an
// unchanged built-in writes nothing (its updated_at stays, and with it the
// Personal scope's generation the indexer's Changed reads).
func sameRow(prev, cand db.Automation) bool { return fieldsOf(prev) == fieldsOf(cand) }
