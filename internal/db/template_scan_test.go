package db

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// templateScanMinPackages is the coverage floor: a scan pointed at the wrong
// root finds no in-memory-DB packages and passes for the wrong reason.
const templateScanMinPackages = 20

// inMemoryOpenMarkers are the two ways a test outside this package gets a
// fresh in-memory database. Both route through Open(":memory:"), which runs
// the whole goose migration suite unless InitTestTemplate installed the
// snapshot hook first.
var inMemoryOpenMarkers = []string{`db.OpenTestDB(`, `db.Open(":memory:")`}

// TestInitTestTemplate_EveryInMemoryPackageInstallsIt fails when a package
// under internal/ or cmd/ opens in-memory databases in its tests without a
// test file calling db.InitTestTemplate (conventionally from TestMain). Such
// a package migrates from scratch per test — ~8 s each under -race — and a
// few dozen of those are what pushed main's race pass over its 25-minute
// per-package timeout (internal/kb had 80 un-templated opens).
//
// Out of reach by design: a test that opens a file-backed database
// (db.Open(<path>)) migrates from scratch regardless; use db.OpenTestDB
// unless the test genuinely needs a file.
func TestInitTestTemplate_EveryInMemoryPackageInstallsIt(t *testing.T) {
	root := repoRootForOwnerScan(t)

	type pkgState struct{ opens, installs bool }
	pkgs := map[string]*pkgState{}
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.Walk(filepath.Join(root, dir), func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel, err := filepath.Rel(root, filepath.Dir(path))
			if err != nil {
				return err
			}
			if rel == filepath.Join("internal", "db") {
				return nil // this package installs the template via its own TestMain
			}
			// #nosec G122 -- path comes from Walk over the repo's own source tree in a test.
			src, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			st := pkgs[rel]
			if st == nil {
				st = &pkgState{}
				pkgs[rel] = st
			}
			for _, m := range inMemoryOpenMarkers {
				if strings.Contains(string(src), m) {
					st.opens = true
				}
			}
			if strings.Contains(string(src), "db.InitTestTemplate()") {
				st.installs = true
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", dir, err)
		}
	}

	var opening, missing []string
	for rel, st := range pkgs {
		if !st.opens {
			continue
		}
		opening = append(opening, rel)
		if !st.installs {
			missing = append(missing, rel)
		}
	}
	if len(opening) < templateScanMinPackages {
		t.Fatalf("found only %d packages opening in-memory test DBs, want at least %d — wrong root %q?", len(opening), templateScanMinPackages, root)
	}
	sort.Strings(missing)
	for _, rel := range missing {
		t.Errorf("%s opens in-memory test databases but no test file calls db.InitTestTemplate() — add a TestMain (see internal/catchup/testmain_test.go)", rel)
	}
}
