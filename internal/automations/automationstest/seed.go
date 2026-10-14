package automationstest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// SeedOptions tunes SeedAutomation. The zero value seeds a personal,
// confirmed, enabled automation with slug "seeded" at time.Now().
type SeedOptions struct {
	Slug        string            // "" = "seeded"
	Scope       automations.Scope // zero = personal
	Now         time.Time         // zero = time.Now()
	Unconfirmed bool              // leave the approval hash unconfirmed
	Disabled    bool              // leave the automation disabled
}

// seedFolder is the recipe folder of one (database, scope): every recipe
// seeded there is kept, so a rescan never marks an earlier seed removed even
// after a test's cleanup deleted the folder.
type seedFolder struct {
	dir   string
	files map[string]string // slug → recipe text
}

type seedKey struct {
	d     *db.DB
	scope automations.Scope
}

var (
	seedMu      sync.Mutex
	seedFolders = map[seedKey]*seedFolder{}
)

// SeedAutomation indexes recipeText through the real indexer (parse, index
// row), then confirms and enables it unless opts say otherwise, and returns
// the row as stored. A recipe that fails to parse fails the test.
func SeedAutomation(t *testing.T, d *db.DB, recipeText string, opts SeedOptions) db.Automation {
	t.Helper()
	if opts.Slug == "" {
		opts.Slug = "seeded"
	}
	if opts.Scope.Kind == "" {
		opts.Scope.Kind = automations.ScopePersonal
	}
	if opts.Now.IsZero() {
		opts.Now = time.Now()
	}
	dir := writeSeedFolder(t, d, opts.Scope, opts.Slug, recipeText)
	ix := automations.NewIndexer(d, t.TempDir(), NewFakeClock(opts.Now))
	if _, err := ix.RescanFolder(context.Background(), opts.Scope, dir); err != nil {
		t.Fatalf("SeedAutomation: indexing %s: %v", opts.Slug, err)
	}
	a, err := d.GetAutomationBySlug(string(opts.Scope.Kind), opts.Scope.WorkbenchID, opts.Slug)
	if err != nil {
		t.Fatalf("SeedAutomation: reading %s back: %v", opts.Slug, err)
	}
	if a.ParseError != "" {
		t.Fatalf("SeedAutomation: %s does not parse: %s", opts.Slug, a.ParseError)
	}
	if !opts.Unconfirmed {
		if err := d.ConfirmAutomation(a.ID, a.ApprovalHash, opts.Now); err != nil {
			t.Fatalf("SeedAutomation: confirming %s: %v", opts.Slug, err)
		}
	}
	if !opts.Disabled {
		if err := d.SetAutomationEnabled(a.ID, true, opts.Now); err != nil {
			t.Fatalf("SeedAutomation: enabling %s: %v", opts.Slug, err)
		}
	}
	if a, err = d.GetAutomation(a.ID); err != nil {
		t.Fatalf("SeedAutomation: reading %s back: %v", opts.Slug, err)
	}
	return *a
}

// writeSeedFolder (re)creates the folder of (d, scope) with every recipe
// seeded there so far plus this one, and returns it.
func writeSeedFolder(t *testing.T, d *db.DB, scope automations.Scope, slug, text string) string {
	t.Helper()
	seedMu.Lock()
	defer seedMu.Unlock()
	key := seedKey{d: d, scope: scope}
	f := seedFolders[key]
	if f == nil {
		dir, err := os.MkdirTemp("", "automationstest-seed-")
		if err != nil {
			t.Fatalf("SeedAutomation: %v", err)
		}
		f = &seedFolder{dir: dir, files: map[string]string{}}
		seedFolders[key] = f
	}
	f.files[slug] = text
	if err := os.MkdirAll(f.dir, 0o755); err != nil {
		t.Fatalf("SeedAutomation: %v", err)
	}
	for s, body := range f.files {
		if err := os.WriteFile(filepath.Join(f.dir, s+".md"), []byte(body), 0o644); err != nil {
			t.Fatalf("SeedAutomation: %v", fmt.Errorf("writing %s: %w", s, err))
		}
	}
	dir := f.dir
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}
