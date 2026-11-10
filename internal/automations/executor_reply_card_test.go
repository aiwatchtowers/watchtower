package automations_test

import (
	"encoding/json"
	"testing"

	"watchtower/internal/db"
)

// replyCardScript writes a report and a log step: a run that ran leaves both.
const replyCardScript = `log("ran"); output.report({title: "r", body: trigger.reply.value})`

// writeCard commits a living inbox card with key "bugs" and the given
// content hash for automation a through a finished manual run (the upsert
// path a rewrite takes), or removes the key when hash is "".
func (f *exFixture) writeCard(t *testing.T, a db.Automation, hash string) {
	t.Helper()
	id := f.enqueue(t, a, db.TriggerManual)
	ok, err := f.d.ClaimAutomationRun(id, a.ApprovalHash, a.RecipeText, 0, 0, f.clock.Now())
	if err != nil || !ok {
		t.Fatalf("claim %d = %v, %v", id, ok, err)
	}
	c := &db.RunCommit{Removals: []string{"bugs"}}
	if hash != "" {
		c = &db.RunCommit{Outputs: []db.AutomationOutput{{Kind: "inbox", Title: "Bugs " + hash, Body: "b",
			OutputKey: "bugs", ContentHash: hash, BlocksJSON: `{"v":1,"blocks":[]}`,
			Actions: []db.InboxAction{{Label: "Later", Kind: db.InboxActionReply, Reply: "later"}}}}}
	}
	if err := f.d.FinishAutomationRun(id, db.RunFinish{Status: db.RunSucceeded, Now: f.clock.Now()}, c); err != nil {
		t.Fatalf("finish %d: %v", id, err)
	}
}

func (f *exFixture) cardID(t *testing.T, a db.Automation) int64 {
	t.Helper()
	var id int64
	if err := f.d.QueryRow(`SELECT id FROM automation_outputs WHERE automation_id = ? AND output_key = 'bugs'`, a.ID).
		Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

// pressCard queues the reply run a press of the card's action 0 makes, with
// the payload's content hash.
func (f *exFixture) pressCard(t *testing.T, a db.Automation, hash string) int64 {
	t.Helper()
	id, err := f.d.PressInboxOutputAction(f.cardID(t, a), 0, hash, f.clock.Now())
	if err != nil {
		t.Fatalf("press: %v", err)
	}
	return id
}

func (f *exFixture) reportCount(t *testing.T) int {
	t.Helper()
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM automation_outputs WHERE kind = 'report'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// AUTO-06: a queued reply run whose card changed (or was removed) before it
// started ends cancelled with the reason; its script never runs.
func TestExecutor_ReplyRunOnChangedCardCancelled(t *testing.T) {
	for name, rewrite := range map[string]string{"changed hash": "h2", "removed key": ""} {
		t.Run(name, func(t *testing.T) {
			f := newExFixture(t, exOpts{})
			a := f.seedText(t, "triage", replyRecipeText(replyCardScript), false)
			f.writeCard(t, a, "h1")
			id := f.pressCard(t, a, "h1")
			f.writeCard(t, a, rewrite)

			f.step(t, 1)
			r := f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
			if r.Error != "The card changed after the button was pressed; nothing ran. Press the button on the updated card." {
				t.Fatalf("error = %q", r.Error)
			}
			if steps := f.steps(t, id); len(steps) != 0 {
				t.Fatalf("steps = %d; want 0", len(steps))
			}
			if n := f.reportCount(t); n != 0 {
				t.Fatalf("reports = %d; want nothing committed", n)
			}
		})
	}
}

func TestExecutor_ReplyRunOnSameHashRewriteRuns(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seedText(t, "triage", replyRecipeText(replyCardScript), false)
	f.writeCard(t, a, "h1")
	id := f.pressCard(t, a, "h1")
	f.writeCard(t, a, "h1")
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if n := f.reportCount(t); n != 1 {
		t.Fatalf("reports = %d; want 1", n)
	}
}

// A payload from before content hashes (none in it) runs even when the
// card it names is gone.
func TestExecutor_ReplyRunWithoutHashRuns(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seedText(t, "triage", replyRecipeText(replyCardScript), false)
	raw, err := json.Marshal(db.ReplyPayload{Reply: db.ReplyTrigger{OutputID: 99999, Value: "later", Data: json.RawMessage(`null`)}})
	if err != nil {
		t.Fatal(err)
	}
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerReply, EventJSON: string(raw)})
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
}

// TestAuto08_ResumedReplyRunIsCheckedForChangedCard: the card check runs on
// a resume too — a card rewritten while the reply run waited ends the
// resumed run cancelled before any of its script replays.
func TestAuto08_ResumedReplyRunIsCheckedForChangedCard(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "triage", []string{"ask:owner", "inbox:reply"}, "inbox",
		`log("a"); `+resumeAskCall+`; return trigger.reply.value`)
	w.writeCard(t, a, "h1")
	id := w.pressCard(t, a, "h1")
	w.stopWhileWaiting(t, id)
	before := len(w.steps(t, id))
	// The run holds the automation's one slot while it waits, so no other
	// run can commit: write the changed-hash rewrite's effect directly.
	if _, err := w.d.Exec(`UPDATE automation_outputs SET content_hash = 'h2' WHERE id = ?`, w.cardID(t, a)); err != nil {
		t.Fatal(err)
	}

	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	r := w.waitEnded(t, id)
	if r.Status != db.RunCancelled || r.ErrorKind != db.ErrKindCancelled {
		t.Fatalf("run = %s/%s (%s); want cancelled/cancelled", r.Status, r.ErrorKind, r.Error)
	}
	if n := len(w.steps(t, id)); n != before {
		t.Fatalf("steps = %d; want %d (nothing replayed)", n, before)
	}
}
