package inboxfeed

import (
	"encoding/json"
	"maps"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// unguardedRace are the fixture writes whose second racer may write again:
// a reminder's Snooze, which keeps SnoozeReminder's unguarded UPDATE (its
// Swift twin's), answers ok to both.
var unguardedRace = map[string]bool{"ref_reminder_snooze_hook": true}

// TestInboxAct_TwoConnectionsRace: every write of the fixture, called at
// once from two db.Open handles on one file (two processes, as far as
// SQLite is concerned) on the same row: exactly one answers ok without
// already, the other already or changed.
func TestInboxAct_TwoConnectionsRace(t *testing.T) {
	ran := 0
	for _, c := range loadWriteCases(t) {
		if c.Expect.Status != "ok" || c.Expect.Already || unguardedRace[c.Name] {
			continue
		}
		ran++
		t.Run(c.Name, func(t *testing.T) {
			d, path := seededAt(t, c.Seed)
			other, err := db.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = other.Close() })
			now, _ := time.Parse(time.RFC3339, c.Now)
			var req api.ActRequest
			if err := json.Unmarshal(c.Call, &req); err != nil {
				t.Fatal(err)
			}
			var wg sync.WaitGroup
			answers := make([]api.Response, 2)
			for i, h := range []*db.DB{d, other} {
				r := req
				r.RequestID = newRequestID()
				p, err := json.Marshal(r)
				if err != nil {
					t.Fatal(err)
				}
				tw := actTower(h, now, fixtureDeps(t, h))
				wg.Go(func() { answers[i] = callAct(t, tw, p, socket) })
			}
			wg.Wait()
			wrote, other2 := 0, 0
			for _, a := range answers {
				switch {
				case a.Status == api.StatusOK && !strings.Contains(string(a.Result), `"already":true`):
					wrote++
				case a.Status == api.StatusOK, a.Status == api.StatusRefused && a.Refusal.Code == api.CodeChanged:
					other2++
				default:
					t.Errorf("answer %s %+v %s", a.Status, a.Refusal, a.Result)
				}
			}
			if wrote != 1 || other2 != 1 {
				t.Errorf("%d wrote, %d already/changed; want one each", wrote, other2)
			}
			rows := c.Expect.Rows
			if strings.Contains(c.Name, "make_task") {
				// The losing press's apply_track_action row stays as a failed
				// audit row ("This change was already applied."), which no
				// approval list shows (db.approvalRowClause): the change
				// itself landed once.
				rows = maps.Clone(rows)
				delete(rows, "agent_actions")
			}
			assertRows(t, d, rows)
		})
	}
	if ran < 18 {
		t.Fatalf("%d racing cases, want every guarded write", ran)
	}
}
