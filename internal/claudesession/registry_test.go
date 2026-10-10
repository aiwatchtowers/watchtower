package claudesession

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	busyID  = "00000000-0000-4000-8000-000000000411"
	idleID  = "00000000-0000-4000-8000-000000000412"
	firstID = "00000000-0000-4000-8000-000000000413"
)

// firstWriteEntry is the shape Claude Code writes at process start, before
// the first status update: no status, updatedAt or statusUpdatedAt keys.
const firstWriteEntry = `{
  "pid": 4343,
  "sessionId": "` + firstID + `",
  "cwd": "/tmp/example/work",
  "startedAt": 1767225600000,
  "procStart": "Thu Jan  1 00:00:00 2026",
  "version": "2.1.295",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle"],
  "kind": "interactive",
  "entrypoint": "sdk-cli",
  "pidDomain": "darwin",
  "messagingSocketPath": "/tmp/example/cc-socks/4343.sock"
}`

func writeRegistry(t *testing.T) string {
	t.Helper()
	configDir := t.TempDir()
	sessions := filepath.Join(configDir, "sessions")
	if err := os.MkdirAll(sessions, 0o755); err != nil {
		t.Fatal(err)
	}
	busy, err := os.ReadFile("testdata/registry_busy.json")
	if err != nil {
		t.Fatal(err)
	}
	idle, err := os.ReadFile("testdata/registry_idle.json")
	if err != nil {
		t.Fatal(err)
	}
	// Both fixtures carry the same session id; give the idle one its own.
	idle = bytes.ReplaceAll(idle, []byte(busyID), []byte(idleID))
	files := map[string][]byte{
		"4242.json":    busy,
		"4243.json":    idle,
		"4343.json":    []byte(firstWriteEntry),
		"4444.json":    []byte("{not json"),
		"1000.json":    []byte(`{"pid": "x", "sessionId": "` + busyID + `"}`),
		"4242.abc.key": []byte(`{"sessionId": "` + busyID + `"}`),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(sessions, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// The key file must never be opened: an attempt fails with EACCES.
	key := filepath.Join(sessions, "4242.abc.key")
	if err := os.Chmod(key, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(key, 0o600) })
	return configDir
}

func TestFindSessionMatchesBySessionID(t *testing.T) {
	configDir := writeRegistry(t)

	got, ok, err := FindSessionWith(configDir, busyID, pidProc{})
	if err != nil || !ok {
		t.Fatalf("FindSessionWith(busy) = %v, %v, %v; want found", got, ok, err)
	}
	want := Entry{
		PID:             4242,
		SessionID:       busyID,
		Status:          "busy",
		Version:         "2.1.295",
		ProcStart:       "Thu Jan  1 00:00:00 2026",
		StatusUpdatedAt: time.UnixMilli(1767225602687),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("busy entry =\n%+v\nwant\n%+v", got, want)
	}

	idle, ok, err := FindSessionWith(configDir, idleID, pidProc{})
	if err != nil || !ok {
		t.Fatalf("FindSessionWith(idle) = %v, %v, %v; want found", idle, ok, err)
	}
	if idle.Status != "idle" || !idle.StatusUpdatedAt.Equal(time.UnixMilli(1767225645660)) {
		t.Errorf("idle entry status = %q at %v", idle.Status, idle.StatusUpdatedAt)
	}

	if _, ok, err := FindSessionWith(configDir, "00000000-0000-4000-8000-000000000999", pidProc{}); ok || err != nil {
		t.Errorf("unknown session: found=%v err=%v; want not found, nil", ok, err)
	}
	if _, ok, err := FindSessionWith(configDir, "", pidProc{}); ok || err != nil {
		t.Errorf("empty session id: found=%v err=%v; want not found, nil", ok, err)
	}
}

// A first-write entry has no status yet: the raw status stays empty (unknown,
// neither busy nor idle) and the status time stays zero.
func TestFindSessionFirstWriteEntryHasNoStatus(t *testing.T) {
	configDir := writeRegistry(t)

	got, ok, err := FindSessionWith(configDir, firstID, pidProc{})
	if err != nil || !ok {
		t.Fatalf("FindSessionWith(first write) = %v, %v, %v; want found", got, ok, err)
	}
	if got.Status != "" || !got.StatusUpdatedAt.IsZero() {
		t.Errorf("first-write entry status = %q at %v; want empty, zero", got.Status, got.StatusUpdatedAt)
	}
	if got.PID != 4343 || got.ProcStart != "Thu Jan  1 00:00:00 2026" {
		t.Errorf("first-write entry = %+v", got)
	}
}

// The config dir is a path, not a pattern: glob metacharacters in it neither
// fail the read nor match other dirs, and a dir named *.json is not an entry.
func TestFindSessionTakesTheConfigDirLiterally(t *testing.T) {
	parent := t.TempDir()
	configDir := filepath.Join(parent, "claude[1]")
	sessions := filepath.Join(configDir, "sessions")
	if err := os.MkdirAll(filepath.Join(sessions, "9999.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessions, "4242.json"), []byte(entryJSONText(4242, "busy", 1767225600000)), 0o600); err != nil {
		t.Fatal(err)
	}
	// "claude[1]" as a pattern matches "claude1": an entry there must not be read.
	decoy := filepath.Join(parent, "claude1", "sessions")
	if err := os.MkdirAll(decoy, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(decoy, "5555.json"), []byte(entryJSONText(5555, "idle", 1767225699000)), 0o600); err != nil {
		t.Fatal(err)
	}

	got, ok, err := FindSessionWith(configDir, busyID, pidProc{})
	if err != nil || !ok || got.PID != 4242 || got.Status != "busy" {
		t.Errorf("FindSessionWith(%q) = %+v, %v, %v; want the busy 4242", configDir, got, ok, err)
	}
}

func TestFindSessionWithoutRegistryIsNotFound(t *testing.T) {
	_, ok, err := FindSessionWith(t.TempDir(), busyID, pidProc{})
	if ok || err != nil {
		t.Errorf("no sessions dir: found=%v err=%v; want not found, nil", ok, err)
	}
}

// pidProc is a process table where only the listed pids run.
type pidProc map[int]bool

func (p pidProc) Exists(pid int) bool    { return p[pid] }
func (pidProc) Start(int) (string, bool) { return "", false }

func entryJSONText(pid int, status string, statusUpdatedAt int64) string {
	return fmt.Sprintf(`{"pid": %d, "sessionId": %q, "status": %q, "statusUpdatedAt": %d}`,
		pid, busyID, status, statusUpdatedAt)
}

// A stale entry left by a crashed process must not hide the live entry of
// the same session resumed under a new pid, whichever file sorts first; with
// no live entry the newest status wins.
func TestFindSessionPrefersTheLiveEntryOfASession(t *testing.T) {
	for _, order := range []struct{ stale, live string }{
		{"1000.json", "2000.json"},
		{"2000.json", "1000.json"},
	} {
		configDir := t.TempDir()
		sessions := filepath.Join(configDir, "sessions")
		if err := os.MkdirAll(sessions, 0o755); err != nil {
			t.Fatal(err)
		}
		// The stale entry carries the newer status: liveness must win over it.
		files := map[string]string{
			order.stale: entryJSONText(111, "busy", 1767225699000),
			order.live:  entryJSONText(222, "idle", 1767225600000),
		}
		for name, data := range files {
			if err := os.WriteFile(filepath.Join(sessions, name), []byte(data), 0o600); err != nil {
				t.Fatal(err)
			}
		}

		got, ok, err := FindSessionWith(configDir, busyID, pidProc{222: true})
		if err != nil || !ok || got.PID != 222 {
			t.Errorf("stale %s, live %s: got pid %d, %v, %v; want the live 222", order.stale, order.live, got.PID, ok, err)
		}
		got, ok, err = FindSessionWith(configDir, busyID, pidProc{})
		if err != nil || !ok || got.PID != 111 {
			t.Errorf("stale %s, live %s, none alive: got pid %d, %v, %v; want the newest status 111", order.stale, order.live, got.PID, ok, err)
		}
	}
}

type fakeProc struct {
	alive    bool
	started  string
	startErr bool
}

func (f fakeProc) Exists(int) bool { return f.alive }
func (f fakeProc) Start(int) (string, bool) {
	if f.startErr {
		return "", false
	}
	return f.started, true
}

func TestAliveRejectsAReusedPID(t *testing.T) {
	const started = "Thu Jan  1 00:00:00 2026"
	withStart := Entry{PID: 4242, ProcStart: started}
	cases := []struct {
		name  string
		entry Entry
		proc  fakeProc
		want  bool
	}{
		{"same start", withStart, fakeProc{alive: true, started: started}, true},
		{"same start, other spacing", withStart, fakeProc{alive: true, started: "Thu Jan 1 00:00:00 2026\n"}, true},
		{"reused pid", withStart, fakeProc{alive: true, started: "Fri Jan  2 09:00:00 2026"}, false},
		{"start unreadable", withStart, fakeProc{alive: true, startErr: true}, false},
		{"gone", withStart, fakeProc{alive: false, started: started}, false},
		{"no proc start, exists", Entry{PID: 4242}, fakeProc{alive: true, startErr: true}, true},
		{"no proc start, gone", Entry{PID: 4242}, fakeProc{alive: false}, false},
		{"no pid", Entry{}, fakeProc{alive: true}, false},
	}
	for _, c := range cases {
		if got := AliveWith(c.entry, c.proc); got != c.want {
			t.Errorf("%s: alive = %v, want %v", c.name, got, c.want)
		}
	}
}

// The real process probe sees this test process alive with its own start
// time, and a dead pid gone.
func TestAliveSeesTheCurrentProcess(t *testing.T) {
	pid := os.Getpid()
	started, ok := SystemProcs{}.Start(pid)
	if !ok || started == "" {
		t.Fatalf("start(self) = %q, %v", started, ok)
	}
	if !AliveWith(Entry{PID: pid, ProcStart: started}, SystemProcs{}) {
		t.Error("AliveWith(self with its start) = false")
	}
	if AliveWith(Entry{PID: pid, ProcStart: "Thu Jan  1 00:00:00 1970"}, SystemProcs{}) {
		t.Error("AliveWith(self with another start) = true")
	}
}

// procStart is written in UTC: the probe's start time, read as UTC, is the
// test process's real start, not one shifted by the local zone.
func TestProcStartIsReadInUTC(t *testing.T) {
	started, ok := SystemProcs{}.Start(os.Getpid())
	if !ok {
		t.Fatal("start(self) not read")
	}
	at, err := time.ParseInLocation("Mon Jan 2 15:04:05 2006", strings.Join(strings.Fields(started), " "), time.UTC)
	if err != nil {
		t.Fatalf("start(self) = %q: %v", started, err)
	}
	if age := time.Since(at); age < -time.Minute || age > 30*time.Minute {
		t.Errorf("start(self) = %q read as UTC is %v from now; want the recent past", started, age)
	}
}
