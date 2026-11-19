package inboxfeed

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

const screenWritesPath = "testdata/screen_writes.json"

// screenCase is one case of the screens' writes fixture (screen_writes.json,
// the shape of inbox_writes.json plus the command): Swift names the twin
// writer ScreenWritesFixtureTests runs over the same seed. Race says how two
// racing calls answer: "" one writes and the other answers already or
// changed, "both" both answer ok (an unguarded write, as in Swift), "skip" not
// raced (a create, an undo whose loser answers undone false, or a write
// each racer adds a row of its own to, as tracks.priority's feedback).
type screenCase struct {
	Name    string          `json:"name"`
	Seed    []string        `json:"seed"`
	Now     string          `json:"now"`
	Command string          `json:"command"`
	Call    json.RawMessage `json:"call"`
	Swift   json.RawMessage `json:"swift"`
	Race    string          `json:"race"`
	Expect  struct {
		writeExpect
		// Result lists fields the ok response must carry, as JSON values.
		Result map[string]json.RawMessage `json:"result"`
	} `json:"expect"`
}

func loadScreenCases(t testing.TB) []screenCase {
	t.Helper()
	b, err := os.ReadFile(screenWritesPath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []screenCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatalf("%s: %v", screenWritesPath, err)
	}
	return cases
}

// screenTower is a tower with every command registered over d.
func screenTower(d *db.DB, now time.Time, deps ActDeps) *tower.Tower {
	var r tower.Registry
	Register(&r, nil)
	RegisterAct(&r, deps)
	RegisterScreens(&r, deps)
	return tower.New(d, tower.Options{Registry: &r, Now: func() time.Time { return now }, Sentence: FaultSentence})
}

func callScreen(tw *tower.Tower, command string, params json.RawMessage, o tower.Origin) api.Response {
	return tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "1", Command: command, Params: params}, o)
}

// screenCommands is every command RegisterScreens registers (plan Task 9's
// table, reconciled with the call-site grep).
var screenCommands = []string{
	"outputs.read", "outputs.done", "outputs.dismiss", "reminders.done", "reminders.snooze",
	"briefing.read", "inbox_items.read",
	"tracks.read", "tracks.done", "tracks.stop", "tracks.restore", "tracks.priority", "tracks.ownership",
	"tracks.sub_items", "tracks.enabled", "tracks.instruction", "tracks.delete", "tracks.event_status",
	"tracks.events_read",
	"ideas.status", "ideas.snooze", "ideas.merge", "ideas.supersede", "ideas.rating", "ideas.create",
	"ideas.delete", "ideas.converted", "ideas.decision_seen", "ideas.decisions_seen_all",
	"ideas.create_from_chat", "ideas.undo_chat",
	"dayplan.done", "dayplan.pending", "dayplan.delete", "dayplan.reorder", "dayplan.add",
	"targets.set_status", "targets.set_column", "targets.snooze", "targets.work_on",
	"catchup.acknowledge", "digests.read", "digests.stream_read", "digests.decision_read", "digests.decisions_read_all",
}

// TestScreenCommands_EveryCommandIsRegisteredGuarded: each command of the
// table is registered as a guarded write that names the tables it changes,
// needs no hub grant (none is an AGENT-07 gesture) and has a verb phrase;
// a table it writes that the feed reads is in ChangeTables; and the fixture
// has a case for each.
// notFeedTables are the tables the screen commands write that inbox.feed
// does not read: a write to them needs no feed re-read.
var notFeedTables = map[string]bool{
	"digests": true, "decision_reads": true, "stream_digests": true, "feedback": true,
	"idea_mentions": true, "chat_messages": true, "chat_conversations": true,
	"target_status_history": true, "catchup_recaps": true,
}

func TestScreenCommands_EveryCommandIsRegisteredGuarded(t *testing.T) {
	var r tower.Registry
	RegisterScreens(&r, ActDeps{})
	got := map[string]tower.Command{}
	for _, c := range r.Commands() {
		got[c.Name] = c
	}
	if len(got) != len(screenCommands) {
		t.Errorf("%d commands registered, want %d", len(got), len(screenCommands))
	}
	covered := map[string]bool{}
	for _, c := range loadScreenCases(t) {
		covered[c.Command] = true
	}
	feedReads := map[string]bool{}
	for _, table := range ChangeTables {
		feedReads[table] = true
	}
	for _, name := range screenCommands {
		c, ok := got[name]
		if !ok {
			t.Errorf("%s is not registered", name)
			continue
		}
		if !c.Spec.Idempotent || c.Spec.Read || c.Spec.Watch || c.Spec.IdempotentFor != nil {
			t.Errorf("%s: spec %+v, want a guarded write", name, c.Spec)
		}
		if len(c.Spec.ChangeTables) == 0 {
			t.Errorf("%s names no ChangeTables", name)
		}
		for _, table := range c.Spec.ChangeTables {
			if !feedReads[table] && !notFeedTables[table] {
				t.Errorf("%s writes %s: add it to inbox.feed's ChangeTables if the feed reads it, else to notFeedTables", name, table)
			}
		}
		if c.Spec.Grant != "" || c.Spec.GrantFor != nil {
			t.Errorf("%s needs a grant; no screen command is an owner gesture", name)
		}
		if screenPhrases[name] == "" {
			t.Errorf("%s has no verb phrase", name)
		}
		if !covered[name] {
			t.Errorf("%s has no case in %s", name, screenWritesPath)
		}
		req := reflect.New(c.Req).Elem()
		if f, ok := req.Type().FieldByName("WriteParams"); !ok || !f.Anonymous {
			t.Errorf("%s: %s does not embed WriteParams", name, c.Req)
		}
	}
}

// TestScreenCommands_HubIsRefused: every screen command is the Mac's own:
// from the hub it answers not_permitted ("…: this is done on the Mac.")
// before anything is written, whatever the hub routes.
func TestScreenCommands_HubIsRefused(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range loadScreenCases(t) {
		if seen[c.Command] {
			continue
		}
		seen[c.Command] = true
		t.Run(c.Command, func(t *testing.T) {
			d := seeded(t, c.Seed)
			before := snapshotRows(t, d, c.Expect.Rows)
			resp := callScreen(screenTower(d, time.Now(), fixtureDeps(t, d)), c.Command, c.Call, hub)
			if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeNotPermitted ||
				!strings.HasSuffix(resp.Refusal.Sentence, ": "+reasonOnTheMac) {
				t.Fatalf("answer %s %+v, want not_permitted on the Mac", resp.Status, resp.Refusal)
			}
			if after := snapshotRows(t, d, c.Expect.Rows); after != before {
				t.Errorf("rows changed:\n%s\nwant\n%s", after, before)
			}
			var n int
			if err := d.QueryRow(`SELECT COUNT(*) FROM tower_requests`).Scan(&n); err != nil || n != 0 {
				t.Errorf("%d ledger rows (%v), want none", n, err)
			}
		})
	}
	if len(seen) != len(screenCommands) {
		t.Errorf("%d commands checked, want %d", len(seen), len(screenCommands))
	}
}

// snapshotRows is the rows of the tables want names, on its columns, as text.
func snapshotRows(t *testing.T, d *db.DB, want map[string][]map[string]any) string {
	t.Helper()
	var b strings.Builder
	for _, table := range slices.Sorted(maps.Keys(want)) {
		got, err := readRows(d, table, columnsOf(want[table]))
		if err != nil {
			t.Fatal(err)
		}
		b.WriteString(table)
		for _, r := range got {
			b.WriteString(fmt.Sprint(r))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func TestScreenWritesCases(t *testing.T) {
	cases := loadScreenCases(t)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			d := seeded(t, c.Seed)
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatal(err)
			}
			resp := callScreen(screenTower(d, now, fixtureDeps(t, d)), c.Command, c.Call, socket)
			checkScreenAnswer(t, c, resp)
			assertRows(t, d, c.Expect.Rows)
		})
	}
}

func checkScreenAnswer(t *testing.T, c screenCase, resp api.Response) {
	t.Helper()
	if string(resp.Status) != c.Expect.Status {
		t.Fatalf("status %s (%+v), want %s", resp.Status, resp.Refusal, c.Expect.Status)
	}
	if resp.Status == api.StatusRefused {
		if string(resp.Refusal.Code) != c.Expect.Code {
			t.Errorf("code %s (%s), want %s", resp.Refusal.Code, resp.Refusal.Sentence, c.Expect.Code)
		}
		if c.Expect.Sentence != "" && resp.Refusal.Sentence != c.Expect.Sentence {
			t.Errorf("sentence %q, want %q", resp.Refusal.Sentence, c.Expect.Sentence)
		}
		return
	}
	var res map[string]json.RawMessage
	if err := json.Unmarshal(resp.Result, &res); err != nil {
		t.Fatal(err)
	}
	if got := string(res["already"]) == "true"; got != c.Expect.Already {
		t.Errorf("result %s, want already=%v", resp.Result, c.Expect.Already)
	}
	for k, want := range c.Expect.Result {
		if canon(t, res[k]) != canon(t, want) {
			t.Errorf("result %s = %s, want %s", k, res[k], want)
		}
	}
}

func canon(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	if len(raw) == 0 {
		return "null"
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// TestScreenWrites_TwoConnectionsRace: every writing case of the fixture,
// called at once from two db.Open handles on one file on the same rows: a
// guarded write lands once (one ok, the other already or changed); an
// unguarded one (race "both") answers ok to both, whichever of them wrote;
// either way the rows end as the fixture says.
func TestScreenWrites_TwoConnectionsRace(t *testing.T) {
	ran := 0
	for _, c := range loadScreenCases(t) {
		if c.Expect.Status != "ok" || c.Expect.Already || c.Race == "skip" {
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
			var params map[string]any
			if err := json.Unmarshal(c.Call, &params); err != nil {
				t.Fatal(err)
			}
			var wg sync.WaitGroup
			answers := make([]api.Response, 2)
			for i, h := range []*db.DB{d, other} {
				params["request_id"] = newRequestID()
				p, err := json.Marshal(params)
				if err != nil {
					t.Fatal(err)
				}
				tw := screenTower(h, now, fixtureDeps(t, h))
				wg.Go(func() { answers[i] = callScreen(tw, c.Command, p, socket) })
			}
			wg.Wait()
			wrote, lost := 0, 0
			for _, a := range answers {
				switch {
				case a.Status == api.StatusOK && !strings.Contains(string(a.Result), `"already":true`):
					wrote++
				case a.Status == api.StatusOK, a.Status == api.StatusRefused && a.Refusal.Code == api.CodeChanged:
					lost++
				default:
					t.Errorf("answer %s %+v %s", a.Status, a.Refusal, a.Result)
				}
			}
			switch {
			case c.Race == "both" && (answers[0].Status != api.StatusOK || answers[1].Status != api.StatusOK):
				t.Errorf("answers %s and %s, want ok to both", answers[0].Status, answers[1].Status)
			case c.Race != "both" && (wrote != 1 || lost != 1):
				t.Errorf("%d wrote, %d already/changed; want one each", wrote, lost)
			}
			assertRows(t, d, c.Expect.Rows)
		})
	}
	if ran < 40 {
		t.Fatalf("%d racing cases, want every write", ran)
	}
}
