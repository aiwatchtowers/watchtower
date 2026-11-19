package tower

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/tower/api"
)

// pauseFixture is a fixture whose Tower runs over the workspace ws with the
// pause commands registered.
func pauseFixture(t *testing.T, ws string, noSync bool) *fixture {
	t.Helper()
	return newFixtureWith(t, func(r *Registry, o *Options) {
		RegisterPause(r)
		o.Workspace = ws
		o.NoSync = noSync
	})
}

func (f *fixture) hello() api.HelloResponse {
	f.t.Helper()
	r := f.call("tower.hello", nil)
	if r.Status != api.StatusOK {
		f.t.Fatalf("hello: %+v", r)
	}
	var h api.HelloResponse
	if err := json.Unmarshal(r.Result, &h); err != nil {
		f.t.Fatal(err)
	}
	return h
}

func (f *fixture) pause(command, id string) api.PauseResponse {
	f.t.Helper()
	r := f.call(command, api.PauseRequest{WriteParams: api.WriteParams{RequestID: id}})
	if r.Status != api.StatusOK {
		f.t.Fatalf("%s: %+v", command, r)
	}
	var p api.PauseResponse
	if err := json.Unmarshal(r.Result, &p); err != nil {
		f.t.Fatal(err)
	}
	return p
}

func TestPause_FileIsAtomicAndSurvivesARestart(t *testing.T) {
	ws := t.TempDir()
	f := pauseFixture(t, ws, false)
	if f.hello().SyncPaused || IsPaused(ws) {
		t.Fatal("paused before any sync.pause")
	}
	if p := f.pause("sync.pause", "p1"); !p.Paused {
		t.Fatalf("sync.pause answered %+v", p)
	}
	fi, err := os.Stat(PausePath(ws))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("%s: %v, %v", PausePath(ws), fi, err)
	}
	if PausePath(ws) != filepath.Join(ws, "sync.paused") {
		t.Fatalf("PausePath = %s", PausePath(ws))
	}
	entries, err := os.ReadDir(ws)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() != "sync.paused" && strings.HasPrefix(e.Name(), "sync.paused") {
			t.Fatalf("a temp file was left behind: %s", e.Name())
		}
	}

	// A new Tower over the same workspace — a daemon restart — still sees it.
	restarted := pauseFixture(t, ws, false)
	if !restarted.hello().SyncPaused {
		t.Fatal("the pause did not survive a restart")
	}
	if p := restarted.pause("sync.resume", "r1"); p.Paused {
		t.Fatalf("sync.resume answered %+v", p)
	}
	if _, err := os.Stat(PausePath(ws)); !os.IsNotExist(err) {
		t.Fatalf("sync.resume left the file: %v", err)
	}
	if restarted.hello().SyncPaused || IsPaused(ws) {
		t.Fatal("still paused after sync.resume")
	}
	// A resume of a sync that is not paused is a no-op.
	if p := restarted.pause("sync.resume", "r2"); p.Paused {
		t.Fatalf("a second sync.resume answered %+v", p)
	}
}

// TestPause_ServesInboxWhilePaused: with the pause file present, tower.ping
// and a read keep answering ok across a restart. Its inbox.feed half is
// TestPause_ServesInboxFeedWhilePaused (pause_inbox_test.go, the external
// test package: inboxfeed imports tower).
func TestPause_ServesInboxWhilePaused(t *testing.T) {
	ws := t.TempDir()
	if err := SetPaused(ws, true); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"first start", "restart"} {
		f := pauseFixture(t, ws, false)
		if !f.hello().SyncPaused {
			t.Fatalf("%s: hello says not paused", name)
		}
		if r := f.call("tower.ping", nil); r.Status != api.StatusOK {
			t.Fatalf("%s: ping while paused: %+v", name, r)
		}
		if r := f.call("test.read", nil); r.Status != api.StatusOK {
			t.Fatalf("%s: a read while paused: %+v", name, r)
		}
	}
}

func TestPause_WithoutAWorkspaceIsRefused(t *testing.T) {
	f := pauseFixture(t, "", false)
	r := f.call("sync.pause", api.PauseRequest{WriteParams: api.WriteParams{RequestID: "p"}})
	if r.Status != api.StatusRefused || r.Refusal.Code != api.CodeUnsupported {
		t.Fatalf("sync.pause with no workspace: %+v", r)
	}
}

func TestHello_NoSyncIsReportedAndNeverStored(t *testing.T) {
	ws := t.TempDir()
	h := pauseFixture(t, ws, true).hello()
	if !h.NoSync || h.SyncPaused {
		t.Fatalf("hello with --no-sync: %+v, want no_sync and not paused", h)
	}
	if _, err := os.Stat(PausePath(ws)); !os.IsNotExist(err) {
		t.Fatalf("--no-sync wrote the owner's pause: %v", err)
	}
	if h := pauseFixture(t, ws, false).hello(); h.NoSync || h.SyncPaused {
		t.Fatalf("a start without --no-sync after one with it: %+v", h)
	}
}
