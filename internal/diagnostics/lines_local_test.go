package diagnostics

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/daemon"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

func TestDiagnostics_VersionLine(t *testing.T) {
	cases := []struct {
		name       string
		b          Build
		want, flav string
	}{
		{"empty flavor", Build{Version: "1.2.3", Commit: "abc1234"}, "Watchtower 1.2.3 (commit abc1234, flavor: default)", FlavorDefault},
		{"dev flavor", Build{Version: "1.2.3", Commit: "abc1234", Flavor: "dev"}, "Watchtower 1.2.3 (commit abc1234, flavor: default)", FlavorDefault},
		{"corp flavor", Build{Version: "1.2.3", Commit: "abc1234", Flavor: "acme-corp", AppVersion: "1.2.4"},
			"Watchtower 1.2.3 (commit abc1234, flavor: corp) · app 1.2.4", FlavorCorp},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, flav := VersionLine(c.b)
			if got != c.want || flav != c.flav {
				t.Errorf("VersionLine = %q, %q; want %q, %q", got, flav, c.want, c.flav)
			}
			if strings.Contains(got, "acme") {
				t.Errorf("raw flavor printed: %q", got)
			}
		})
	}
}

// TestFlavorCases pins Flavor to the case table shared with the Swift
// HubIdentity.flavor(buildFlavor:) (ReportProblemFlavorCasesTests).
func TestFlavorCases(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "report_problem_flavor_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		BuildFlavor string `json:"build_flavor"`
		Flavor      string `json:"flavor"`
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 5 {
		t.Fatalf("only %d flavor cases", len(cases))
	}
	for _, c := range cases {
		if got := Flavor(c.BuildFlavor); got != c.Flavor {
			t.Errorf("Flavor(%q) = %q, want %q", c.BuildFlavor, got, c.Flavor)
		}
	}
}

func TestDiagnostics_SysctlFailure(t *testing.T) {
	fake := func(vals map[string]string) func(string) (string, error) {
		return func(k string) (string, error) {
			v, ok := vals[k]
			if !ok {
				return "", errors.New("sysctl failed")
			}
			return v, nil
		}
	}
	cases := []struct {
		name                    string
		vals                    map[string]string
		wantText, wantOS, wantC string
	}{
		{"both fail", nil, "macOS unknown · Other", MacOSUnknown, ChipOther},
		{"m3 max", map[string]string{"kern.osproductversion": "15.5", "machdep.cpu.brand_string": "Apple M3 Max"},
			"macOS 15.5 · Apple M3", "macOS 15.5", "Apple M3"},
		{"m1", map[string]string{"kern.osproductversion": "14.7.1", "machdep.cpu.brand_string": "Apple M1"},
			"macOS 14.7.1 · Apple M1", "macOS 14.7.1", "Apple M1"},
		{"m5 ultra", map[string]string{"kern.osproductversion": "26.1", "machdep.cpu.brand_string": "Apple M5 Ultra"},
			"macOS 26.1 · Apple M5", "macOS 26.1", "Apple M5"},
		{"m7 is other", map[string]string{"kern.osproductversion": "15.5", "machdep.cpu.brand_string": "Apple M7"},
			"macOS 15.5 · Other", "macOS 15.5", ChipOther},
		{"intel is other", map[string]string{"kern.osproductversion": "15.5", "machdep.cpu.brand_string": "Intel(R) Core(TM) i9"},
			"macOS 15.5 · Other", "macOS 15.5", ChipOther},
		{"odd version unknown", map[string]string{"kern.osproductversion": "15.5 beta x", "machdep.cpu.brand_string": "Apple M2 Pro"},
			"macOS unknown · Apple M2", MacOSUnknown, "Apple M2"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			text, macos, chip := MachineLine(fake(c.vals))
			if text != c.wantText || macos != c.wantOS || chip != c.wantC {
				t.Errorf("MachineLine = %q, %q, %q; want %q, %q, %q", text, macos, chip, c.wantText, c.wantOS, c.wantC)
			}
		})
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func lastSyncJSON(t *testing.T, finished time.Time, errText string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"started_at": finished.Add(-time.Minute), "finished_at": finished, "error": errText})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestDiagnostics_DaemonLine(t *testing.T) {
	now := time.Date(2026, 11, 4, 10, 0, 0, 0, time.UTC)
	fakePeek := func(st daemon.PeekState) func(string) (int, daemon.PeekState, error) {
		return func(string) (int, daemon.PeekState, error) { return 42, st, nil }
	}
	cases := []struct {
		name     string
		pid      *string                                     // pid file body; nil = no file
		peek     func(string) (int, daemon.PeekState, error) // nil = daemon.PeekProcess
		lastSync *string
		progress *string
		want     string
	}{
		{name: "no_pid_file", want: "stopped · no cycle yet"},
		{name: "stale_dead_pid", peek: fakePeek(daemon.PeekGone), want: "stopped (stale pid file) · no cycle yet"},
		{name: "reused_pid", peek: fakePeek(daemon.PeekReused), want: "stopped (stale pid file) · no cycle yet"},
		{name: "old_untagged", peek: fakePeek(daemon.PeekGone), want: "stopped (stale pid file) · no cycle yet"},
		{name: "running_confirmed", peek: fakePeek(daemon.PeekRunning),
			lastSync: ptr(lastSyncJSON(t, now.Add(-4*time.Minute), "")), want: "running · last cycle 4 min ago, done"},
		{name: "identity_unknown", peek: fakePeek(daemon.PeekUnknown), want: "unknown (process not confirmed) · no cycle yet"},
		{name: "empty_file", pid: ptr(""), want: "unknown (pid file corrupt) · no cycle yet"},
		{name: "garbage_file", pid: ptr("garbage"), want: "unknown (pid file corrupt) · no cycle yet"},
		{name: "permission_denied", pid: ptr("123 1700000000 v2"), want: "unknown (pid file unreadable: permission) · no cycle yet"},
		{name: "pid_file_is_directory", want: "unknown (pid file unreadable: other) · no cycle yet"},
		{name: "last_sync_missing", want: "stopped · no cycle yet"},
		{name: "last_sync_corrupt", lastSync: ptr("{not json"), want: "stopped · last cycle unknown"},
		{name: "last_sync_no_finish_time", lastSync: ptr(`{"error":""}`), want: "stopped · last cycle unknown"},
		{name: "last_sync_error", lastSync: ptr(lastSyncJSON(t, now.Add(-3*time.Hour), "invalid_auth for team acme")),
			want: "stopped · last cycle 3 h ago, error"},
		{name: "cycle_running", peek: fakePeek(daemon.PeekRunning),
			lastSync: ptr(lastSyncJSON(t, now.Add(-2*24*time.Hour), "")),
			progress: ptr(`{"active":true,"started_at":"2026-11-04T09:58:00Z","updated_at":"2026-11-04T09:59:30Z"}`),
			want:     "running · last cycle 2 min ago, running"},
		{name: "progress_stale_ignored", peek: fakePeek(daemon.PeekRunning),
			lastSync: ptr(lastSyncJSON(t, now.Add(-30*time.Second), "")),
			progress: ptr(`{"active":true,"started_at":"2026-11-04T08:00:00Z","updated_at":"2026-11-04T08:01:00Z"}`),
			want:     "running · last cycle under 1 min ago, done"},
		{name: "progress_ignored_when_stopped",
			lastSync: ptr(lastSyncJSON(t, now.Add(-30*time.Second), "")),
			progress: ptr(`{"active":true,"started_at":"2026-11-04T09:58:00Z","updated_at":"2026-11-04T09:59:30Z"}`),
			want:     "stopped · last cycle under 1 min ago, done"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			pidPath := filepath.Join(dir, "daemon.pid")
			lastSync := filepath.Join(dir, "last_sync.json")
			if c.name == "pid_file_is_directory" {
				if err := os.Mkdir(pidPath, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			if c.pid != nil {
				writeFile(t, pidPath, *c.pid)
				if c.name == "permission_denied" {
					if err := os.Chmod(pidPath, 0o000); err != nil {
						t.Fatal(err)
					}
				}
			}
			if c.lastSync != nil {
				writeFile(t, lastSync, *c.lastSync)
			}
			if c.progress != nil {
				writeFile(t, filepath.Join(dir, "sync_progress.json"), *c.progress)
			}
			peek := c.peek
			if peek == nil {
				peek = daemon.PeekProcess
			}
			if got := DaemonLine(pidPath, lastSync, now, peek); got != c.want {
				t.Errorf("DaemonLine = %q, want %q", got, c.want)
			}
			if c.pid != nil {
				if _, err := os.Lstat(pidPath); err != nil {
					t.Errorf("pid file gone after DaemonLine: %v", err)
				}
			}
		})
	}
}

func TestDiagnostics_LastSyncUnreadable(t *testing.T) {
	dir := t.TempDir()
	lastSync := filepath.Join(dir, "last_sync.json")
	writeFile(t, lastSync, `{"finished_at":"2026-11-04T09:00:00Z"}`)
	if err := os.Chmod(lastSync, 0o000); err != nil {
		t.Fatal(err)
	}
	peek := func(string) (int, daemon.PeekState, error) { return 0, daemon.PeekNone, nil }
	if got, want := DaemonLine(filepath.Join(dir, "daemon.pid"), lastSync, time.Now(), peek), "stopped · last cycle unknown"; got != want {
		t.Errorf("DaemonLine = %q, want %q", got, want)
	}
	if row, ok := SyncRow(lastSync); !ok || row != SyncResultUnknown {
		t.Errorf("SyncRow = %q, %v; want %q, true", row, ok, SyncResultUnknown)
	}
}

func TestDiagnostics_SyncRow(t *testing.T) {
	finished := time.Date(2026, 11, 4, 9, 12, 30, 0, time.FixedZone("x", 3*3600))
	cases := []struct {
		name   string
		body   *string
		want   string
		wantOK bool
	}{
		{name: "sync_row_missing"},
		{name: "sync_row_corrupt", body: ptr("{"), want: SyncResultUnknown, wantOK: true},
		{name: "sync_row_ok", body: ptr(lastSyncJSON(t, finished, ""))},
		{name: "sync_row_failed", body: ptr(lastSyncJSON(t, finished, "slack: invalid_auth for team acme")),
			want: "  2026-11-04 06:12Z  sync  auth", wantOK: true},
		{name: "sync_row_failed_no_time", body: ptr(`{"error":"boom"}`), want: SyncResultUnknown, wantOK: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "last_sync.json")
			if c.body != nil {
				writeFile(t, path, *c.body)
			}
			row, ok := SyncRow(path)
			if row != c.want || ok != c.wantOK {
				t.Errorf("SyncRow = %q, %v; want %q, %v", row, ok, c.want, c.wantOK)
			}
			if strings.Contains(row, "acme") {
				t.Errorf("error text printed: %q", row)
			}
		})
	}
}

func TestDiagnostics_LogMissing(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "watchtower.log"), strings.Repeat("x", 12*1024))
	if got, want := LogsLine(dir), "watchtower.log 12 KB · daemon.log missing (not attached)"; got != want {
		t.Errorf("LogsLine = %q, want %q", got, want)
	}
	if got, want := LogsLine(filepath.Join(dir, "absent")), "watchtower.log missing · daemon.log missing (not attached)"; got != want {
		t.Errorf("LogsLine = %q, want %q", got, want)
	}
}

func TestDiagnostics_LogUnreadable(t *testing.T) {
	dir := t.TempDir()
	// A directory where the log should be is not a log file.
	if err := os.Mkdir(filepath.Join(dir, "daemon.log"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "watchtower.log"), "")
	if got, want := LogsLine(dir), "watchtower.log 0 B · daemon.log unreadable (not attached)"; got != want {
		t.Errorf("LogsLine = %q, want %q", got, want)
	}
	// A folder that cannot be searched: stat fails with a permission error.
	locked := filepath.Join(dir, "locked")
	if err := os.Mkdir(locked, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(locked, "watchtower.log"), "x")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })
	if got, want := LogsLine(locked), "watchtower.log unreadable · daemon.log unreadable (not attached)"; got != want {
		t.Errorf("LogsLine = %q, want %q", got, want)
	}
}

func TestDiagnostics_CrashLine(t *testing.T) {
	at := time.Date(2026, 11, 4, 9, 12, 0, 0, time.UTC)
	cases := []struct {
		name       string
		scan       CrashScan
		want, wrsn string
	}{
		{"none", CrashScan{}, "none in the logs", ""},
		{"one with time and place", CrashScan{Count: 1, Time: at, TimeKnown: true, Place: "watchtower/internal/sync.(*Syncer).run"},
			"1 in the logs, last after 2026-11-04 09:12Z, in watchtower/internal/sync.(*Syncer).run", ""},
		{"time unknown", CrashScan{Count: 2, Place: "watchtower/cmd.run"}, "2 in the logs, last time unknown, in watchtower/cmd.run", ""},
		{"no place", CrashScan{Count: 1, Time: at, TimeKnown: true}, "1 in the logs, last after 2026-11-04 09:12Z, in location unknown", ""},
		{"no logs", CrashScan{NoLogs: true}, "unknown (no logs)", ""},
		{"budget_logscan_with_crash", CrashScan{Count: 1, Time: at, TimeKnown: true, Place: "watchtower/cmd.run", Stopped: true, ScannedMB: 7},
			"1 in the logs, last after 2026-11-04 09:12Z, in watchtower/cmd.run (scan stopped after 7 MB)", ReasonLogScan},
		{"budget_logscan_none_found", CrashScan{Stopped: true, ScannedMB: 7}, "none in the first 7 MB of the logs (scan stopped)", ReasonLogScan},
		{"megabytes ignored when not stopped", CrashScan{ScannedMB: 7}, "none in the logs", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, reason := CrashLine(c.scan)
			if got != c.want || reason != c.wrsn {
				t.Errorf("CrashLine = %q, %q; want %q, %q", got, reason, c.want, c.wrsn)
			}
		})
	}
}

// TestDiagnostics_CrashPartUsesBudget: the scan's deadline is
// Budgets.LogScan from the part's start, not a hard-coded 2 s.
func TestDiagnostics_CrashPartUsesBudget(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "watchtower.log"), "2026/11/04 09:00:00 ok\n")
	start := time.Date(2026, 11, 4, 10, 0, 0, 0, time.UTC)
	calls := 0
	clock := func() time.Time {
		calls++
		if calls == 1 {
			return start
		}
		return start.Add(time.Second) // past a 500 ms budget at once
	}
	part := CrashPart(dir, Budgets{LogScan: 500 * time.Millisecond}, clock)
	text, reason := part(context.Background())
	if want := "none in the first 0 MB of the logs (scan stopped)"; text != want || reason != ReasonLogScan {
		t.Errorf("CrashPart = %q, %q; want %q, %q", text, reason, want, ReasonLogScan)
	}

	calls = 0
	part = CrashPart(dir, Budgets{LogScan: time.Hour}, clock)
	if text, reason := part(context.Background()); text != CrashNone || reason != "" {
		t.Errorf("CrashPart (1 h budget) = %q, %q; want %q", text, reason, CrashNone)
	}
	if text, _ := CrashPart(filepath.Join(dir, "absent"), DefaultBudgets, time.Now)(context.Background()); text != UnknownNoLogs {
		t.Errorf("CrashPart with no logs = %q, want %q", text, UnknownNoLogs)
	}
}

func TestDiagnostics_PolicyLine(t *testing.T) {
	cases := []struct {
		name string
		raw  map[string]any
		want string
	}{
		{"unmanaged", map[string]any{}, "managed by organization: no"},
		{"managed", map[string]any{policy.KeyAllowedSources: []any{"slack"}}, "managed by organization: yes"},
		{"managed with a defect", map[string]any{policy.KeyAllowedSources: "slack"}, "managed by organization: yes (with errors)"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			policytest.Set(t, c.raw)
			if got := PolicyPart(policy.Current()); got != c.want {
				t.Errorf("PolicyPart = %q, want %q", got, c.want)
			}
		})
	}
}

func TestDiagnostics_IPhoneFlag(t *testing.T) {
	for flag, want := range map[string]string{
		"on":    "iPhone companion on",
		"off":   "iPhone companion off",
		"":      "",
		"maybe": "",
	} {
		if got := IPhonePart(flag); got != want {
			t.Errorf("IPhonePart(%q) = %q, want %q", flag, got, want)
		}
	}
}

func TestDiagnosticsText_LocalHelpers(t *testing.T) {
	cases := []struct{ name, got, want string }{
		{"Age negative", Age(-time.Minute), AgeUnderMinute},
		{"Age seconds", Age(59 * time.Second), "under 1 min"},
		{"Age minutes", Age(4*time.Minute + 59*time.Second), "4 min"},
		{"Age hours", Age(47 * time.Hour), "47 h"},
		{"Age days", Age(72 * time.Hour), "3 d"},
		{"Size bytes", Size(512), "512 B"},
		{"Size KB", Size(12 * 1024), "12 KB"},
		{"Size MB exact", Size(4 << 20), "4 MB"},
		{"Size MB decimal", Size(4<<20 + 300<<10), "4.3 MB"},
		{"Size GB", Size(1288490188), "1.2 GB"},
		{"Size big GB", Size(20 << 30), "20 GB"},
		{"ChipApple", ChipApple(3), "Apple M3"},
		{"LogSize", LogSize(LogDaemon, LogMissing), "daemon.log missing"},
		{"IPhone", IPhone(OptionOn), "iPhone companion on"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, c.got, c.want)
		}
	}
}

func ptr(s string) *string { return &s }
