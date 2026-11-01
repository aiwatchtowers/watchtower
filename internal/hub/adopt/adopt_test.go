package adopt

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/state/swiftfixture"
	"watchtower/internal/logcanary"
)

const (
	fixtureHubID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
	phoneA       = "0B0B0B0B-0B0B-4B0B-8B0B-0B0B0B0B0B0B"
	phoneB       = "0C0C0C0C-0C0C-4C0C-8C0C-0C0C0C0C0C0C"
	errCanary    = "Disk full while writing the acme standup"
)

// swiftStatuses are the seven Swift phone_recordings statuses; the first
// five are in progress.
var swiftStatuses = []string{"received", "queued", "transcribing", "diarizing", "summarizing", "done", "failed"}

// fixture is a Mac with a Swift hub: <root>/support/MobileHub (the Swift
// sidecar, transport.db, SliceAssets/), <root>/support/recordings (the
// transcriber's folder, where the Swift rows' audio is and where adoption
// moves it), <root>/support/elsewhere (one row's audio outside it) and
// <root>/data/.hub (the Go hub dir).
type fixture struct {
	root, mobile, hub, rec, outside string
	now                             time.Time
	updated                         float64 // every phone_recordings row's updated_at
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	return newFixtureIn(t, t.TempDir(), nil)
}

// newFixtureIn builds the fixture under root; mutate (nil = none) then
// changes the Swift file, e.g. to drop a column.
func newFixtureIn(t *testing.T, root string, mutate func(*sql.DB) error) *fixture {
	t.Helper()
	f := &fixture{
		root: root, mobile: filepath.Join(root, "support", "MobileHub"), hub: filepath.Join(root, "data", ".hub"),
		rec: filepath.Join(root, "support", "recordings"), outside: filepath.Join(root, "support", "elsewhere"),
		now: time.Unix(1_800_000_000, 0).UTC(), updated: 1_799_990_000.5,
	}
	for _, d := range []string{f.mobile, f.rec, f.outside, filepath.Join(f.mobile, "SliceAssets", "rec_one")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	db, err := swiftfixture.Create(filepath.Join(f.mobile, state.FileName), fixtureHubID, swiftfixture.Schema)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	devCols := "device_id, name, scope, user_record_name, linked_at, typing_allowed, start_sessions_granted, signing_key, agreement_key, link_nonce, last_seq"
	exec(`INSERT INTO devices (`+devCols+`) VALUES (?, 'phone A', 'shared', '_acme', 1700000000.5, 1, 0, x'0102', x'0304', 'nonce1', 9)`, phoneA)
	exec(`INSERT INTO devices (`+devCols+`) VALUES (?, 'phone B', 'private', '_acme', 1700000001.5, 0, 1, x'0506', x'0708', 'nonce2', 3)`, phoneB)
	exec(`INSERT INTO hub_epochs (epoch, sealed_keys, created_at, first_seq) VALUES (1, x'aa01', 1700000000, 1), (2, x'aa02', 1700000500, 40)`)
	exec(`INSERT INTO relay_processed (record_name, phase, outcome, updated_at, echo, done_seq) VALUES ('a-upload-1', 'done', 'received', 1700000100, x'e0e1e2', 12)`)
	exec(`INSERT INTO slice_state (record_name, payload_hash, pushed_at) VALUES ('workbench-1', 'hash-1', 1700000200), ('timeline-today', 'hash-2', 1700000300)`)
	exec(`INSERT INTO slice_assets (file_path, descriptor) VALUES ('rec_one/asset.bin', x'd0d1')`)
	exec(`INSERT INTO work_alerts (key, seen_at, generation) VALUES ('alert-1', 1700000400, 2)`)
	// Milestones with a rowid gap: the copy keeps the rowids.
	exec(`INSERT INTO session_milestones (rowid, session_id, at, kind, text) VALUES (1, 4, 1700000000, 'state', 'a'), (3, 4, 1700000001, 'state', 'b'), (7, 5, 1700000002, 'state', 'c')`)
	for _, s := range swiftStatuses {
		audio := filepath.Join(f.rec, "acme standup "+s+".m4a")
		var tid any
		var errText any
		switch s {
		case "done":
			tid = 7
		case "failed":
			errText = errCanary
		}
		exec(`INSERT INTO phone_recordings (upload_id, audio_path, transcript_id, status, percent, error, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?)`,
			"rec-"+s, audio, tid, s, errText, f.updated)
		if err := os.WriteFile(audio, []byte("audio of "+s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// In progress, its audio outside the transcriber's folder: left there.
	outsideAudio := filepath.Join(f.outside, "acme outside.m4a")
	exec(`INSERT INTO phone_recordings (upload_id, audio_path, status, updated_at) VALUES ('rec-outside', ?, 'queued', ?)`, outsideAudio, f.updated)
	if err := os.WriteFile(outsideAudio, []byte("outside audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	exec(`INSERT INTO phone_recordings (upload_id, audio_path, status, updated_at) VALUES ('bad/id', '', 'queued', ?)`, f.updated)
	if mutate != nil {
		if err := mutate(db); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(f.mobile, "SliceAssets", "rec_one", "asset.bin"), []byte("sealed asset"), 0o600); err != nil {
		t.Fatal(err)
	}
	tdb, err := sql.Open("sqlite3", filepath.Join(f.mobile, "transport.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tdb.Exec(`CREATE TABLE engine_state (id INTEGER PRIMARY KEY, data BLOB); INSERT INTO engine_state VALUES (1, x'c0ffee')`); err != nil {
		t.Fatal(err)
	}
	_ = tdb.Close()
	return f
}

// wantCounts is what the fixture's adoption imports.
var wantCounts = Counts{Devices: 2, Jobs: 8, Skipped: 1, AudioLeft: 1}

func (f *fixture) settings() Settings {
	return Settings{Enabled: true, StartSessionAllows: map[string]bool{strings.ToLower(phoneA): true, phoneB: false, "FFFFFFFF-0000-4000-8000-000000000000": true}}
}

func (f *fixture) run(t *testing.T) (Result, error) {
	t.Helper()
	return Run(context.Background(), f.mobile, f.hub, f.rec, f.settings(), func() time.Time { return f.now })
}

func (f *fixture) mustRun(t *testing.T) Result {
	t.Helper()
	res, err := f.run(t)
	if err != nil {
		t.Fatalf("Run: %v (%+v)", err, res)
	}
	return res
}

// goDB opens the Go sidecar raw for assertions.
func (f *fixture) goDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := rawOpen(filepath.Join(f.hub, state.FileName), openRO)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func (f *fixture) store(t *testing.T) *state.Store {
	t.Helper()
	st, err := state.Open(f.hub)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func scalar[T any](t *testing.T, db *sql.DB, q string, args ...any) T {
	t.Helper()
	var v T
	if err := db.QueryRow(q, args...).Scan(&v); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return v
}

// snapshot is the end state of an adoption, with the fixture root replaced:
// every table's rows (the goose table by version only), every file under
// the root with its bytes, and their modes.
func (f *fixture) snapshot(t *testing.T) string {
	t.Helper()
	var b strings.Builder
	db := f.goDB(t)
	for _, tbl := range tableNames(t, db) {
		q := `SELECT * FROM "` + tbl + `"`
		if strings.HasPrefix(tbl, "goose") {
			q = `SELECT version_id, is_applied FROM "` + tbl + `"`
		}
		lines := tableRows(t, db, q)
		fmt.Fprintf(&b, "table %s (%d)\n%s\n", tbl, len(lines), strings.Join(lines, "\n"))
	}
	_ = filepath.WalkDir(f.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(f.root, path)
		base := filepath.Base(path)
		if base == state.FileName || strings.HasPrefix(base, state.FileName+"-") || base == "hub.lock" || base == "hubstate.db.migrate.lock" {
			fmt.Fprintf(&b, "file %s\n", rel) // compared by its rows above
			return nil
		}
		fi, _ := d.Info()
		if d.IsDir() {
			fmt.Fprintf(&b, "dir %s %v\n", rel, fi.Mode().Perm())
			return nil
		}
		data, _ := os.ReadFile(path) //nolint:gosec // G122: the test's own temp dir
		fmt.Fprintf(&b, "file %s %v %q\n", rel, fi.Mode().Perm(), strings.ReplaceAll(string(data), f.root, "<root>"))
		return nil
	})
	return strings.ReplaceAll(b.String(), f.root, "<root>")
}

func tableNames(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite%' ORDER BY name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, n)
	}
	return tables
}

// tableRows is every row of q, blobs in hex, sorted.
func tableRows(t *testing.T, db *sql.DB, q string) []string {
	t.Helper()
	r, err := db.Query(q)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	cols, _ := r.Columns()
	var lines []string
	for r.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := r.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		for i, v := range vals {
			if bs, ok := v.([]byte); ok {
				vals[i] = fmt.Sprintf("%x", bs)
			}
		}
		lines = append(lines, fmt.Sprint(vals...))
	}
	sort.Strings(lines)
	return lines
}

func TestAdoptImportsEveryTable(t *testing.T) {
	f := newFixture(t)
	res := f.mustRun(t)
	if res.Step != StepDone || res.Error != "" || res.Imported != wantCounts {
		t.Fatalf("result = %+v", res)
	}
	db := f.goDB(t)
	if v := scalar[string](t, db, `SELECT value FROM hub_meta WHERE key = 'hub_id'`); v != fixtureHubID {
		t.Errorf("hub_id = %q", v)
	}
	if n := scalar[int](t, db, `SELECT count(*) FROM devices`); n != 2 {
		t.Errorf("devices = %d", n)
	}
	if v := scalar[string](t, db, `SELECT hex(signing_key) || hex(agreement_key) || link_nonce || last_seq FROM devices WHERE device_id = ?`, phoneA); v != "01020304nonce19" {
		t.Errorf("phone A = %q", v)
	}
	if v := scalar[string](t, db, `SELECT group_concat(epoch || ':' || hex(sealed_keys) || ':' || first_seq, ',') FROM (SELECT * FROM hub_epochs ORDER BY epoch)`); v != "1:AA01:1,2:AA02:40" {
		t.Errorf("epochs = %q", v)
	}
	if v := scalar[string](t, db, `SELECT phase || outcome || hex(echo) || done_seq FROM relay_processed WHERE record_name = 'a-upload-1'`); v != "donereceivedE0E1E212" {
		t.Errorf("ledger = %q", v)
	}
	if v := scalar[string](t, db, `SELECT group_concat(record_name || '=' || payload_hash, ',') FROM (SELECT * FROM slice_state ORDER BY record_name)`); v != "timeline-today=hash-2,workbench-1=hash-1" {
		t.Errorf("slice hashes = %q", v)
	}
	if v := scalar[string](t, db, `SELECT hex(descriptor) FROM slice_assets WHERE file_path = 'rec_one/asset.bin'`); v != "D0D1" {
		t.Errorf("slice asset = %q", v)
	}
	if n := scalar[int](t, db, `SELECT count(*) FROM work_alerts`); n != 1 {
		t.Errorf("work alerts = %d", n)
	}
	if v := scalar[string](t, db, `SELECT group_concat(rowid || text, ',') FROM (SELECT rowid, text FROM session_milestones ORDER BY rowid)`); v != "1a,3b,7c" {
		t.Errorf("milestone rowids = %q", v)
	}
	// Every migration on the branch applied (derived from the embedded FS).
	mfs, err := state.Migrations()
	if err != nil {
		t.Fatal(err)
	}
	ents, err := fs.ReadDir(mfs, ".")
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".sql") {
			var v int
			if _, err := fmt.Sscanf(e.Name(), "%05d_", &v); err != nil {
				t.Fatal(err)
			}
			want = append(want, fmt.Sprint(v))
		}
	}
	if len(want) < 8 {
		t.Fatalf("migrations found = %v", want)
	}
	got := scalar[string](t, db, `SELECT group_concat(version_id, ',') FROM (SELECT version_id FROM goose_db_version WHERE version_id > 0 AND is_applied ORDER BY version_id)`)
	if got != strings.Join(want, ",") {
		t.Errorf("applied migrations = %s, want %s", got, strings.Join(want, ","))
	}
	if b, err := os.ReadFile(filepath.Join(f.hub, "assets", "rec_one", "asset.bin")); err != nil || string(b) != "sealed asset" {
		t.Errorf("slice asset file = %q %v", b, err)
	}
	ck, err := os.Stat(filepath.Join(f.hub, "cloudkit"))
	if err != nil || ck.Mode().Perm() != 0o700 {
		t.Fatalf("cloudkit dir = %v %v", ck, err)
	}
	tdb, err := rawOpen(filepath.Join(f.hub, "cloudkit", "transport.db"), openRO)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tdb.Close() }()
	if v := scalar[string](t, tdb, `SELECT hex(data) FROM engine_state`); v != "C0FFEE" {
		t.Errorf("transport state = %q", v)
	}
	if exists(filepath.Join(f.hub, tmpDirName)) {
		t.Error("adopt.tmp left behind")
	}
	// Settings and transport.
	if v := scalar[string](t, db, `SELECT value FROM hub_meta WHERE key = 'enabled'`); v != "1" {
		t.Errorf("enabled = %q", v)
	}
	if v := scalar[string](t, db, `SELECT value FROM hub_meta WHERE key = 'transport'`); v != "cloudkit" {
		t.Errorf("transport = %q", v)
	}
	if v := scalar[string](t, db, `SELECT group_concat(start_sessions_granted, ',') FROM (SELECT * FROM devices ORDER BY device_id)`); v != "1,0" {
		t.Errorf("start-session grants = %q", v)
	}
	if v := scalar[string](t, db, `SELECT value FROM hub_meta WHERE key = 'adopted_at'`); v != "1800000000.000" {
		t.Errorf("adopted_at = %q", v)
	}
	if n := scalar[int](t, db, `SELECT count(*) FROM hub_meta WHERE key = 'adopt_error'`); n != 0 {
		t.Error("adopt_error left")
	}
	// The second run does nothing.
	if _, err := f.run(t); !errors.Is(err, ErrAlreadyAdopted) {
		t.Fatalf("second Run = %v", err)
	}
}

func TestAdoptSwitchesToWAL(t *testing.T) {
	f := newFixture(t)
	sdb, err := rawOpen(filepath.Join(f.mobile, state.FileName), openRO)
	if err != nil {
		t.Fatal(err)
	}
	if m := scalar[string](t, sdb, `PRAGMA journal_mode`); m != "delete" {
		t.Fatalf("fixture journal mode = %q", m)
	}
	_ = sdb.Close()
	f.mustRun(t)
	if m := scalar[string](t, f.goDB(t), `PRAGMA journal_mode`); m != "wal" {
		t.Fatalf("adopted journal mode = %q", m)
	}
}

func TestAdoptCreatesNoHeldUploads(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	if n := scalar[int](t, f.goDB(t), `SELECT count(*) FROM held_uploads`); n != 0 {
		t.Fatalf("held_uploads = %d", n)
	}
}

// TestAPendingUploadAfterAdoptionIsARepeat: an upload record still in the
// RelayZone is read once by the Go intake, whose HasRecording check (before
// any download) answers it received again for every adopted upload.
func TestAPendingUploadAfterAdoptionIsARepeat(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	st := f.store(t)
	for _, s := range swiftStatuses {
		if ok, err := st.HasRecording("rec-" + s); err != nil || !ok {
			t.Errorf("rec-%s: HasRecording = %v %v", s, ok, err)
		}
	}
}

func TestMovedNoteContent(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	ents, err := os.ReadDir(f.mobile)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != "MOVED" {
		t.Fatalf("MobileHub = %v", ents)
	}
	p := filepath.Join(f.mobile, "MOVED")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if want := []byte("hub_impl=go\nmoved_to=" + f.hub + "\n"); !bytes.Equal(b, want) {
		t.Fatalf("MOVED = %q, want %q", b, want)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o600 {
		t.Fatalf("MOVED mode = %v", fi.Mode().Perm())
	}
}

// TestALaterMobileHubIsNeverImported (Review Focus 2): a pre-guard app after
// a downgrade leaves a new MobileHub/ with a new, unlinked identity; it never
// replaces the adopted links, and it is neither read nor deleted.
func TestALaterMobileHubIsNeverImported(t *testing.T) {
	sink := logcanary.Capture(t)
	f := newFixture(t)
	f.mustRun(t)
	before := f.snapshot(t)
	later := filepath.Join(f.mobile, state.FileName)
	db, err := swiftfixture.Create(later, "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", swiftfixture.Schema)
	if err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	laterBytes, _ := os.ReadFile(later)
	laterInfo, _ := os.Stat(later)

	res, err := f.run(t)
	if !errors.Is(err, ErrLaterMobileHub) || res.Error != ClassLaterMobileHub {
		t.Fatalf("Run = %+v %v", res, err)
	}
	if !strings.Contains(sink.String(), LaterMobileHubLog) {
		t.Errorf("log = %q", sink.String())
	}
	if b, _ := os.ReadFile(later); !bytes.Equal(b, laterBytes) {
		t.Error("the later sidecar changed")
	}
	if fi, _ := os.Stat(later); !fi.ModTime().Equal(laterInfo.ModTime()) {
		t.Error("the later sidecar was touched")
	}
	_ = os.Remove(later) // the snapshot walks the root
	if after := f.snapshot(t); after != before {
		t.Fatalf("adopted state changed:\n%s\nvs\n%s", after, before)
	}
	_ = os.WriteFile(later, laterBytes, 0o600)
	rep, err := Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	// Run refuses it, so it reads ignored (no Retry that cannot succeed).
	if rep.HubID != fixtureHubID || rep.SwiftState != "ignored" || rep.Step != StepDone {
		t.Fatalf("status = %+v", rep)
	}

	// A Go hub that ran first (never adopted) is not overwritten either.
	g := newFixture(t)
	st, err := state.Open(g.hub)
	if err != nil {
		t.Fatal(err)
	}
	_ = st.Close()
	if _, err := g.run(t); !errors.Is(err, ErrLaterMobileHub) {
		t.Fatalf("Run over a Go hub of its own = %v", err)
	}
	if !exists(filepath.Join(g.mobile, state.FileName)) || exists(filepath.Join(g.mobile, "MOVED")) {
		t.Fatal("the Swift sidecar beside a Go hub of its own was touched")
	}
	if rep, err := Status(g.mobile, g.hub); err != nil || rep.SwiftState != "ignored" {
		t.Fatalf("status beside a Go hub of its own = %+v %v", rep, err)
	}
}

func TestAdoptWithNothingToAdopt(t *testing.T) {
	root := t.TempDir()
	_, err := Run(context.Background(), filepath.Join(root, "MobileHub"), filepath.Join(root, ".hub"), "", Settings{}, nil)
	if !errors.Is(err, ErrNothingToAdopt) {
		t.Fatalf("Run = %v", err)
	}
}

// TestAdoptFinishesFromALeftoverCopy: a verified copy in adopt.tmp whose
// Swift sidecar has gone is adopted from the copy, not dropped.
func TestAdoptFinishesFromALeftoverCopy(t *testing.T) {
	f := newFixture(t)
	killAt(t, "verify")
	if _, err := f.run(t); !errors.Is(err, errKilled) {
		t.Fatalf("killed run = %v", err)
	}
	if err := os.Remove(filepath.Join(f.mobile, state.FileName)); err != nil {
		t.Fatal(err)
	}
	if res, err := f.run(t); err != nil || res.Step != StepDone {
		t.Fatalf("Run from the copy = %+v %v", res, err)
	}
	if v := scalar[string](t, f.goDB(t), `SELECT value FROM hub_meta WHERE key = 'hub_id'`); v != fixtureHubID {
		t.Fatalf("hub_id = %q", v)
	}
}

func TestFILES01_AdoptLogsCountsOnly(t *testing.T) {
	sink := logcanary.Capture(t)
	canary := logcanary.Text("path")
	f := newFixtureIn(t, filepath.Join(t.TempDir(), canary), nil)
	sdb, err := rawOpen(filepath.Join(f.mobile, state.FileName), openRW)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sdb.Exec(`UPDATE devices SET name = ?`, logcanary.Text("name")); err != nil {
		t.Fatal(err)
	}
	if _, err := sdb.Exec(`UPDATE phone_recordings SET error = ? WHERE status = 'failed'`, logcanary.Text("error")); err != nil {
		t.Fatal(err)
	}
	_ = sdb.Close()
	// A recordings dir that cannot be created: logged without its path.
	blocked := filepath.Join(f.root, "blocked")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	f.rec = filepath.Join(blocked, canary)
	f.mustRun(t)
	// A refused adoption logs its class only.
	g := newFixtureIn(t, filepath.Join(t.TempDir(), canary), dropColumn("devices", "scope"))
	_, _ = g.run(t)
	sink.AssertClean(t)
	if !strings.Contains(sink.String(), "2 phones, 8 recording jobs, 1 skipped") {
		t.Errorf("log = %q", sink.String())
	}
}
