package db

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// sparseFixture is compactFixture with rows messages carrying an 8 KiB
// raw_json, inserted in one transaction and then emptied by migration
// 00134's UPDATE — the free pages a compaction reclaims.
func sparseFixture(t *testing.T, rows int) string {
	t.Helper()
	path := compactFixture(t)
	fillSparse(t, path, rows)
	return path
}

func fillSparse(t *testing.T, path string, rows int) {
	t.Helper()
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	raw := `{"pad":"` + strings.Repeat("x", 8<<10) + `"}`
	for i := range rows {
		_, err := tx.Exec(`INSERT INTO messages (channel_id, ts, text, raw_json) VALUES (?, ?, ?, ?)`,
			"acme:C1", fmt.Sprintf("%d.000100", 1700000000+i), fmt.Sprintf("message %d", i), raw)
		if err != nil {
			t.Fatalf("insert: %v", err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE messages SET raw_json = '{}' WHERE raw_json != '{}'`); err != nil {
		t.Fatalf("emptying raw_json: %v", err)
	}
}

// messagesDigest is the message count and a SHA-256 of every text in rowid
// order, read without migrating.
func messagesDigest(t *testing.T, path string) (int, [32]byte) {
	t.Helper()
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	var texts string
	if err := d.QueryRow(`SELECT COALESCE(group_concat(text, char(31)), '') FROM (SELECT text FROM messages ORDER BY rowid)`).Scan(&texts); err != nil {
		t.Fatal(err)
	}
	return n, sha256.Sum256([]byte(texts))
}

func maintenanceKeys(t *testing.T, path string) map[string]string {
	t.Helper()
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	rows, err := d.Query(`SELECT key, value FROM db_maintenance`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			t.Fatal(err)
		}
		out[k] = v
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestCompact_ShrinksSparseFixture(t *testing.T) {
	path := sparseFixture(t, 4000)
	countBefore, sumBefore := messagesDigest(t, path)

	res, err := Compact(context.Background(), path, CompactOptions{Reason: "migration:134", Version: "1.0.0"})
	if err != nil {
		t.Fatalf("Compact: %v (%+v)", err, res)
	}
	if !res.Compacted || res.Skipped != "" || res.Reason != "migration:134" {
		t.Fatalf("got %+v, want compacted with the reason carried", res)
	}
	if res.BytesAfter >= res.BytesBefore/2 {
		t.Fatalf("bytes %d → %d, want under half", res.BytesBefore, res.BytesAfter)
	}
	countAfter, sumAfter := messagesDigest(t, path)
	if countAfter != countBefore || sumAfter != sumBefore {
		t.Fatalf("messages changed: %d rows → %d, checksum equal = %v", countBefore, countAfter, sumAfter == sumBefore)
	}
	keys := maintenanceKeys(t, path)
	if keys[maintLastCompactedVersion] != fmt.Sprint(highestAppliedVersion(t, path)) {
		t.Fatalf("last_compacted_version = %q, want %d", keys[maintLastCompactedVersion], highestAppliedVersion(t, path))
	}
	if _, err := time.Parse(time.RFC3339, keys[maintCompactedAt]); err != nil || !strings.HasSuffix(keys[maintCompactedAt], "Z") {
		t.Fatalf("compacted_at = %q, want RFC 3339 UTC (%v)", keys[maintCompactedAt], err)
	}
	if c := checkCompaction(t, path, "1.0.0"); c.Due {
		t.Fatalf("still due after compacting: %+v", c)
	}
}

func TestCompact_DiskShortLeavesDBUntouched(t *testing.T) {
	path := compactFixture(t)
	stubFreeDisk(t, 0)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
	if err != nil || res.Skipped != "disk" || res.Compacted {
		t.Fatalf("got (%+v, %v), want skipped disk, nil", res, err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		t.Fatalf("file changed: size %d → %d, mtime %v → %v", before.Size(), after.Size(), before.ModTime(), after.ModTime())
	}
	if keys := maintenanceKeys(t, path); len(keys) != 0 {
		t.Fatalf("db_maintenance written on a disk skip: %v", keys)
	}

	res, err = Compact(context.Background(), path, CompactOptions{Force: true, Version: "1.0.0"})
	if err != nil || !res.Compacted {
		t.Fatalf("Force: got (%+v, %v), want compacted", res, err)
	}
}

func TestCompact_SchemaPendingRefuses(t *testing.T) {
	path := compactFixture(t)
	compactExec(t, path, `DELETE FROM goose_db_version WHERE version_id = (SELECT MAX(version_id) FROM goose_db_version)`)
	countGoose := func() int {
		d, err := OpenExisting(path, compactCheckBusy)
		if err != nil {
			t.Fatalf("OpenExisting: %v", err)
		}
		defer d.Close()
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM goose_db_version`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := countGoose()

	res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
	if err != nil || res.Skipped != "schema_pending" || res.Compacted {
		t.Fatalf("got (%+v, %v), want skipped schema_pending, nil", res, err)
	}
	if after := countGoose(); after != before {
		t.Fatalf("goose_db_version rows %d → %d: compaction migrated", before, after)
	}
}

func TestSchemaCurrentErr_ReadErrorIsAnError(t *testing.T) {
	path := compactFixture(t)
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	if current, err := d.schemaCurrentErr(); err != nil || !current {
		t.Fatalf("open handle: got (%v, %v), want (true, nil)", current, err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if current, err := d.schemaCurrentErr(); err == nil || current {
		t.Fatalf("closed handle: got (%v, %v), want (false, error)", current, err)
	}
	if d.SchemaCurrent() {
		t.Fatal("SchemaCurrent = true on a closed handle")
	}
}

func TestSchemaCurrentErr_NoVersionTableIsPendingNotError(t *testing.T) {
	path := compactFixture(t)
	compactExec(t, path, `DROP TABLE goose_db_version`)
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	if current, err := d.schemaCurrentErr(); err != nil || current {
		t.Fatalf("got (%v, %v), want (false, nil)", current, err)
	}
}

// copyDBFile copies the database file and any -wal beside it to a new temp
// dir and returns the copy's path.
func copyDBFile(t *testing.T, path string) string {
	t.Helper()
	dst := filepath.Join(t.TempDir(), filepath.Base(path))
	for _, suffix := range []string{"", "-wal"} {
		b, err := os.ReadFile(path + suffix)
		if suffix != "" && os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dst+suffix, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dst
}

func TestCompact_InterruptLeavesDBIntact(t *testing.T) {
	path := sparseFixture(t, 8000)
	countBefore, sumBefore := messagesDigest(t, path)

	// The cancel must land while the VACUUM runs, not after it commits: time
	// an uninterrupted compaction of a copy and cancel within a tenth of it.
	measured, err := Compact(context.Background(), copyDBFile(t, path), CompactOptions{Version: "1.0.0"})
	if err != nil || !measured.Compacted {
		t.Fatalf("measuring run: got (%+v, %v), want compacted", measured, err)
	}
	delay := min(20*time.Millisecond, time.Duration(measured.DurationMS)*time.Millisecond/10)
	if delay < time.Millisecond {
		t.Fatalf("the fixture compacts in %d ms, too fast to interrupt reliably; enlarge its live data", measured.DurationMS)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	prev := compactVacuumHook
	compactVacuumHook = func() {
		go func() {
			time.Sleep(delay)
			cancel()
		}()
	}
	t.Cleanup(func() { compactVacuumHook = prev })

	res, err := Compact(ctx, path, CompactOptions{Version: "1.0.0"})
	if err != nil || res.Skipped != "interrupted" || res.Compacted {
		t.Fatalf("got (%+v, %v), want skipped interrupted, nil", res, err)
	}
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open after the interrupt: %v", err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	countAfter, sumAfter := messagesDigest(t, path)
	if countAfter != countBefore || sumAfter != sumBefore {
		t.Fatalf("messages changed: %d rows → %d, checksum equal = %v", countBefore, countAfter, sumAfter == sumBefore)
	}
	keys := maintenanceKeys(t, path)
	for _, k := range []string{maintLastCompactedVersion, maintCompactedAt, maintCompactFailures, maintCompactFailuresVersion} {
		if v, ok := keys[k]; ok {
			t.Fatalf("%s = %q written on an interrupt", k, v)
		}
	}
}

func TestCompact_FailureCounter(t *testing.T) {
	path := compactFixture(t)
	prev := compactVacuumSQL
	compactVacuumSQL = "VACUUM no_such_schema"
	t.Cleanup(func() { compactVacuumSQL = prev })

	for i, wantGaveUp := range []bool{false, false, true} {
		res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
		if err == nil || !strings.Contains(err.Error(), "no_such_schema") {
			t.Fatalf("call %d: err = %v, want the VACUUM error", i+1, err)
		}
		if res.Compacted || res.Failures != i+1 || res.GaveUp != wantGaveUp || res.Error == "" {
			t.Fatalf("call %d: got %+v, want failures=%d gave_up=%v with the error", i+1, res, i+1, wantGaveUp)
		}
	}
	if c := checkCompaction(t, path, "1.0.0"); c.Due || c.Reason != "gave_up" {
		t.Fatalf("after 3 failures: got due=%v reason=%q, want gave_up", c.Due, c.Reason)
	}

	res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.1"})
	if err == nil || res.Failures != 1 || res.GaveUp {
		t.Fatalf("new version: got (%+v, %v), want failures=1", res, err)
	}

	compactVacuumSQL = prev
	if res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.1"}); err != nil || !res.Compacted {
		t.Fatalf("success: got (%+v, %v)", res, err)
	}
	keys := maintenanceKeys(t, path)
	for _, k := range []string{maintCompactFailures, maintCompactFailuresVersion} {
		if v, ok := keys[k]; ok {
			t.Fatalf("%s = %q left after a success", k, v)
		}
	}
}

// A failure after a VACUUM that succeeded — here recording it — is a
// failure like the VACUUM's own: Error filled, counted against the cap.
func TestCompact_RecordFailureCounts(t *testing.T) {
	path := compactFixture(t)
	prev := compactRecord
	compactRecord = func(*DB) error { return errors.New("record failed") }
	t.Cleanup(func() { compactRecord = prev })

	for i, wantGaveUp := range []bool{false, false, true} {
		res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
		if err == nil || !strings.Contains(err.Error(), "record failed") {
			t.Fatalf("call %d: err = %v, want the record error", i+1, err)
		}
		if res.Compacted || res.Error != "record failed" || res.Failures != i+1 || res.GaveUp != wantGaveUp {
			t.Fatalf("call %d: got %+v, want failures=%d gave_up=%v with the error", i+1, res, i+1, wantGaveUp)
		}
	}
	if c := checkCompaction(t, path, "1.0.0"); c.Due || c.Reason != "gave_up" {
		t.Fatalf("after 3 failures: got due=%v reason=%q, want gave_up", c.Due, c.Reason)
	}
}

// A reader holding an open read transaction (an MCP server, a hook) does
// not make the compaction fail or hang: VACUUM commits beside it and the
// final checkpoint, which cannot pass the reader's snapshot, reports busy
// after the busy timeout instead of failing.
func TestCompact_ConcurrentReaderDoesNotFail(t *testing.T) {
	path := sparseFixture(t, 500)
	prevBusy := compactBusy
	compactBusy = 2 * time.Second
	t.Cleanup(func() { compactBusy = prevBusy })

	reader, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer reader.Close()
	tx, err := reader.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatalf("BEGIN: %v", err)
	}
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n); err != nil {
		t.Fatalf("SELECT: %v", err)
	}

	start := time.Now()
	res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
	elapsed := time.Since(start)
	if err != nil || !res.Compacted {
		t.Fatalf("got (%+v, %v), want compacted", res, err)
	}
	if elapsed > compactBusy+5*time.Second {
		t.Fatalf("Compact took %v beside a reader, want within the busy timeout", elapsed)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatal(err)
	}
	if after, _ := messagesDigest(t, path); after != n {
		t.Fatalf("rows %d → %d", n, after)
	}
}

func TestCompact_PathWithSpacesAndUnicode(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "my space é")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "watchtower.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	stubFreeDisk(t, 1<<50)
	fillSparse(t, path, 100)

	res, err := Compact(context.Background(), path, CompactOptions{Version: "1.0.0"})
	if err != nil || !res.Compacted {
		t.Fatalf("got (%+v, %v), want compacted", res, err)
	}
	if c := checkCompaction(t, path, "1.0.0"); c.Due || c.DBBytes != res.BytesAfter {
		t.Fatalf("check after compacting: %+v (bytes_after %d)", c, res.BytesAfter)
	}
}
