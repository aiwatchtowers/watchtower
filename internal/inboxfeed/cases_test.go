package inboxfeed

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
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
// fresh migrated file, a moment, the request and the feed Build must
// produce (built_at blank). A case marked desktop is a test-only scenario
// the Desktop's tests seed and serve (FeedCaseTransport): its steps are
// the writes a test makes, each with the feed Go lists after it.
type feedCase struct {
	Name string          `json:"name"`
	Now  string          `json:"now"`
	Seed []string        `json:"seed"`
	Opts api.FeedRequest `json:"opts"`
	// DisabledFeatures are the feature ids turned off for the case (the
	// Mac's feature list; Options.DisabledFeatures).
	DisabledFeatures []string `json:"disabled_features,omitempty"`
	Expect           api.Feed `json:"expect"`
	// Desktop marks a test-only scenario of the Desktop's Inbox tests.
	Desktop bool `json:"desktop,omitempty"`
	// Steps are writes made in turn after the seed, each with its feed.
	Steps []feedStep `json:"steps,omitempty"`
}

// feedStep is one write of a case and the feed after it. The write is SQL
// (what a CLI or another process writes) and/or one inbox.act call (the
// Inbox's own press, run through the tower as the app sends it). When is a
// query answering 1 once this write has landed and 0 before it, and 0 for
// every later step: the Desktop's fake tower serves the feed of the last
// step whose When holds on the test's database, so the list follows the
// test's write the way the tower's would (Go decides what is listed).
type feedStep struct {
	Name   string          `json:"name"`
	SQL    []string        `json:"sql,omitempty"`
	Act    json.RawMessage `json:"act,omitempty"`
	When   string          `json:"when"`
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

// buildSteps runs Build for c (built_at blanked), then makes each step's write on the same
// database and runs Build again: the seed's feed and every step's.
// Each step's When must answer 0 before its write and 1 after it, and
// no later step's When may hold yet.
func buildSteps(t testing.TB, c feedCase) (api.Feed, []api.Feed) {
	t.Helper()
	now, err := time.Parse(time.RFC3339, c.Now)
	if err != nil {
		t.Fatalf("%s: now: %v", c.Name, err)
	}
	d := seeded(t, c.Seed)
	build := func() api.Feed {
		feed, err := Build(context.Background(), d, Options{
			Folder: c.Opts.Folder, Limit: c.Opts.Limit, Clip: c.Opts.Clip, Day: c.Opts.Day, Now: now.UTC(),
			DisabledFeatures: c.DisabledFeatures,
		})
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		feed.BuiltAt = ""
		return feed
	}
	holds := func(s feedStep) bool {
		var n int64
		if err := d.QueryRow(s.When).Scan(&n); err != nil && !errors.Is(err, sql.ErrNoRows) {
			t.Fatalf("%s/%s: when: %v", c.Name, s.Name, err)
		}
		return n != 0
	}
	later := func(from int) {
		for _, s := range c.Steps[from:] {
			if holds(s) {
				t.Fatalf("%s/%s: when holds before its write", c.Name, s.Name)
			}
		}
	}
	base := build()
	later(0)
	steps := make([]api.Feed, len(c.Steps))
	for i, s := range c.Steps {
		if s.When == "" || (len(s.SQL) == 0 && len(s.Act) == 0) {
			t.Fatalf("%s/%s: a step needs a write and a when", c.Name, s.Name)
		}
		for _, stmt := range s.SQL {
			if _, err := d.Exec(stmt); err != nil {
				t.Fatalf("%s/%s: %q: %v", c.Name, s.Name, stmt, err)
			}
		}
		if len(s.Act) > 0 {
			resp := callAct(t, actTower(d, now.UTC(), fixtureDeps(t, d)), s.Act, socket)
			if resp.Status != api.StatusOK {
				t.Fatalf("%s/%s: inbox.act %s: %+v", c.Name, s.Name, resp.Status, resp.Refusal)
			}
		}
		if !holds(s) {
			t.Fatalf("%s/%s: when does not hold after its write", c.Name, s.Name)
		}
		later(i + 1)
		steps[i] = build()
	}
	return base, steps
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
		var steps []api.Feed
		cases[i].Expect, steps = buildSteps(t, cases[i])
		for j := range steps {
			cases[i].Steps[j].Expect = steps[j]
		}
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
