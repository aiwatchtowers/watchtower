package automations

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// WriteRecipe writes data to path (a <slug>.md in the canonical recipe folder
// dir of scope) atomically with mode 0644, like the owner's own files, rescans
// dir and returns the file's index row. It is the one write path of a recipe:
// `automations save` and save_automation both use it.
func (ix *Indexer) WriteRecipe(ctx context.Context, scope Scope, dir, path string, data []byte) (*db.Automation, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", dir, err)
	}
	if err := fsutil.WriteFileAtomic(path, data, 0o644); err != nil {
		return nil, fmt.Errorf("writing %s: %w", path, err)
	}
	return ix.IndexedRecipeAt(ctx, scope, dir, path)
}

// RefuseLinkedRecipeDir refuses a workbench recipe folder (absolute, as
// stored) with a symlink anywhere in its existing part: the scheduler never
// scans such a folder (the indexer's workbenchPathPlain), and a write through
// the link could land outside the workbench. The part that does not exist
// yet is created plain by MkdirAll.
func RefuseLinkedRecipeDir(dir string) error {
	existing := dir
	for {
		_, err := os.Lstat(existing)
		if err == nil {
			break
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("checking %s: %w", existing, err)
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			break
		}
		existing = parent
	}
	plain, err := fsutil.NoSymlinkComponents(existing)
	if err != nil {
		return fmt.Errorf("checking %s: %w", dir, err)
	}
	if !plain {
		return fmt.Errorf("%s has a symlink in its path: a workbench recipe folder must be a plain directory "+
			"(the scheduler never scans one behind a link)", dir)
	}
	return nil
}

// IndexedRecipeAt rescans dir under scope and returns the index row of the
// recipe file at path (canonical), or an error naming why it is not indexed.
func (ix *Indexer) IndexedRecipeAt(ctx context.Context, scope Scope, dir, path string) (*db.Automation, error) {
	report, err := ix.RescanFolder(ctx, scope, dir)
	if err != nil {
		return nil, err
	}
	return ix.RecipeInReport(scope, report, path)
}

// RecipeInReport is the index row of the recipe file at path (canonical)
// after the rescan that produced report, or an error naming why it is not
// indexed.
func (ix *Indexer) RecipeInReport(scope Scope, report RescanReport, path string) (*db.Automation, error) {
	for _, s := range report.Skipped {
		if s.Path == path {
			return nil, fmt.Errorf("%s is not indexed: %s", path, s.Reason)
		}
	}
	a, err := ix.db.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, RecipeSlugOf(path))
	if err != nil {
		return nil, fmt.Errorf("%s is not indexed: %w", path, err)
	}
	if a.Path != path || a.RemovedAt != nil {
		return nil, fmt.Errorf("%s is not indexed (its slug belongs to automation %d at %s)", path, a.ID, a.Path)
	}
	return a, nil
}

// RecipeSlugOf is the slug a recipe file's name gives (its stem).
func RecipeSlugOf(path string) string {
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}

// TriggerSpecJSON is t as the automations.trigger_spec column stores it.
func TriggerSpecJSON(t Trigger) (string, error) { return triggerSpecJSON(t) }
