package adopt

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"watchtower/internal/hub/state"
)

var errKilled = errors.New("killed")

// killPoints are every point a kill can land between two commits: after
// each step, and inside the steps that touch several files.
var killPoints = []string{
	"copy", "verify",
	"rename:assets", "rename:transport", "rename:state", "rename",
	"migrate",
	"recordings:files", "recordings",
	"settings", "transport",
	"moved:note", "moved",
	"done",
}

// killAt makes Run stop at point, once, as a kill there would.
func killAt(t *testing.T, point string) {
	t.Helper()
	fired := false
	prev := stepHook
	stepHook = func(p string) error {
		if p == point && !fired {
			fired = true
			return errKilled
		}
		return nil
	}
	t.Cleanup(func() { stepHook = prev })
}

// TestAdoptResumesAfterAKillAtEveryStep (Review Focus 1): a run killed at
// any point leaves no hub id but the Swift one, and the next run finishes
// the same adoption — the end state equals an uninterrupted run's, with one
// copy of every row. Between the runs the recordings kept read without
// error (hub status never fails mid-adoption).
func TestAdoptResumesAfterAKillAtEveryStep(t *testing.T) {
	ref := newFixtureIn(t, filepath.Join(t.TempDir(), "mac"), nil)
	ref.mustRun(t)
	want := ref.snapshot(t)

	// The matrix is exhaustive: every point an uninterrupted run passes is
	// in it, and every point in it is passed.
	var seen []string
	prev := stepHook
	stepHook = func(p string) error { seen = append(seen, p); return nil }
	probe := newFixture(t)
	probe.mustRun(t)
	stepHook = prev
	if strings.Join(seen, ",") != strings.Join(killPoints, ",") {
		t.Fatalf("hook points = %v, matrix = %v", seen, killPoints)
	}

	for _, point := range killPoints {
		t.Run(point, func(t *testing.T) {
			f := newFixtureIn(t, filepath.Join(t.TempDir(), "mac"), nil)
			killAt(t, point)
			if _, err := f.run(t); !errors.Is(err, errKilled) {
				t.Fatalf("killed run = %v", err)
			}
			rep, err := Status(f.mobile, f.hub)
			if err != nil {
				t.Fatal(err)
			}
			if rep.HubID != fixtureHubID {
				t.Fatalf("hub_id after a kill at %s = %q", point, rep.HubID)
			}
			if exists(filepath.Join(f.hub, state.FileName)) {
				if v, _ := readMeta(filepath.Join(f.hub, state.FileName), false, MetaAdoptedAt); v[MetaAdoptedAt] != "" && point != "done" {
					t.Fatalf("adopted_at set after a kill at %s", point)
				}
				st, err := state.OpenReadOnly(f.hub)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := Kept(context.Background(), st, f.rec); err != nil {
					t.Fatalf("Kept after a kill at %s: %v", point, err)
				}
				_ = st.Close()
			}
			res, err := f.run(t)
			if point == "done" {
				if !errors.Is(err, ErrAlreadyAdopted) {
					t.Fatalf("run after a kill at done = %+v %v", res, err)
				}
			} else if err != nil || res.Step != StepDone {
				t.Fatalf("resumed run = %+v %v", res, err)
			}
			if got := f.snapshot(t); got != want {
				t.Fatalf("end state after a kill at %s differs:\n--- got\n%s\n--- want\n%s", point, got, want)
			}
			if _, err := f.run(t); !errors.Is(err, ErrAlreadyAdopted) {
				t.Fatalf("third run = %v", err)
			}
		})
	}
}

// dropColumn is a fixture mutation: the Swift file of a build without
// table.column.
func dropColumn(table, column string) func(*sql.DB) error {
	return func(db *sql.DB) error {
		if table == "slice_state" && column == "wire_name" {
			if _, err := db.Exec(`DROP INDEX slice_state_by_wire`); err != nil {
				return err
			}
		}
		_, err := db.Exec(`ALTER TABLE ` + table + ` DROP COLUMN ` + column)
		return err
	}
}

// TestAdoptAddsEveryMissingFoldedInColumn: a Swift file from a build that
// had not added one of the ALTER columns yet gains it in the copy, before
// the commit point, with the Swift ALTER's type and default — as the Swift
// hub's own upgrade would have — and adopts.
func TestAdoptAddsEveryMissingFoldedInColumn(t *testing.T) {
	for _, c := range foldedIn {
		t.Run(c.table+"."+c.column, func(t *testing.T) {
			f := newFixtureIn(t, t.TempDir(), dropColumn(c.table, c.column))
			if err := CheckSwiftFile(filepath.Join(f.mobile, state.FileName)); !errors.Is(err, ErrSwiftSchema) {
				t.Fatalf("CheckSwiftFile without the column = %v", err)
			}
			if res, err := f.run(t); err != nil || res.Step != StepDone {
				t.Fatalf("Run = %+v %v", res, err)
			}
			db := f.goDB(t)
			var typ string
			var notNull int
			var dflt sql.NullString
			if err := db.QueryRow(`SELECT type, "notnull", dflt_value FROM pragma_table_info(?) WHERE name = ?`, c.table, c.column).Scan(&typ, &notNull, &dflt); err != nil {
				t.Fatalf("column after adoption: %v", err)
			}
			got := typ
			if notNull == 1 {
				got += " NOT NULL"
			}
			if dflt.Valid {
				got += " DEFAULT " + dflt.String
			}
			if got != c.typ {
				t.Fatalf("column = %q, want %q", got, c.typ)
			}
		})
	}
	if err := CheckSwiftFile(filepath.Join(newFixture(t).mobile, state.FileName)); err != nil {
		t.Fatalf("CheckSwiftFile on today's file = %v", err)
	}
}

// TestFoldedInMatchesTheSwiftAlters pins foldedIn to the Swift hub's ALTER
// columns: the (name, type) pairs of HubSyncState+Keys.swift's
// addMissingColumns calls and HubSyncState.swift's relay_processed pairs,
// plus HubSyncState.swift's devices names (type INTEGER NOT NULL DEFAULT 0).
func TestFoldedInMatchesTheSwiftAlters(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "WatchtowerDesktop", "Sources", "Services", "MobileHub")
	var swift []string
	pair := regexp.MustCompile(`\("([a-z_]+)", "([A-Z][^"]*)"\)`)
	for _, name := range []string{"HubSyncState.swift", "HubSyncState+Keys.swift"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Skipf("the Swift hub's source is gone (Task 24): %v", err)
		}
		for _, m := range pair.FindAllStringSubmatch(string(b), -1) {
			swift = append(swift, m[1]+" "+m[2])
		}
		if name == "HubSyncState.swift" {
			list := regexp.MustCompile(`for name in \[([^\]]*)\]`).FindStringSubmatch(string(b))
			if list == nil {
				t.Fatal("the devices ALTER names were not found")
			}
			for _, n := range regexp.MustCompile(`"([a-z_]+)"`).FindAllStringSubmatch(list[1], -1) {
				swift = append(swift, n[1]+" INTEGER NOT NULL DEFAULT 0")
			}
		}
	}
	var ours []string
	for _, c := range foldedIn {
		ours = append(ours, c.column+" "+c.typ)
	}
	sort.Strings(swift)
	sort.Strings(ours)
	if strings.Join(swift, "\n") != strings.Join(ours, "\n") {
		t.Fatalf("Swift ALTER columns:\n%s\nfoldedIn:\n%s", strings.Join(swift, "\n"), strings.Join(ours, "\n"))
	}
}

// refusedBeforeTheCommitPoint asserts nothing moved and the class is kept.
func refusedBeforeTheCommitPoint(t *testing.T, f *fixture, class string) {
	t.Helper()
	if exists(filepath.Join(f.hub, state.FileName)) || exists(filepath.Join(f.mobile, MovedName)) {
		t.Fatal("something moved")
	}
	rep, err := Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Error != class || rep.SwiftState != "present" {
		t.Fatalf("status = %+v", rep)
	}
}

func TestAdoptRefusesASchemaItCannotMigrate(t *testing.T) {
	f := newFixtureIn(t, t.TempDir(), dropColumn("devices", "scope"))
	swift := filepath.Join(f.mobile, state.FileName)
	before, _ := os.ReadFile(swift)
	res, err := f.run(t)
	if !errors.Is(err, ErrSwiftSchema) || res.Error != ClassSwiftSchema || res.Step != StepVerify {
		t.Fatalf("Run = %+v %v", res, err)
	}
	refusedBeforeTheCommitPoint(t, f, ClassSwiftSchema)
	if b, _ := os.ReadFile(swift); !bytes.Equal(b, before) {
		t.Fatal("the Swift sidecar changed")
	}
}

func TestAdoptRefusesAFileWithoutAHubID(t *testing.T) {
	for name, q := range map[string]string{
		"missing":   `DELETE FROM hub_meta WHERE key = 'hub_id'`,
		"not_uuid":  `UPDATE hub_meta SET value = 'acme' WHERE key = 'hub_id'`,
		"truncated": `UPDATE hub_meta SET value = 'AAAAAAAA-AAAA-4AAA-8AAA' WHERE key = 'hub_id'`,
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixtureIn(t, t.TempDir(), func(db *sql.DB) error { _, err := db.Exec(q); return err })
			res, err := f.run(t)
			if !errors.Is(err, ErrSwiftHubID) || res.Error != ClassSwiftHubID {
				t.Fatalf("Run = %+v %v", res, err)
			}
			refusedBeforeTheCommitPoint(t, f, ClassSwiftHubID)
		})
	}
}

// TestAdoptRefusesABusySwiftFile: another connection on the Swift file (the
// Swift hub still running) fails the copy with swift_busy: a WAL reader
// blocks the full checkpoint, a DELETE-mode reader the exclusive lock.
func TestAdoptRefusesABusySwiftFile(t *testing.T) {
	prev := swiftBusyTimeout
	swiftBusyTimeout = "100"
	t.Cleanup(func() { swiftBusyTimeout = prev })
	for _, mode := range []string{"wal", "delete"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			path := filepath.Join(f.mobile, state.FileName)
			db, err := rawOpen(path, openRW)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = db.Close() }()
			if mode == "wal" {
				if _, err := db.Exec(`PRAGMA journal_mode = WAL`); err != nil {
					t.Fatal(err)
				}
				if _, err := db.Exec(`INSERT INTO work_alerts (key, seen_at, generation) VALUES ('alert-2', 1, 1)`); err != nil {
					t.Fatal(err)
				}
			}
			tx, err := db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback() }()
			var n int
			if err := tx.QueryRow(`SELECT count(*) FROM devices`).Scan(&n); err != nil {
				t.Fatal(err)
			}
			res, err := f.run(t)
			if !errors.Is(err, ErrSwiftBusy) || res.Error != ClassSwiftBusy || res.Step != StepCopy {
				t.Fatalf("Run = %+v %v", res, err)
			}
			if exists(filepath.Join(f.hub, state.FileName)) {
				t.Fatal("something moved")
			}
			// Once the other connection is gone, the adoption goes through.
			_ = tx.Rollback()
			_ = db.Close()
			if res, err := f.run(t); err != nil || res.Step != StepDone {
				t.Fatalf("Run after = %+v %v", res, err)
			}
		})
	}
}

// TestStatusAndRunLeaveNoLogsInMobileHub: Status reads a WAL-mode Swift
// file without its -shm and creates nothing in MobileHub/; Run leaves no
// -wal or -shm there either.
func TestStatusAndRunLeaveNoLogsInMobileHub(t *testing.T) {
	f := newFixture(t)
	path := filepath.Join(f.mobile, state.FileName)
	db, err := rawOpen(path, openRW)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA journal_mode = WAL`); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	for _, s := range []string{"-wal", "-shm"} {
		_ = os.Remove(path + s)
	}
	list := func() string {
		ents, _ := os.ReadDir(f.mobile)
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		return strings.Join(names, ",")
	}
	before := list()
	rep, err := Status(f.mobile, f.hub)
	if err != nil || rep.HubID != fixtureHubID || len(rep.PendingRecordings) != 7 {
		t.Fatalf("Status = %+v %v", rep, err)
	}
	if after := list(); after != before {
		t.Fatalf("Status changed MobileHub: %s → %s", before, after)
	}
	killAt(t, "copy")
	if _, err := f.run(t); !errors.Is(err, errKilled) {
		t.Fatalf("killed run = %v", err)
	}
	for _, s := range []string{"-wal", "-shm"} {
		if exists(path + s) {
			t.Errorf("the copy left %s beside the Swift file", s)
		}
	}
}
