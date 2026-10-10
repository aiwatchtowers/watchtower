package claudesession

import (
	"bytes"
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

	got, ok, err := FindSession(configDir, busyID)
	if err != nil || !ok {
		t.Fatalf("FindSession(busy) = %v, %v, %v; want found", got, ok, err)
	}
	want := Entry{
		PID:                 4242,
		SessionID:           busyID,
		Status:              "busy",
		Version:             "2.1.295",
		MessagingSocketPath: "/tmp/example/cc-socks/4242.sock",
		ProcStart:           "Thu Jan  1 00:00:00 2026",
		PeerProtocol:        1,
		PeerFeatures:        []string{"notify_idle", "reply_across_default_dirs", "artifact_yield"},
		StatusUpdatedAt:     time.UnixMilli(1767225602687),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("busy entry =\n%+v\nwant\n%+v", got, want)
	}

	idle, ok, err := FindSession(configDir, idleID)
	if err != nil || !ok {
		t.Fatalf("FindSession(idle) = %v, %v, %v; want found", idle, ok, err)
	}
	if idle.Status != "idle" || !idle.StatusUpdatedAt.Equal(time.UnixMilli(1767225645660)) {
		t.Errorf("idle entry status = %q at %v", idle.Status, idle.StatusUpdatedAt)
	}

	if _, ok, err := FindSession(configDir, "00000000-0000-4000-8000-000000000999"); ok || err != nil {
		t.Errorf("unknown session: found=%v err=%v; want not found, nil", ok, err)
	}
	if _, ok, err := FindSession(configDir, ""); ok || err != nil {
		t.Errorf("empty session id: found=%v err=%v; want not found, nil", ok, err)
	}
}

// A first-write entry has no status yet: the raw status stays empty (unknown,
// neither busy nor idle) and the status time stays zero.
func TestFindSessionFirstWriteEntryHasNoStatus(t *testing.T) {
	configDir := writeRegistry(t)

	got, ok, err := FindSession(configDir, firstID)
	if err != nil || !ok {
		t.Fatalf("FindSession(first write) = %v, %v, %v; want found", got, ok, err)
	}
	if got.Status != "" || !got.StatusUpdatedAt.IsZero() {
		t.Errorf("first-write entry status = %q at %v; want empty, zero", got.Status, got.StatusUpdatedAt)
	}
	if got.PID != 4343 || got.MessagingSocketPath != "/tmp/example/cc-socks/4343.sock" {
		t.Errorf("first-write entry = %+v", got)
	}
}

func TestFindSessionWithoutRegistryIsNotFound(t *testing.T) {
	_, ok, err := FindSession(t.TempDir(), busyID)
	if ok || err != nil {
		t.Errorf("no sessions dir: found=%v err=%v; want not found, nil", ok, err)
	}
}

type fakeProc struct {
	alive    bool
	started  string
	startErr bool
}

func (f fakeProc) exists(int) bool { return f.alive }
func (f fakeProc) start(int) (string, bool) {
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
		if got := alive(c.entry, c.proc); got != c.want {
			t.Errorf("%s: alive = %v, want %v", c.name, got, c.want)
		}
	}
}

// The real process probe sees this test process alive with its own start
// time, and a dead pid gone.
func TestAliveSeesTheCurrentProcess(t *testing.T) {
	pid := os.Getpid()
	started, ok := osProc{}.start(pid)
	if !ok || started == "" {
		t.Fatalf("start(self) = %q, %v", started, ok)
	}
	if !Alive(Entry{PID: pid, ProcStart: started}) {
		t.Error("Alive(self with its start) = false")
	}
	if Alive(Entry{PID: pid, ProcStart: "Thu Jan  1 00:00:00 1970"}) {
		t.Error("Alive(self with another start) = true")
	}
}

// procStart is written in UTC: the probe's start time, read as UTC, is the
// test process's real start, not one shifted by the local zone.
func TestProcStartIsReadInUTC(t *testing.T) {
	started, ok := osProc{}.start(os.Getpid())
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

func TestConfigDirHonoursClaudeConfigDir(t *testing.T) {
	env := func(v string) func(string) string {
		return func(key string) string {
			if key == "CLAUDE_CONFIG_DIR" {
				return v
			}
			return ""
		}
	}
	if got := ConfigDir(env("/tmp/example/claude")); got != "/tmp/example/claude" {
		t.Errorf("ConfigDir(set) = %q", got)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	if got := ConfigDir(env("")); got != filepath.Join(home, ".claude") {
		t.Errorf("ConfigDir(unset) = %q, want %q", got, filepath.Join(home, ".claude"))
	}
}
