package db

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

const replyActionsJSON = `[{"label":"Backlog","kind":"reply","reply":"backlog","data":{"k":1}}]`

// seedRunnableAutomation makes a confirmed, enabled automation.
func seedRunnableAutomation(t *testing.T, d *DB, slug string) int64 {
	t.Helper()
	a := seedRunAutomation(t, d, slug, 1)
	if err := d.ConfirmAutomation(a, "h-"+slug, runTestNow); err != nil {
		t.Fatal(err)
	}
	if err := d.SetAutomationEnabled(a, true, runTestNow); err != nil {
		t.Fatal(err)
	}
	return a
}

// seedInboxCard stores an inbox output of automation a (on a finished manual
// run) with the given actions JSON, and returns its id.
func seedInboxCard(t *testing.T, d *DB, a int64, title, link, actions string) int64 {
	t.Helper()
	var run int64
	if err := d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'succeeded')
		RETURNING id`, a).Scan(&run); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := d.QueryRow(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, link, actions_json)
		VALUES (?, ?, 'inbox', ?, 'body', ?, ?) RETURNING id`, a, run, title, link, actions).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func countReplyRuns(t *testing.T, d *DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM automation_runs WHERE trigger = 'reply'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

type pressRecord struct {
	action, runID *int64
	at            *string
}

func readPress(t *testing.T, d *DB, outputID int64) pressRecord {
	t.Helper()
	var p pressRecord
	if err := d.QueryRow(`SELECT pressed_action, pressed_run_id, pressed_at FROM automation_outputs WHERE id = ?`,
		outputID).Scan(&p.action, &p.runID, &p.at); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPressInboxOutputAction_OnePressOneRun(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedInboxCard(t, d, a, "Bug A-1", "https://example.com/a-1", replyActionsJSON)
	now := runTestNow.Add(time.Minute)

	runID, err := d.PressInboxOutputAction(out, 0, now)
	if err != nil {
		t.Fatalf("press: %v", err)
	}
	r := wantAutomationRun(t, d, runID, RunQueued, "")
	if r.Trigger != TriggerReply || r.AutomationID != a || !r.QueuedAt.Equal(now) {
		t.Errorf("run = %+v; want a queued reply run of automation %d at %v", r, a, now)
	}
	var p ReplyPayload
	if err := json.Unmarshal([]byte(r.EventJSON), &p); err != nil {
		t.Fatalf("event_json %q: %v", r.EventJSON, err)
	}
	want := ReplyTrigger{OutputID: out, Action: 0, Value: "backlog", Data: json.RawMessage(`{"k":1}`),
		Card: ReplyCard{Title: "Bug A-1", Link: "https://example.com/a-1"}}
	if p.Reply.OutputID != want.OutputID || p.Reply.Action != want.Action || p.Reply.Value != want.Value ||
		string(p.Reply.Data) != string(want.Data) || p.Reply.Card != want.Card {
		t.Errorf("payload = %+v; want %+v", p.Reply, want)
	}

	press := readPress(t, d, out)
	if press.action == nil || *press.action != 0 || press.runID == nil || *press.runID != runID ||
		press.at == nil || *press.at != formatAutomationTime(now) {
		t.Errorf("press = %v/%v/%v; want 0/%d/%s", press.action, press.runID, press.at, runID, formatAutomationTime(now))
	}
	outs, err := d.ListAutomationOutputs("inbox", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(outs) != 1 || outs[0].PressedAction == nil || *outs[0].PressedAction != 0 ||
		outs[0].PressedRunID != runID || !sameAutomationTime(outs[0].PressedAt, now) {
		t.Errorf("listed output = %+v; want the press", outs)
	}
}

func TestPressInboxOutputAction_SecondPressRefused(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedInboxCard(t, d, a, "Bug", "", replyActionsJSON)
	runID, err := d.PressInboxOutputAction(out, 0, runTestNow)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.PressInboxOutputAction(out, 0, runTestNow.Add(time.Second))
	var already *AlreadyPressedError
	if !errors.As(err, &already) || already.RunID != runID {
		t.Fatalf("second press = %v; want AlreadyPressedError{%d}", err, runID)
	}
	if want := "Sent — run #" + jsonInt(runID); already.Error() != want {
		t.Errorf("Error() = %q; want %q", already.Error(), want)
	}
	if n := countReplyRuns(t, d); n != 1 {
		t.Errorf("reply runs = %d; want 1", n)
	}
}

func jsonInt(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestPressInboxOutputAction_ClosedCardRefused(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	for _, col := range []string{"done_at", "dismissed_at"} {
		out := seedInboxCard(t, d, a, "Bug", "", replyActionsJSON)
		if _, err := d.Exec(`UPDATE automation_outputs SET `+col+` = ? WHERE id = ?`, formatAutomationTime(runTestNow), out); err != nil {
			t.Fatal(err)
		}
		_, err := d.PressInboxOutputAction(out, 0, runTestNow)
		wantErrIs(t, col, err, ErrOutputClosed)
	}
	if n := countReplyRuns(t, d); n != 0 {
		t.Errorf("reply runs = %d; want 0", n)
	}
}

func TestPressInboxOutputAction_RefusesNonReplyAndBadIndex(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedInboxCard(t, d, a, "Bug", "", `[{"label":"Open","kind":"link","open":"https://example.com/x","primary":true}]`)
	_, err := d.PressInboxOutputAction(out, 0, runTestNow)
	wantErrIs(t, "a link action", err, ErrNotAReplyAction)
	_, err = d.PressInboxOutputAction(out, 4, runTestNow)
	wantErrIs(t, "index 4", err, ErrNotAReplyAction)
	_, err = d.PressInboxOutputAction(out, -1, runTestNow)
	wantErrIs(t, "index -1", err, ErrNotAReplyAction)
	_, err = d.PressInboxOutputAction(out+100, 0, runTestNow)
	wantErrIs(t, "a missing output", err, ErrOutputNotFound)

	var run int64
	if err := d.QueryRow(`SELECT run_id FROM automation_outputs WHERE id = ?`, out).Scan(&run); err != nil {
		t.Fatal(err)
	}
	var report int64
	if err := d.QueryRow(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, actions_json)
		VALUES (?, ?, 'report', 'r', 'b', ?) RETURNING id`, a, run, replyActionsJSON).Scan(&report); err != nil {
		t.Fatal(err)
	}
	_, err = d.PressInboxOutputAction(report, 0, runTestNow)
	wantErrIs(t, "a report output", err, ErrOutputNotFound)
	if n := countReplyRuns(t, d); n != 0 {
		t.Errorf("reply runs = %d; want 0", n)
	}
}

func TestPressInboxOutputAction_NotRunnableRefused(t *testing.T) {
	cases := map[string]string{
		"disabled":    `UPDATE automations SET enabled = 0 WHERE id = ?`,
		"unconfirmed": `UPDATE automations SET approval_hash = 'h-new' WHERE id = ?`,
		"parse error": `UPDATE automations SET parse_error = 'bad frontmatter' WHERE id = ?`,
		"removed":     `UPDATE automations SET removed_at = '2026-10-20T09:00:00Z' WHERE id = ?`,
	}
	for name, update := range cases {
		t.Run(name, func(t *testing.T) {
			d := openTestDB(t)
			a := seedRunnableAutomation(t, d, "triage")
			out := seedInboxCard(t, d, a, "Bug", "", replyActionsJSON)
			if _, err := d.Exec(update, a); err != nil {
				t.Fatal(err)
			}
			_, err := d.PressInboxOutputAction(out, 0, runTestNow)
			wantErrIs(t, name, err, ErrOutputAutomationNotRunnable)
			if n := countReplyRuns(t, d); n != 0 {
				t.Errorf("reply runs = %d; want 0", n)
			}
			if p := readPress(t, d, out); p.action != nil || p.runID != nil || p.at != nil {
				t.Errorf("press recorded: %+v", p)
			}
		})
	}
}

func TestPressInboxOutputAction_DataComesFromTheStoredRow(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedInboxCard(t, d, a, "Bug", "", `[{"label":"Later","kind":"reply","reply":"later"}]`)
	runID, err := d.PressInboxOutputAction(out, 0, runTestNow)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]map[string]json.RawMessage
	if err := json.Unmarshal([]byte(mustGetAutomationRun(t, d, runID).EventJSON), &raw); err != nil {
		t.Fatal(err)
	}
	if got := string(raw["reply"]["data"]); got != "null" {
		t.Errorf("data = %s; want null", got)
	}
}
