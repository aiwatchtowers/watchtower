package cmd

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gopkg.in/yaml.v3"

	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/diagnostics"
	"watchtower/internal/logcanary"
	"watchtower/internal/providers"
	"watchtower/internal/sqlcipher"
)

// diagInstall is a fake install under a temp HOME: a config naming one
// workspace, the workspace folder with its logs and a migrated database.
type diagInstall struct {
	home, cfgPath, root, ws, dbPath string
}

const diagWorkspace = "acme"

// newDiagInstall seeds HOME, the config (schema_format below current, no
// features.migrated marker) and a migrated, closed database.
func newDiagInstall(t *testing.T) diagInstall {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WATCHTOWER_AI_PROVIDER", "")
	in := diagInstall{home: home, cfgPath: filepath.Join(home, ".config", "watchtower", "config.yaml")}
	in.root = filepath.Join(home, ".local", "share", "watchtower")
	in.ws = filepath.Join(in.root, diagWorkspace)
	in.dbPath = filepath.Join(in.ws, "watchtower.db")
	diagWrite(t, in.cfgPath, "active_workspace: "+diagWorkspace+"\ndb:\n  schema_format: 0\n")
	diagWrite(t, filepath.Join(in.ws, "watchtower.log"), "2026/11/01 10:00:00 sync started\n")
	diagWrite(t, filepath.Join(in.ws, "daemon.log"), "")
	d, err := db.Open(in.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	return in
}

func diagWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// diagSeams pins the host-dependent inputs (build, sysctl) and restores
// every diagnostics seam and flag after the test.
func diagSeams(t *testing.T) {
	t.Helper()
	oldVersion, oldCommit, oldFlavor := Version, Commit, BuildFlavor
	oldBudgets, oldOpener, oldSysctl, oldPeek := diagnosticsBudgets, diagnosticsOpener, diagnosticsSysctl, diagnosticsPeek
	oldResolve, oldReadDB := diagnosticsResolve, diagnosticsReadDB
	oldConfig, oldWorkspace := flagConfig, flagWorkspace
	t.Cleanup(func() {
		Version, Commit, BuildFlavor = oldVersion, oldCommit, oldFlavor
		diagnosticsBudgets, diagnosticsOpener, diagnosticsSysctl, diagnosticsPeek = oldBudgets, oldOpener, oldSysctl, oldPeek
		diagnosticsResolve, diagnosticsReadDB = oldResolve, oldReadDB
		flagConfig, flagWorkspace = oldConfig, oldWorkspace
		diagnosticsFlagJSON, diagnosticsFlagAppVersion, diagnosticsFlagIPhone = false, "", ""
	})
	Version, Commit, BuildFlavor = "0.0.0-test", "abc1234", ""
	diagnosticsSysctl = func(name string) (string, error) {
		if name == "kern.osproductversion" {
			return "15.5", nil
		}
		return "Apple M3 Max", nil
	}
}

// runDiag runs `watchtower <args>` through the real Execute and returns
// stdout and the exit code.
func runDiag(t *testing.T, args ...string) (string, int) {
	t.Helper()
	var out bytes.Buffer
	oldArgs := os.Args
	t.Cleanup(func() {
		os.Args = oldArgs
		rootCmd.SetArgs(nil)
		rootCmd.SetOut(nil)
	})
	os.Args = append([]string{"watchtower"}, args...)
	rootCmd.SetArgs(args)
	rootCmd.SetOut(&out)
	code := Execute()
	return out.String(), code
}

// diagArgs is `diagnostics --config <cfg> --workspace <ws>` plus extra.
func diagArgs(cfg, ws string, extra ...string) []string {
	return append([]string{"diagnostics", "--config", cfg, "--workspace", ws}, extra...)
}

func lineWith(t *testing.T, text, prefix string) string {
	t.Helper()
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, prefix) {
			return l
		}
	}
	t.Fatalf("no line %q in:\n%s", prefix, text)
	return ""
}

func lastJSON(t *testing.T, out string) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var obj map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &obj); err != nil {
		t.Fatalf("last line is not JSON: %v\n%s", err, out)
	}
	return obj
}

func TestDiagnostics_FullReportLineOrder(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	d, err := db.Open(in.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{
		`INSERT INTO slack_accounts (status) VALUES ('ok'), ('revoked')`,
		`INSERT INTO pipeline_runs (pipeline, status, error_msg, finished_at) VALUES ('digests', 'error', 'status 429', '2026-11-01T09:00:00Z')`,
	} {
		if _, err := d.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	diagWrite(t, filepath.Join(in.ws, "last_sync.json"),
		`{"finished_at":"2026-11-01T09:30:00Z","error":"connection refused"}`)

	out, code := runDiag(t, diagArgs(in.cfgPath, "", "--app-version", "1.2.3", "--iphone", "on")...)
	if code != 0 {
		t.Fatalf("exit %d\n%s", code, out)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	want := []string{
		"Watchtower 0.0.0-test (commit abc1234, flavor: default) · app 1.2.3",
		"macOS 15.5 · Apple M3",
		"Config: ok",
		"AI: Claude Code (default, not chosen)",
		"Features on: ",
		"Sources: Slack 2 (1 needs sign-in) · Quick Connections 0 · iPhone companion on",
		"Daemon: stopped · last cycle ",
		"Recent errors (last 20):",
		"  2026-11-01 09:00Z  digests  rate_limit",
		"  2026-11-01 09:30Z  sync  network",
		"Crash: none in the logs",
		"Logs: watchtower.log ",
		"Database: schema ",
	}
	if len(lines) != len(want) {
		t.Fatalf("got %d lines, want %d:\n%s", len(lines), len(want), out)
	}
	for i, w := range want {
		if !strings.HasPrefix(lines[i], w) {
			t.Errorf("line %d = %q, want prefix %q", i, lines[i], w)
		}
	}
	if !strings.HasSuffix(lines[12], " · managed by organization: no") {
		t.Errorf("database line %q", lines[12])
	}
}

func TestDiagnostics_JSON(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	d, err := db.Open(in.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO email_accounts (provider, status) VALUES ('outlook', 'ok')`); err != nil {
		t.Fatal(err)
	}
	_ = d.Close()
	out, code := runDiag(t, diagArgs(in.cfgPath, "", "--json", "--iphone", "on")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	obj := lastJSON(t, out)
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if want := []string{"chip", "flavor", "macos", "partial", "provider", "sources", "text", "version"}; !slices.Equal(keys, want) {
		t.Errorf("keys %v", keys)
	}
	if obj["version"] != "0.0.0-test" || obj["macos"] != "macOS 15.5" || obj["chip"] != "Apple M3" ||
		obj["provider"] != "Claude Code" || obj["flavor"] != "default" || obj["partial"] != false {
		t.Errorf("values %v", obj)
	}
	if got := fmt.Sprint(obj["sources"]); got != "[Email over IMAP iPhone companion]" {
		t.Errorf("sources %s", got)
	}
}

// fileState is the bytes and mtime of a file, or "absent".
func fileState(t *testing.T, path string) string {
	t.Helper()
	st, err := os.Stat(path)
	if os.IsNotExist(err) {
		return "absent"
	}
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	return fmt.Sprintf("%d %s %d", len(b), hex.EncodeToString(sum[:]), st.ModTime().UnixNano())
}

func fileHash(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	return fmt.Sprintf("%d %s", len(b), hex.EncodeToString(sum[:]))
}

func dirNames(t *testing.T, dir string) []string {
	t.Helper()
	var names []string
	err := filepath.WalkDir(dir, func(p string, _ os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		names = append(names, strings.TrimPrefix(p, dir))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return names
}

// tableHashes copies the database files aside (so the read cannot touch
// them) and hashes every table's rows plus the goose version.
func tableHashes(t *testing.T, dbPath string) map[string]string {
	t.Helper()
	dir := t.TempDir()
	cp := filepath.Join(dir, "copy.db")
	for _, suffix := range []string{"", "-wal", "-shm"} {
		b, err := os.ReadFile(dbPath + suffix)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		diagWrite(t, cp+suffix, string(b))
	}
	ctx := context.Background()
	d, err := db.OpenExistingContext(ctx, cp, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = d.Close() }()
	out := map[string]string{}
	for _, tbl := range queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name`) {
		all := queryStrings(t, d, fmt.Sprintf(`SELECT * FROM %q`, tbl))
		sort.Strings(all)
		sum := sha256.Sum256([]byte(strings.Join(all, "\n")))
		out[tbl] = hex.EncodeToString(sum[:])
	}
	return out
}

// queryStrings returns each row of q printed as one string.
func queryStrings(t *testing.T, d *db.DB, q string) []string {
	t.Helper()
	rows, err := d.QueryContext(context.Background(), q)
	if err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	defer func() { _ = rows.Close() }()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	var all []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		all = append(all, fmt.Sprint(vals...))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return all
}

// seedWriterState leaves the database with a pending migration (its newest
// goose row deleted) and committed frames in the WAL from an open writer,
// which the caller closes (clean stop) or keeps open (writer running).
func seedWriterState(t *testing.T, dbPath string) *db.DB {
	t.Helper()
	d, err := db.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{
		`PRAGMA wal_autocheckpoint = 0`,
		`DELETE FROM goose_db_version WHERE id = (SELECT max(id) FROM goose_db_version)`,
		`INSERT INTO slack_accounts (status) VALUES ('ok')`,
		`INSERT INTO pipeline_runs (pipeline, status, error_msg) VALUES ('digests', 'error', 'boom')`,
	} {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	return d
}

// leftOverWAL makes in.dbPath a crashed writer's files: the main file, -wal
// and -shm copied while the writer still had frames in its WAL.
func leftOverWAL(t *testing.T, in diagInstall) {
	t.Helper()
	src := filepath.Join(t.TempDir(), "src.db")
	d := seedWriterStateAt(t, in.dbPath, src)
	defer func() { _ = d.Close() }()
	for _, suffix := range []string{"", "-wal", "-shm"} {
		b, err := os.ReadFile(src + suffix)
		if err != nil {
			t.Fatal(err)
		}
		diagWrite(t, in.dbPath+suffix, string(b))
	}
	if st, err := os.Stat(in.dbPath + "-wal"); err != nil || st.Size() == 0 {
		t.Fatalf("no WAL frames to leave over: %v", err)
	}
}

// seedWriterStateAt copies the migrated database to src and seeds it there.
func seedWriterStateAt(t *testing.T, from, src string) *db.DB {
	t.Helper()
	b, err := os.ReadFile(from)
	if err != nil {
		t.Fatal(err)
	}
	diagWrite(t, src, string(b))
	return seedWriterState(t, src)
}

func TestDiagnostics_WritesNothing(t *testing.T) {
	for _, situation := range []string{"writer_running", "stopped_clean", "left_over_wal"} {
		t.Run(situation, func(t *testing.T) {
			in := newDiagInstall(t)
			diagSeams(t)
			tmp := t.TempDir()
			t.Setenv("TMPDIR", tmp)
			oldSweep := startTempSweep
			startTempSweep = sweepStaleTemp // synchronous: the skip is observable
			t.Cleanup(func() { startTempSweep = oldSweep })

			switch situation {
			case "writer_running":
				d := seedWriterState(t, in.dbPath)
				t.Cleanup(func() { _ = d.Close() })
			case "stopped_clean":
				if err := seedWriterState(t, in.dbPath).Close(); err != nil {
					t.Fatal(err)
				}
			case "left_over_wal":
				leftOverWAL(t, in)
			}
			stalePID := filepath.Join(in.ws, "daemon.pid")
			diagWrite(t, stalePID, "999999\n")
			diagWrite(t, filepath.Join(in.ws, "last_sync.json"), `{"finished_at":"2026-11-01T09:30:00Z"}`)
			stale := filepath.Join(tmp, "wt-chat-prompt-stale")
			diagWrite(t, stale, "prompt")
			old := time.Now().Add(-20 * time.Minute)
			if err := os.Chtimes(stale, old, old); err != nil {
				t.Fatal(err)
			}

			watched := []string{in.cfgPath, stalePID, filepath.Join(in.ws, "last_sync.json"),
				filepath.Join(in.ws, "watchtower.log"), filepath.Join(in.ws, "daemon.log"), stale}
			before := map[string]string{}
			for _, p := range watched {
				before[p] = fileState(t, p)
			}
			mainBefore := fileHash(t, in.dbPath)
			walBefore := ""
			if situation == "left_over_wal" {
				walBefore = fileHash(t, in.dbPath+"-wal")
			}
			listBefore := dirNames(t, in.home)
			rowsBefore := tableHashes(t, in.dbPath)

			out, code := runDiag(t, diagArgs(in.cfgPath, "", "--json")...)
			if code != 0 {
				t.Fatalf("exit %d\n%s", code, out)
			}
			for _, p := range watched {
				if got := fileState(t, p); got != before[p] {
					t.Errorf("%s changed: %s → %s", filepath.Base(p), before[p], got)
				}
			}
			if got := fileHash(t, in.dbPath); got != mainBefore {
				t.Errorf("main database file changed: %s → %s", mainBefore, got)
			}
			if walBefore != "" {
				if got := fileHash(t, in.dbPath+"-wal"); got != walBefore {
					t.Errorf("-wal changed: %s → %s", walBefore, got)
				}
			}
			isSide := func(n string) bool { return strings.HasSuffix(n, "-wal") || strings.HasSuffix(n, "-shm") }
			after := slices.DeleteFunc(dirNames(t, in.home), isSide)
			if want := slices.DeleteFunc(listBefore, isSide); !slices.Equal(after, want) {
				t.Errorf("data directory entries changed:\nbefore %v\nafter  %v", want, after)
			}
			if got := tableHashes(t, in.dbPath); !mapsEqual(got, rowsBefore) {
				t.Error("table rows or goose version changed")
			}
		})
	}

	// Control: the same seam does sweep for any other command, so the skip
	// above is what kept the temp file.
	t.Run("control_version_sweeps", func(t *testing.T) {
		diagSeams(t)
		tmp := t.TempDir()
		t.Setenv("TMPDIR", tmp)
		oldSweep := startTempSweep
		startTempSweep = sweepStaleTemp
		t.Cleanup(func() { startTempSweep = oldSweep })
		stale := filepath.Join(tmp, "wt-chat-prompt-stale")
		diagWrite(t, stale, "prompt")
		old := time.Now().Add(-20 * time.Minute)
		if err := os.Chtimes(stale, old, old); err != nil {
			t.Fatal(err)
		}
		if _, code := runDiag(t, "version"); code != 0 {
			t.Fatalf("exit %d", code)
		}
		if _, err := os.Stat(stale); !os.IsNotExist(err) {
			t.Errorf("version did not sweep the stale temp file: %v", err)
		}
	})
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func TestDiagnostics_LeftOverWALMainFileUntouched(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	leftOverWAL(t, in)
	mainBefore, walBefore := fileHash(t, in.dbPath), fileHash(t, in.dbPath+"-wal")
	out, code := runDiag(t, diagArgs(in.cfgPath, "")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	// The WAL's frames are read: the account committed there is counted.
	if l := lineWith(t, out, diagnostics.LabelSources); !strings.HasPrefix(l, "Sources: Slack 1 ok") {
		t.Errorf("sources %q", l)
	}
	if got := fileHash(t, in.dbPath); got != mainBefore {
		t.Errorf("main file changed: %s → %s", mainBefore, got)
	}
	if got := fileHash(t, in.dbPath+"-wal"); got != walBefore {
		t.Errorf("-wal changed: %s → %s", walBefore, got)
	}
}

// holdExclusive takes an exclusive lock on the database from another
// connection, released in cleanup.
func holdExclusive(t *testing.T, path string) {
	t.Helper()
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	conn, err := d.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{`PRAGMA locking_mode = EXCLUSIVE`, `BEGIN EXCLUSIVE`, `INSERT INTO slack_accounts (status) VALUES ('ok')`} {
		if _, err := conn.ExecContext(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	t.Cleanup(func() {
		_, _ = conn.ExecContext(ctx, `ROLLBACK`)
		_ = conn.Close()
		_ = d.Close()
	})
}

func assertBusyLines(t *testing.T, out string) {
	t.Helper()
	busy := diagnostics.UnknownDatabaseBusy
	if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+busy+" · iPhone companion off" {
		t.Errorf("sources %q", l)
	}
	if !strings.Contains(out, "Recent errors (last 20):\n  pipeline runs "+busy+"\n  2026-11-01 09:30Z  sync  timeout") {
		t.Errorf("recent errors:\n%s", out)
	}
	if l := lineWith(t, out, diagnostics.LabelDatabase); !regexp.MustCompile(
		`^Database: schema unknown \(database busy\) · \d+(\.\d)? (KB|MB) · managed by organization: no$`).MatchString(l) {
		t.Errorf("database %q", l)
	}
	for _, label := range []string{"Config: ok", "AI: ", "Features on: ", "Daemon: stopped", "Crash: ", "Logs: "} {
		lineWith(t, out, label)
	}
}

func TestDiagnostics_BusyDatabaseFinishesInTime(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	diagWrite(t, filepath.Join(in.ws, "last_sync.json"), `{"finished_at":"2026-11-01T09:30:00Z","error":"deadline exceeded"}`)
	holdExclusive(t, in.dbPath)
	start := time.Now()
	out, code := runDiag(t, diagArgs(in.cfgPath, "", "--iphone", "off")...)
	if el := time.Since(start); el > 7500*time.Millisecond {
		t.Errorf("took %v", el)
	}
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	assertBusyLines(t, out)
	if !strings.HasSuffix(strings.TrimSpace(out), "Partial report: database busy") {
		t.Errorf("last line:\n%s", out)
	}
	shortDBBudgets()
	jsonOut, _ := runDiag(t, diagArgs(in.cfgPath, "", "--json")...)
	if lastJSON(t, jsonOut)["partial"] != true {
		t.Error("partial is not true")
	}
}

// shortDBBudgets keeps the busy tests fast: the same rules, smaller numbers.
func shortDBBudgets() {
	diagnosticsBudgets.DB = 300 * time.Millisecond
	diagnosticsBudgets.DBFallback = 400 * time.Millisecond
	diagnosticsBudgets.Busy = 50 * time.Millisecond
}

func TestDiagnostics_BusyKeepsFileParts(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	shortDBBudgets()
	diagWrite(t, filepath.Join(in.ws, "last_sync.json"), `{"finished_at":"2026-11-01T09:30:00Z","error":"deadline exceeded"}`)
	holdExclusive(t, in.dbPath)
	out, code := runDiag(t, diagArgs(in.cfgPath, "", "--iphone", "off")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	assertBusyLines(t, out)
	// The holder's db.Open pointed the process's lock-metrics sink here; the
	// command's busy open still writes no dblock.jsonl line.
	if _, err := os.Stat(filepath.Join(in.ws, lockmetrics.FileName)); !os.IsNotExist(err) {
		t.Errorf("dblock.jsonl written: %v", err)
	}
}

func TestDiagnostics_NoDatabase(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	if err := os.Remove(in.dbPath); err != nil {
		t.Fatal(err)
	}
	out, code := runDiag(t, diagArgs(in.cfgPath, "")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	nodb := diagnostics.UnknownNoDatabase
	if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+nodb {
		t.Errorf("sources %q", l)
	}
	if !strings.Contains(out, "Recent errors (last 20):\n  pipeline runs "+nodb) {
		t.Errorf("recent errors:\n%s", out)
	}
	if l := lineWith(t, out, diagnostics.LabelDatabase); l != "Database: schema "+nodb+" · managed by organization: no" {
		t.Errorf("database %q", l)
	}
	if _, err := os.Stat(in.dbPath); !os.IsNotExist(err) {
		t.Errorf("the database was created: %v", err)
	}
}

// TestDiagnostics_NoHomeDir is the spec's no_home_dir case: HOME empty and
// no WATCHTOWER_CONFIG_PATH (--config ""), the full text equals the golden.
func TestDiagnostics_NoHomeDir(t *testing.T) {
	diagSeams(t)
	t.Setenv("HOME", "")
	t.Setenv("WATCHTOWER_CONFIG_PATH", "")
	out, code := runDiag(t, "diagnostics", "--config", "", "--workspace", "", "--app-version", "1.2.3", "--iphone", "on")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	golden := filepath.Join("testdata", "no_home_dir.golden")
	if *updateSessionReportGolden {
		diagWrite(t, golden, out)
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden (run with -update): %v", err)
	}
	if out != string(want) {
		t.Errorf("got:\n%s\nwant:\n%s", out, want)
	}
}

func TestDiagnostics_InputFailures(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, in diagInstall) (args []string)
		check func(t *testing.T, out string)
	}{
		{"config_is_directory", func(t *testing.T, in diagInstall) []string {
			dir := filepath.Join(in.home, "cfgdir")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			return diagArgs(dir, "")
		}, func(t *testing.T, out string) {
			if l := lineWith(t, out, diagnostics.LabelConfig); l != "Config: unreadable (other)" {
				t.Errorf("config %q", l)
			}
			if l := lineWith(t, out, diagnostics.LabelDaemon); l != "Daemon: "+diagnostics.UnknownNoConfig {
				t.Errorf("daemon %q", l)
			}
		}},
		{"workspace_not_chosen", func(t *testing.T, in diagInstall) []string {
			diagWrite(t, in.cfgPath, "digest:\n  enabled: true\n")
			d, err := db.Open(filepath.Join(in.root, "beta", "watchtower.db"))
			if err != nil {
				t.Fatal(err)
			}
			_ = d.Close()
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			if l := lineWith(t, out, diagnostics.LabelWorkspace); l != "Workspace: not chosen (2 found)" {
				t.Errorf("workspace %q", l)
			}
			if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+diagnostics.UnknownNoWorkspace {
				t.Errorf("sources %q", l)
			}
			if strings.Contains(out, diagWorkspace) || strings.Contains(out, "beta") {
				t.Error("a workspace name was printed")
			}
		}},
		{"db_not_a_database", func(t *testing.T, in diagInstall) []string {
			junk := make([]byte, 8192)
			_, _ = rand.Read(junk)
			diagWrite(t, in.dbPath, string(junk))
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			nadb := diagnostics.DatabaseUnreadableNotADB
			if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+nadb {
				t.Errorf("sources %q", l)
			}
			if l := lineWith(t, out, diagnostics.LabelDatabase); l != "Database: schema "+nadb+" · 8 KB · managed by organization: no" {
				t.Errorf("database %q", l)
			}
		}},
		{"db_no_ckpt_guard", func(t *testing.T, in diagInstall) []string {
			diagnosticsOpener = func(time.Duration) diagnostics.OpenFunc {
				return func(context.Context, string) (diagnostics.DBReader, error) {
					return nil, sqlcipher.ErrNoCheckpointGuard
				}
			}
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+diagnostics.DatabaseNoCkptGuard {
				t.Errorf("sources %q", l)
			}
		}},
		{"budget_db_before_open", func(t *testing.T, in diagInstall) []string {
			shortDBBudgets()
			diagnosticsOpener = func(time.Duration) diagnostics.OpenFunc {
				return func(ctx context.Context, _ string) (diagnostics.DBReader, error) {
					<-ctx.Done()
					return nil, ctx.Err()
				}
			}
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			busy := diagnostics.UnknownDatabaseBusy
			if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+busy {
				t.Errorf("sources %q", l)
			}
			if !strings.HasSuffix(strings.TrimSpace(out), "Partial report: database busy") {
				t.Errorf("no partial line:\n%s", out)
			}
		}},
		{"budget_logscan", func(t *testing.T, in diagInstall) []string {
			diagnosticsBudgets.LogScan = 0
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			if l := lineWith(t, out, diagnostics.LabelCrash); l != "Crash: none in the first 0 MB of the logs (scan stopped)" {
				t.Errorf("crash %q", l)
			}
			if !strings.HasSuffix(strings.TrimSpace(out), "Partial report: log scan stopped") {
				t.Errorf("no partial line:\n%s", out)
			}
		}},
		{"busy_and_logscan", func(t *testing.T, in diagInstall) []string {
			shortDBBudgets()
			diagnosticsBudgets.LogScan = 0
			holdExclusive(t, in.dbPath)
			return diagArgs(in.cfgPath, "")
		}, func(t *testing.T, out string) {
			if !strings.HasSuffix(strings.TrimSpace(out), "Partial report: database busy, log scan stopped") {
				t.Errorf("reasons:\n%s", out)
			}
		}},
		{"budget_hard_stop", func(t *testing.T, in diagInstall) []string {
			diagnosticsBudgets.HardStop = 50 * time.Millisecond
			release := make(chan struct{})
			t.Cleanup(func() { close(release) })
			diagnosticsOpener = func(time.Duration) diagnostics.OpenFunc {
				return func(context.Context, string) (diagnostics.DBReader, error) {
					<-release // an open that ignores its context
					return nil, context.Canceled
				}
			}
			return diagArgs(in.cfgPath, "", "--iphone", "on")
		}, func(t *testing.T, out string) {
			to := diagnostics.UnknownTimedOut
			if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+to+" · iPhone companion on" {
				t.Errorf("sources %q", l)
			}
			if l := lineWith(t, out, "Recent errors"); l != "Recent errors: "+to {
				t.Errorf("recent errors %q", l)
			}
			if l := lineWith(t, out, diagnostics.LabelDatabase); l != "Database: "+to+" · "+to+" · managed by organization: no" {
				t.Errorf("database %q", l)
			}
			lineWith(t, out, "Config: ok")
			if !strings.HasSuffix(strings.TrimSpace(out), "Partial report: timed out at 8 s") {
				t.Errorf("no partial line:\n%s", out)
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := newDiagInstall(t)
			diagSeams(t)
			args := c.setup(t, in)
			start := time.Now()
			out, code := runDiag(t, args...)
			if code != 0 {
				t.Fatalf("exit %d\n%s", code, out)
			}
			if el := time.Since(start); el > 7500*time.Millisecond {
				t.Errorf("took %v", el)
			}
			c.check(t, out)
		})
	}
}

// TestDIAG01_NoNamesOrText seeds canaries into every name and text the
// command reads around and checks no output carries one, a home path or an
// `<acct>:<id>` shape.
func TestDIAG01_NoNamesOrText(t *testing.T) {
	canary := logcanary.Text
	idShape := regexp.MustCompile(`\w+:[A-Z0-9]{6,}`)
	check := func(t *testing.T, out string) {
		t.Helper()
		if strings.Contains(out, logcanary.Marker) {
			t.Errorf("a canary was printed:\n%s", out)
		}
		if strings.Contains(out, "/Users/") || strings.Contains(out, os.TempDir()) {
			t.Errorf("a path was printed:\n%s", out)
		}
		if m := idShape.FindString(out); m != "" {
			t.Errorf("an id shape %q was printed:\n%s", m, out)
		}
	}
	seed := func(t *testing.T) diagInstall {
		in := newDiagInstall(t)
		diagSeams(t)
		BuildFlavor = canary("flavor")
		ws := canary("ws")
		newWS := filepath.Join(in.root, ws)
		if err := os.Rename(in.ws, newWS); err != nil {
			t.Fatal(err)
		}
		in.ws, in.dbPath = newWS, filepath.Join(newWS, "watchtower.db")
		diagWrite(t, in.cfgPath, "active_workspace: "+ws+"\n")
		d, err := db.Open(in.dbPath)
		if err != nil {
			t.Fatal(err)
		}
		q := func(s string, args ...any) {
			if _, err := d.Exec(s, args...); err != nil {
				t.Fatalf("%s: %v", s, err)
			}
		}
		q(`INSERT INTO slack_accounts (team_id, team_name, team_domain, label, current_user_id, status, error) VALUES (?, ?, ?, ?, ?, 'error', ?)`,
			"T0CANARY1", canary("team"), canary("domain"), canary("label"), "1:U0CANARY1", canary("err"))
		q(`INSERT INTO google_accounts (email, label, gmail_enabled, status, error) VALUES (?, ?, 1, ?, ?)`,
			canary("mail")+"@example.com", canary("glabel"), canary("status"), canary("gerr"))
		q(`INSERT INTO email_accounts (provider, email_address, host, label) VALUES ('imap', ?, ?, ?)`,
			canary("imap")+"@example.com", canary("host"), canary("ilabel"))
		q(`INSERT INTO channels (id, name, type) VALUES ('1:C0CANARY1', ?, 'public')`, canary("channel"))
		q(`INSERT INTO external_connections (name, enabled) VALUES (?, 1)`, canary("qc"))
		q(`INSERT INTO automations (slug, scope, path, name) VALUES (?, 'personal', ?, ?)`, canary("slug"), "/tmp/"+canary("path"), canary("auto"))
		q(`INSERT INTO pipeline_runs (pipeline, status, error_msg, finished_at) VALUES ('digests', 'error', ?, '2026-11-01T09:00:00Z')`,
			canary("errmsg"))
		_ = d.Close()
		diagWrite(t, filepath.Join(in.ws, "last_sync.json"),
			`{"finished_at":"2026-11-01T09:30:00Z","error":"`+canary("syncerr")+`"}`)
		diagWrite(t, filepath.Join(in.ws, "watchtower.log"),
			"2026/11/01 10:00:00 start\npanic: "+canary("panic")+"\n\ngoroutine 1 [running]:\nwatchtower/internal/sync.(*Syncer).run(...)\n")
		return in
	}
	for _, mode := range [][]string{nil, {"--json"}} {
		t.Run(fmt.Sprintf("normal%v", mode), func(t *testing.T) {
			in := seed(t)
			out, code := runDiag(t, diagArgs(in.cfgPath, canary("ws"), mode...)...)
			if code != 0 {
				t.Fatalf("exit %d", code)
			}
			check(t, out)
			lineWith(t, strings.ReplaceAll(out, `\n`, "\n"), "Crash: 1 in the logs")
		})
		t.Run(fmt.Sprintf("invalid_config%v", mode), func(t *testing.T) {
			in := seed(t)
			diagWrite(t, in.cfgPath, "active_workspace: "+canary("ws")+"\nai:\n  provider: "+canary("provider")+"\n")
			t.Setenv("WATCHTOWER_AI_PROVIDER", canary("envprovider"))
			out, code := runDiag(t, diagArgs(in.cfgPath, "", mode...)...)
			if code != 0 {
				t.Fatalf("exit %d", code)
			}
			check(t, out)
		})
		t.Run(fmt.Sprintf("flag_workspace_unknown%v", mode), func(t *testing.T) {
			in := seed(t)
			out, _ := runDiag(t, diagArgs(in.cfgPath, canary("other"), mode...)...)
			check(t, out)
		})
		t.Run(fmt.Sprintf("busy%v", mode), func(t *testing.T) {
			in := seed(t)
			shortDBBudgets()
			holdExclusive(t, in.dbPath)
			out, _ := runDiag(t, diagArgs(in.cfgPath, "", mode...)...)
			check(t, out)
		})
	}
}

// TestDiagnostics_FormOptions keeps the Go mappings and the GitHub issue
// form in step: every chip/provider the mapping can emit is a dropdown
// option, and the sources checkboxes and the form-mapped kinds match.
func TestDiagnostics_FormOptions(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", ".github", "ISSUE_TEMPLATE", "bug_report.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var form struct {
		Body []struct {
			ID         string `yaml:"id"`
			Attributes struct {
				Options []yaml.Node `yaml:"options"`
			} `yaml:"attributes"`
		} `yaml:"body"`
	}
	if err := yaml.Unmarshal(raw, &form); err != nil {
		t.Fatal(err)
	}
	options := map[string][]string{}
	for _, f := range form.Body {
		for _, n := range f.Attributes.Options {
			if n.Kind == yaml.ScalarNode {
				options[f.ID] = append(options[f.ID], n.Value)
				continue
			}
			var o struct {
				Label string `yaml:"label"`
			}
			if err := n.Decode(&o); err != nil {
				t.Fatal(err)
			}
			options[f.ID] = append(options[f.ID], o.Label)
		}
	}

	chips := []string{diagnostics.ChipOther}
	for n := 1; n <= 5; n++ {
		chips = append(chips, diagnostics.ChipApple(n))
	}
	for _, c := range chips {
		if !slices.Contains(options["chip"], c) {
			t.Errorf("chip %q is not a form option", c)
		}
	}
	provs := []string{diagnostics.ProviderNotSetUpOption}
	for _, id := range providers.IDs() {
		provs = append(provs, providers.ByID(id).ReportOption)
	}
	for _, p := range provs {
		if !slices.Contains(options["provider"], p) {
			t.Errorf("provider %q is not a form option", p)
		}
	}

	kinds := []string{diagnostics.IPhoneCompanion}
	var skipped []string
	for _, st := range diagnostics.SourceTables {
		if st.FormLabel == "" {
			skipped = append(skipped, st.Kind)
			continue
		}
		if !slices.Contains(kinds, st.FormLabel) {
			kinds = append(kinds, st.FormLabel)
		}
	}
	for _, k := range kinds {
		if !slices.Contains(options["sources"], k) {
			t.Errorf("kind %q is not a sources checkbox", k)
		}
	}
	for _, label := range options["sources"] {
		if !slices.Contains(kinds, label) {
			t.Errorf("checkbox %q has no kind", label)
		}
	}
	// The kinds with no checkbox, named on purpose.
	skipped = append(skipped, diagnostics.QuickConnections)
	if want := []string{diagnostics.KindCalDAV, diagnostics.QuickConnections}; !slices.Equal(skipped, want) {
		t.Errorf("kinds without a checkbox %v, want %v", skipped, want)
	}
}

// diagnostics installs no signal handler: the Desktop's 10 s timeout ends
// the child with SIGTERM's default action.
func TestDiagnostics_NoSignalHandler(t *testing.T) {
	src, err := os.ReadFile("diagnostics.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, banned := range []string{"signal.Notify", "os/signal"} {
		if bytes.Contains(src, []byte(banned)) {
			t.Errorf("diagnostics.go uses %s", banned)
		}
	}
}

// The hard stop covers the up-front work: a config/workspace resolution
// that hangs leaves its lines `unknown (timed out)`, the instant parts and
// the version and machine lines print, the JSON keeps its defaults.
func TestDiagnostics_HardStopCoversResolve(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	diagnosticsBudgets.HardStop = 50 * time.Millisecond
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	diagnosticsResolve = func(diagnostics.Env) diagnostics.Resolved {
		<-release
		// After the test: no workspace, so nothing more is read.
		return diagnostics.Resolved{ConfigLine: diagnostics.ConfigNone, WorkspaceReason: diagnostics.UnknownNoConfig}
	}
	out, code := runDiag(t, diagArgs(in.cfgPath, "", "--iphone", "on")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	to := diagnostics.UnknownTimedOut
	for _, want := range []string{
		"Watchtower 0.0.0-test (commit abc1234, flavor: default)",
		"macOS 15.5 · Apple M3",
		"Config: " + to,
		"Workspace: " + to,
		"AI: " + to,
		"Features on: " + to,
		"Sources: " + to + " · iPhone companion on",
		"Daemon: " + to,
		"Recent errors: " + to,
		"Crash: " + to,
		"Logs: " + to,
		"Database: " + to + " · " + to + " · managed by organization: no",
		"Partial report: timed out at 8 s",
	} {
		if !slices.Contains(strings.Split(strings.TrimSpace(out), "\n"), want) {
			t.Errorf("no line %q in:\n%s", want, out)
		}
	}
	jsonOut, _ := runDiag(t, diagArgs(in.cfgPath, "", "--json", "--iphone", "off")...)
	obj := lastJSON(t, jsonOut)
	if obj["provider"] != "" || obj["partial"] != true || fmt.Sprint(obj["sources"]) != "[]" {
		t.Errorf("json %v", obj)
	}
}

// Panics anywhere in the inputs are contained: exit 0, the report prints,
// the affected parts say `unknown (internal error)`.
func TestDiagnostics_PanicsContained(t *testing.T) {
	internal := diagnostics.UnknownInternal
	dbInternal := func(t *testing.T, out string) {
		t.Helper()
		if l := lineWith(t, out, diagnostics.LabelSources); l != "Sources: "+internal {
			t.Errorf("sources %q", l)
		}
		if !strings.Contains(out, "Recent errors (last 20):\n  pipeline runs "+internal) {
			t.Errorf("recent errors:\n%s", out)
		}
		if l := lineWith(t, out, diagnostics.LabelDatabase); !strings.HasPrefix(l, "Database: schema "+internal+" · ") {
			t.Errorf("database %q", l)
		}
		lineWith(t, out, "Config: ok")
	}
	cases := []struct {
		name  string
		setup func()
		check func(t *testing.T, out string)
	}{
		{"opener_panics", func() {
			diagnosticsOpener = func(time.Duration) diagnostics.OpenFunc {
				return func(context.Context, string) (diagnostics.DBReader, error) { panic("opener bug") }
			}
		}, dbInternal},
		{"read_db_panics", func() {
			diagnosticsReadDB = func(context.Context, diagnostics.Budgets, string, diagnostics.OpenFunc) diagnostics.DBParts {
				panic("reader bug")
			}
		}, dbInternal},
		{"resolve_panics", func() {
			diagnosticsResolve = func(diagnostics.Env) diagnostics.Resolved { panic("resolve bug") }
		}, func(t *testing.T, out string) {
			for _, want := range []string{"Config: " + internal, "AI: " + internal, "Features on: " + internal,
				"Sources: " + internal, "Daemon: " + internal, "Logs: " + internal, "Crash: " + internal} {
				lineWith(t, out, want)
			}
		}},
		{"sysctl_panics", func() {
			diagnosticsSysctl = func(string) (string, error) { panic("sysctl bug") }
		}, func(t *testing.T, out string) {
			if lines := strings.Split(out, "\n"); lines[1] != internal {
				t.Errorf("machine line %q", lines[1])
			}
			lineWith(t, out, "Config: ok")
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := newDiagInstall(t)
			diagSeams(t)
			c.setup()
			out, code := runDiag(t, diagArgs(in.cfgPath, "")...)
			if code != 0 {
				t.Fatalf("exit %d\n%s", code, out)
			}
			c.check(t, out)
			jsonOut, code := runDiag(t, diagArgs(in.cfgPath, "", "--json")...)
			if code != 0 {
				t.Fatalf("json exit %d", code)
			}
			if c.name == "sysctl_panics" && lastJSON(t, jsonOut)["chip"] != diagnostics.ChipOther {
				t.Errorf("chip %v", lastJSON(t, jsonOut)["chip"])
			}
		})
	}
}

// The opener gets Budgets.Busy as its per-statement busy timeout.
func TestDiagnostics_BusyBudgetReachesOpener(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	diagnosticsBudgets.Busy = 123 * time.Millisecond
	var got atomic.Int64
	diagnosticsOpener = func(busy time.Duration) diagnostics.OpenFunc {
		got.Store(int64(busy))
		return diagnostics.Opener(busy)
	}
	if _, code := runDiag(t, diagArgs(in.cfgPath, "")...); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if time.Duration(got.Load()) != diagnosticsBudgets.Busy {
		t.Errorf("opener got busy %v, want %v", time.Duration(got.Load()), diagnosticsBudgets.Busy)
	}
}

// A healthy install with no failed run and no failed sync.
func TestDiagnostics_HealthyNoErrors(t *testing.T) {
	in := newDiagInstall(t)
	diagSeams(t)
	diagWrite(t, filepath.Join(in.ws, "last_sync.json"), `{"finished_at":"2026-11-01T09:30:00Z"}`)
	out, code := runDiag(t, diagArgs(in.cfgPath, "")...)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	lineWith(t, out, diagnostics.RecentErrorsNone)
	if strings.Contains(out, diagnostics.RecentErrorsTitle) || strings.Contains(out, "Partial report") {
		t.Errorf("unexpected:\n%s", out)
	}
}
