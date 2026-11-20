package tower_test

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
	"watchtower/internal/tower/commands"
)

// TestPause_ServesInboxFeedWhilePaused is TestPause_ServesInboxWhilePaused's
// inbox.feed half (spec: the daemon serves inbox.feed while sync is
// paused). It lives in the external test package because inboxfeed imports
// tower: with the pause file present, inbox.feed and inbox.watch answer ok
// on the first start and across a restart, through the real registration.
func TestPause_ServesInboxFeedWhilePaused(t *testing.T) {
	ws := t.TempDir()
	if err := tower.SetPaused(ws, true); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(ws, "watchtower.db")
	for _, name := range []string{"first start", "restart"} {
		d, err := db.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		r := &tower.Registry{}
		commands.RegisterAll(r, commands.Deps{})
		tw := tower.New(d, tower.Options{Registry: r, Workspace: ws, Changes: tower.NewChanges(d, tower.PollInterval)})
		call := func(command string) api.Response {
			return tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "1", Command: command},
				tower.Origin{Transport: "socket"})
		}
		resp := call("inbox.feed")
		if resp.Status != api.StatusOK {
			t.Fatalf("%s: inbox.feed while paused: %+v", name, resp)
		}
		var feed api.Feed
		if err := json.Unmarshal(resp.Result, &feed); err != nil || feed.V != api.FeedVersion || len(feed.Folders) == 0 {
			t.Fatalf("%s: inbox.feed answered %s (%v)", name, resp.Result, err)
		}
		if resp := call("inbox.watch"); resp.Status != api.StatusOK {
			t.Fatalf("%s: inbox.watch while paused: %+v", name, resp)
		}
		var hello api.HelloResponse
		if err := json.Unmarshal(call("tower.hello").Result, &hello); err != nil || !hello.SyncPaused {
			t.Fatalf("%s: hello says not paused (%v)", name, err)
		}
		if err := d.Close(); err != nil {
			t.Fatal(err)
		}
	}
}
