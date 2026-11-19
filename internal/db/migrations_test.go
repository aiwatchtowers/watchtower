package db

import "testing"

// TestLoadMigrations_NoDuplicateVersions guards a merge of two branches that
// each added migrations from the same free number: every embedded migration
// (SQL and Go) must carry its own goose version.
func TestLoadMigrations_NoDuplicateVersions(t *testing.T) {
	migrations, err := loadMigrations()
	if err != nil {
		t.Fatalf("loadMigrations: %v", err)
	}
	seen := map[int64]string{}
	for _, m := range migrations {
		if prev, dup := seen[m.version]; dup {
			t.Errorf("version %d is used by both %s and %s", m.version, prev, m.file)
		}
		seen[m.version] = m.file
	}
}
