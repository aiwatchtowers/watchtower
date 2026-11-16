package inboxfeed

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

var update = flag.Bool("update", false, "rewrite the expect of every case in testdata/inbox_feed_cases.json")

const casesPath = "testdata/inbox_feed_cases.json"

// feedCase is one case of the shared fixture: a database seeded from a
// fresh migrated file, a moment, the request and the feed both builders
// must produce (built_at blank). InboxFeedParityTests runs the Swift
// builders over the same cases.
type feedCase struct {
	Name   string          `json:"name"`
	Now    string          `json:"now"`
	Seed   []string        `json:"seed"`
	Opts   api.FeedRequest `json:"opts"`
	Expect api.Feed        `json:"expect"`
}

func loadCases(t testing.TB) []feedCase {
	t.Helper()
	b, err := os.ReadFile(casesPath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []feedCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatalf("%s: %v", casesPath, err)
	}
	return cases
}

// seeded opens a fresh migrated database and runs seed on it.
func seeded(t testing.TB, seed []string) *db.DB {
	t.Helper()
	d, _ := seededAt(t, seed)
	return d
}

// TestMain removes the migrated template the cases copy.
func TestMain(m *testing.M) {
	code := m.Run()
	if templateDir != "" {
		_ = os.RemoveAll(templateDir)
	}
	os.Exit(code)
}

var (
	templateOnce sync.Once
	templateDir  string
	templateDB   []byte
	templateErr  error
)

// migrated is a fresh migrated database file's bytes, made once: every
// case starts from a copy instead of running the migrations again.
func migrated(t testing.TB) []byte {
	t.Helper()
	templateOnce.Do(func() {
		if templateDir, templateErr = os.MkdirTemp("", "inboxfeed-template-"); templateErr != nil {
			return
		}
		path := filepath.Join(templateDir, "watchtower.db")
		var d *db.DB
		if d, templateErr = db.Open(path); templateErr != nil {
			return
		}
		if _, templateErr = d.Exec("PRAGMA wal_checkpoint(TRUNCATE)"); templateErr != nil {
			_ = d.Close()
			return
		}
		if templateErr = d.Close(); templateErr != nil {
			return
		}
		templateDB, templateErr = os.ReadFile(path)
	})
	if templateErr != nil {
		t.Fatal(templateErr)
	}
	return templateDB
}

// seededAt is seeded with the database file's path, for a second handle.
func seededAt(t testing.TB, seed []string) (*db.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	if err := os.WriteFile(path, migrated(t), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	for _, stmt := range seed {
		if _, err := d.Exec(stmt); err != nil {
			t.Fatalf("seed %q: %v", stmt, err)
		}
	}
	return d, path
}

// otherHandle opens a second handle on path (the pool of a db.DB has one
// connection): another process, as far as SQLite is concerned.
func otherHandle(t testing.TB, path string) *db.DB {
	t.Helper()
	o, err := db.OpenExistingRW(path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = o.Close() })
	return o
}

// buildCase runs Build for c, built_at blanked.
func buildCase(t testing.TB, c feedCase) api.Feed {
	t.Helper()
	now, err := time.Parse(time.RFC3339, c.Now)
	if err != nil {
		t.Fatalf("%s: now: %v", c.Name, err)
	}
	d := seeded(t, c.Seed)
	feed, err := Build(context.Background(), d, Options{
		Folder: c.Opts.Folder, Limit: c.Opts.Limit, Clip: c.Opts.Clip, Now: now.UTC(),
	})
	if err != nil {
		t.Fatalf("%s: %v", c.Name, err)
	}
	feed.BuiltAt = ""
	return feed
}

// canonical is v as indented JSON, for diffs a person can read.
func canonical(t testing.TB, v any) string {
	t.Helper()
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// rewriteCases writes cases back with each expect rebuilt (-update).
func rewriteCases(t *testing.T, cases []feedCase) {
	t.Helper()
	for i := range cases {
		cases[i].Expect = buildCase(t, cases[i])
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(cases); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(casesPath, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}
