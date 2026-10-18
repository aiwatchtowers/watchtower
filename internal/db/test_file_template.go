package db

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// InitTestFileTemplate is InitTestTemplate plus seedNewFileHook: from then
// on a file-backed Open of a path that does not exist yet starts from the
// migrated snapshot written to that file, instead of running goose from
// scratch (~15–25 s per Open under -race on a CI runner), while still taking
// the real open path (DSN, pragmas, WAL, goose check, drift check, file
// modes).
//
// Call it from TestMain in a package whose tests open fresh database files
// (db.Open(filepath.Join(t.TempDir(), …))). Not for a package that tests
// migrating an empty file: every new file is seeded. Outside a test binary
// it refuses (InitTestTemplate checks testing.Testing), so it never seeds a
// real database.
func InitTestFileTemplate() error {
	if err := InitTestTemplate(); err != nil {
		return err
	}
	// A hook already set is kept: internal/db's own TestMain installs a
	// wrapper that leaves openMigratingFresh's paths to a real migration and
	// records what it seeded; replacing it would break those tests.
	if seedNewFileHook == nil {
		seedNewFileHook = func(dbPath string) error {
			_, err := writeTemplateFile(dbPath)
			return err
		}
	}
	return nil
}

// writeTemplateFile writes the migrated template to the new file dbPath, at
// the 0644 SQLite itself creates a file with under the usual umask, so Open's
// permission tightening still has work to do. The bytes go to a temp file in
// the same directory first and are hard-linked into place, so dbPath never
// holds a partial snapshot and an existing file is never clobbered. written
// is false when dbPath appeared meanwhile and was left as it is.
func writeTemplateFile(dbPath string) (written bool, err error) {
	if len(templateSnapshot) == 0 {
		return false, errors.New("template not initialised")
	}
	f, err := os.CreateTemp(filepath.Dir(dbPath), filepath.Base(dbPath)+".seed-*")
	if err != nil {
		return false, err
	}
	tmp := f.Name()
	defer func() { _ = os.Remove(tmp) }()
	if _, err := f.Write(templateSnapshot); err != nil {
		_ = f.Close()
		return false, err
	}
	if err := f.Close(); err != nil {
		return false, err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return false, err
	}
	// Link fails with EEXIST when dbPath appeared meanwhile: someone else
	// seeded (or created) it, which is as good as seeding it here.
	if err := os.Link(tmp, dbPath); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}
