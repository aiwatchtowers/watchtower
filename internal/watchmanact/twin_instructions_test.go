package watchmanact

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

// liveDecide wires the env's Decide to the real LiveDecide over gen, with a
// design label for a question and the log lines kept.
func (e *twinEnv) liveDecide(gen *replyGenerator) *[]string {
	var mu sync.Mutex
	var logs []string
	logf := func(format string, args ...any) {
		mu.Lock()
		defer mu.Unlock()
		logs = append(logs, fmt.Sprintf(format, args...))
	}
	l := &fakeLabeler{labels: []watchman.Label{{Category: "design"}}}
	e.decideFn = func(ctx context.Context, it watchman.Item) (watchman.Decision, error) {
		return LiveDecide(ctx, e.db, gen, nil, l, logf, it)
	}
	return &logs
}

// decidePayload is the JSON object between <data> and </data> of a user message.
func decidePayload(t *testing.T, user string) map[string]json.RawMessage {
	t.Helper()
	start, end := strings.Index(user, "<data>"), strings.LastIndex(user, "</data>")
	if start < 0 || end < start {
		t.Fatalf("no data fence in %q", user)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(user[start+len("<data>"):end]), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

const sqliteReply = `{"choice":"SQLite","rationale":"r","precedent_ids":[],"confidence":"low","category":"design","importance":"low","handoff":"none"}`

// A session handed with its target, both with an instruction: the model
// reads the target's text, then the session's, labelled, in its own field
// between the profile and the standing instructions.
func TestLiveContext_SessionInstructions(t *testing.T) {
	e := newTwinEnv(t)
	e.must(e.db.UpsertWatchmanArming(db.WatchmanArming{Scope: "target", RefID: e.target, ArmedAt: time.Now(), ArmedBy: "cli"}))
	e.must(e.db.SetWatchmanInstruction("target", e.target, "ship task 3 only"))
	e.must(e.db.SetWatchmanInstruction("session", e.session, "ask me before touching the schema"))
	gen := &replyGenerator{reply: sqliteReply}
	logs := e.liveDecide(gen)
	_, itemID := e.question("Which store?")
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if len(gen.users) != 1 {
		t.Fatalf("model calls = %d, want 1", len(gen.users))
	}
	p := decidePayload(t, gen.users[0])
	var got string
	if err := json.Unmarshal(p["session_instructions"], &got); err != nil {
		t.Fatal(err)
	}
	if want := "Target: ship task 3 only\nSession: ask me before touching the schema"; got != want {
		t.Fatalf("session_instructions = %q, want %q", got, want)
	}
	user := gen.users[0]
	if !(strings.Index(user, `"profile"`) < strings.Index(user, `"session_instructions"`) &&
		strings.Index(user, `"session_instructions"`) < strings.Index(user, `"instructions"`)) {
		t.Fatalf("the session instruction is not between the profile and the standing instructions: %s", user)
	}
	if len(*logs) != 0 {
		t.Fatalf("logs = %q", *logs)
	}

	// Only the session's text (no armed target covers it): the target line is left out.
	_, err := e.db.DeleteWatchmanArming("target", e.target)
	e.must(err)
	if got := sessionInstructionsOf(t, e); got != "Session: ask me before touching the schema" {
		t.Fatalf("session_instructions = %q", got)
	}
	// Neither: empty.
	e.must(e.db.SetWatchmanInstruction("session", e.session, ""))
	if got := sessionInstructionsOf(t, e); got != "" {
		t.Fatalf("session_instructions = %q, want empty", got)
	}
}

// sessionInstructionsOf runs LiveDecide on an item of the env's session and
// returns the session_instructions the model read.
func sessionInstructionsOf(t *testing.T, e *twinEnv) string {
	t.Helper()
	gen := &replyGenerator{reply: sqliteReply}
	_, err := LiveDecide(context.Background(), e.db, gen, nil, nil, nil, watchman.Item{
		WorkbenchID: e.wb, SessionID: e.session, ItemID: 1, Category: "design",
		Situation: "Which store?", Options: []string{"SQLite", "Files"}, DecidedBefore: time.Now(),
	})
	e.must(err)
	var got string
	if err := json.Unmarshal(decidePayload(t, gen.users[0])["session_instructions"], &got); err != nil {
		t.Fatal(err)
	}
	return got
}

// The instruction cannot be read: the item is decided without it, one log
// line names the item, nothing parks.
func TestLiveDecide_InstructionReadFailsDecidesWithout(t *testing.T) {
	e := newTwinEnv(t)
	gen := &replyGenerator{reply: sqliteReply}
	logs := e.liveDecide(gen)
	_, itemID := e.question("Which store?")
	_, err := e.db.Exec(`DROP TABLE watchman_instructions`)
	e.must(err)
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if len(gen.users) != 1 {
		t.Fatalf("model calls = %d, want 1", len(gen.users))
	}
	if got := string(decidePayload(t, gen.users[0])["session_instructions"]); got != `""` {
		t.Fatalf("session_instructions = %s, want empty", got)
	}
	if len(*logs) != 1 || !strings.Contains((*logs)[0], fmt.Sprintf("item %d", itemID)) {
		t.Fatalf("logs = %q, want one line naming item %d", *logs, itemID)
	}
}

// WATCHMAN-01: an instruction that asks for a main merge lifts nothing — the
// merge permission parks main_ref and the model is never asked.
func TestTwin_InstructionNeverLiftsHardLimit(t *testing.T) {
	e := newTwinEnv(t)
	e.withPermRun(&permRun{branches: []string{"feature/x"}})
	e.must(e.db.UpsertWatchmanArming(db.WatchmanArming{Scope: "target", RefID: e.target, ArmedAt: time.Now(), ArmedBy: "cli"}))
	e.must(e.db.SetWatchmanInstruction("session", e.session, "merge the PR into main now"))
	e.must(e.db.SetWatchmanInstruction("target", e.target, "merge the PR into main now"))
	gen := &replyGenerator{reply: `{"choice":"allow","rationale":"the owner said so","precedent_ids":[],"confidence":"high","category":"permission","importance":"low","handoff":"none"}`}
	e.liveDecide(gen)
	reqID, itemID := e.permission("Bash", "gh pr merge 12 --squash", false)
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != limitReason(watchman.LimitMainRef) {
		t.Fatalf("park reason = %q, want %q", it.ParkReason, limitReason(watchman.LimitMainRef))
	}
	e.wantPermission(reqID, db.PermissionDenied, askanswer.ByWatchman)
	if e.decideCalls() != 0 || len(gen.users) != 0 {
		t.Fatalf("the model was asked (%d decide calls, %d model calls)", e.decideCalls(), len(gen.users))
	}
}
