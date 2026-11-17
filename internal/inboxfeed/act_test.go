package inboxfeed

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

var actNow = time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)

type fakeArgs struct {
	Text   string `json:"text"`
	Reason string `json:"reason"`
}

// fakeTool is a write tool whose Execute runs run (nil: returns at once).
func fakeTool(t *testing.T, name string, surfaces []string, run func()) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[fakeArgs](nil)
	if err != nil {
		t.Fatal(err)
	}
	return &tools.Tool{
		Name: name, Description: "test tool", InputSchema: schema, Access: tools.AccessWrite, Surfaces: surfaces,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Revise: func(_ context.Context, _ *db.DB, _, patch json.RawMessage) (json.RawMessage, error) {
			return patch, nil
		},
		Execute: func(context.Context, *db.DB, tools.Call) (any, error) {
			if run != nil {
				run()
			}
			return map[string]any{"ok": true}, nil
		},
	}
}

const pendingArgs = `{"text":"hello","reason":"r"}`

// approvalRig seeds one pending proposal #1 of the fake tool.
func approvalRig(t *testing.T, run func()) (*db.DB, string, *tools.Registry) {
	t.Helper()
	d, path := seededAt(t, []string{`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'fake', '` + pendingArgs + `', 'r', 'pending', '2026-11-16T09:00:00Z')`})
	reg := tools.New(d)
	if err := reg.Register(fakeTool(t, "fake", nil, run)); err != nil {
		t.Fatal(err)
	}
	return d, path, reg
}

// actParams is one inbox.act request's params with a fresh request id.
func actParams(t testing.TB, target string, verb api.ActVerb, p api.ActParams) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(api.ActRequest{WriteParams: api.WriteParams{RequestID: newRequestID()},
		Target: target, Verb: verb, Params: p})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

var requestSeq atomic.Int64

func newRequestID() string {
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", 900000+requestSeq.Add(1))
}

func approveParams(t testing.TB, sha string) json.RawMessage {
	return actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: sha})
}

func actResult(t testing.TB, resp api.Response) api.ActResult {
	t.Helper()
	if resp.Status != api.StatusOK {
		t.Fatalf("status %s %+v, want ok", resp.Status, resp.Refusal)
	}
	var r api.ActResult
	if err := json.Unmarshal(resp.Result, &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func actionStatusOf(t testing.TB, d *db.DB, id int64) string {
	t.Helper()
	row, err := d.GetAgentAction(id)
	if err != nil || row == nil {
		t.Fatalf("action %d: %v", id, err)
	}
	return row.Status
}

func TestInboxAct_ApprovalArgsChangedIsRefused(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	tw := actTower(d, actNow, ActDeps{Registry: reg})
	resp := callAct(t, tw, approveParams(t, tools.ArgsSHA256(`{"text":"other","reason":"r"}`)), socket)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeArgsChanged {
		t.Fatalf("got %s %+v, want refused args_changed", resp.Status, resp.Refusal)
	}
	if resp.Refusal.Sentence != "This proposal changed on the Mac — look again before approving." {
		t.Errorf("sentence %q", resp.Refusal.Sentence)
	}
	if s := actionStatusOf(t, d, 1); s != "pending" {
		t.Errorf("row %s, want pending", s)
	}
}

func TestInboxAct_ApproveOverSocketWaitsForTheTool(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, _, reg := approvalRig(t, func() { time.Sleep(5 * time.Second) })
		tw := actTower(d, actNow, ActDeps{Registry: reg})
		start := time.Now()
		res := actResult(t, callAct(t, tw, approveParams(t, tools.ArgsSHA256(pendingArgs)), socket))
		if res.Status != "applied" {
			t.Fatalf("result %+v, want applied", res)
		}
		if waited := time.Since(start); waited != 5*time.Second {
			t.Errorf("answered after %v, want when the tool finished (5s)", waited)
		}
		if s := actionStatusOf(t, d, 1); s != "applied" {
			t.Errorf("row %s, want applied", s)
		}
	})
}

func TestInboxAct_ApproveWaitIsCappedAt120s(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, _, reg := approvalRig(t, func() { time.Sleep(10 * time.Minute) })
		tw := actTower(d, actNow, ActDeps{Registry: reg})
		start := time.Now()
		res := actResult(t, callAct(t, tw, approveParams(t, tools.ArgsSHA256(pendingArgs)), socket))
		if res.Status != "applying" {
			t.Fatalf("result %+v, want applying", res)
		}
		if waited := time.Since(start); waited != ApproveWaitCap {
			t.Errorf("answered after %v, want %v", waited, ApproveWaitCap)
		}
		// The tool goes on after the answer and lands its outcome.
		time.Sleep(10 * time.Minute)
		synctest.Wait()
		if s := actionStatusOf(t, d, 1); s != "applied" {
			t.Errorf("row %s, want applied", s)
		}
	})
}

func TestInboxAct_ApproveOverHubAnswersAfterTheDecision(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	var later []func()
	tw := actTower(d, actNow, ActDeps{Registry: reg, Background: func(fn func()) { later = append(later, fn) }})
	res := actResult(t, callAct(t, tw, approveParams(t, tools.ArgsSHA256(pendingArgs)), tower.Origin{Transport: "hub"}))
	if res.Status != "applying" {
		t.Fatalf("result %+v, want applying", res)
	}
	if s := actionStatusOf(t, d, 1); s != "approved" {
		t.Fatalf("row %s after the answer, want approved (decided, not run)", s)
	}
	if len(later) != 1 {
		t.Fatalf("%d background runs, want 1", len(later))
	}
	later[0]()
	if s := actionStatusOf(t, d, 1); s != "applied" {
		t.Errorf("row %s after the background run, want applied", s)
	}
}

func TestInboxAct_NoWriteTxHeldAcrossTheTool(t *testing.T) {
	running, release := make(chan struct{}), make(chan struct{})
	d, path, reg := approvalRig(t, func() {
		close(running)
		<-release
	})
	other := otherHandle(t, path)
	tw := actTower(d, actNow, ActDeps{Registry: reg})
	done := make(chan api.Response, 1)
	go func() { done <- callAct(t, tw, approveParams(t, tools.ArgsSHA256(pendingArgs)), socket) }()
	<-running
	// Another writer commits while the tool runs: no transaction of the call
	// holds the write lock across it.
	if _, err := other.Exec(`UPDATE automations SET name = name WHERE 0`); err != nil {
		t.Fatal(err)
	}
	tx, err := other.Begin()
	if err != nil {
		t.Fatalf("a second writer could not begin while the tool ran: %v", err)
	}
	if _, err := tx.Exec(`INSERT INTO reminders (note, remind_at) VALUES ('x', '2026-11-16T11:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("a second writer could not commit while the tool ran: %v", err)
	}
	close(release)
	if res := actResult(t, <-done); res.Status != "applied" {
		t.Errorf("result %+v, want applied", res)
	}
}

func TestInboxAct_PatchFromTheHubIsNotPermitted(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	tw := actTower(d, actNow, ActDeps{Registry: reg, Background: func(fn func()) { fn() }})
	patch := api.ActParams{ApprovalVerb: api.ApprovalApprove,
		ArgsSHA256: tools.ArgsSHA256(pendingArgs), Patch: json.RawMessage(`{"text":"edited","reason":"r"}`)}
	resp := callAct(t, tw, actParams(t, "a1", api.ActApproval, patch), tower.Origin{Transport: "hub"})
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeNotPermitted {
		t.Fatalf("got %s %+v, want refused not_permitted", resp.Status, resp.Refusal)
	}
	if s := actionStatusOf(t, d, 1); s != "pending" {
		t.Errorf("row %s, want pending", s)
	}
	// The Mac's Edit… over the socket lands the patch with the approval.
	resp = callAct(t, tw, actParams(t, "a1", api.ActApproval, patch), socket)
	if res := actResult(t, resp); res.Status != "applied" {
		t.Fatalf("result %+v, want applied", res)
	}
	row, _ := d.GetAgentAction(1)
	if row.ArgsJSON != `{"text":"edited","reason":"r"}` {
		t.Errorf("args %s, want the patch", row.ArgsJSON)
	}
}

func TestInboxAct_RejectAndRetryAndDismiss(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	tw := actTower(d, actNow, ActDeps{Registry: reg})
	reject := func() api.Response {
		return callAct(t, tw, actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalReject}), socket)
	}
	if res := actResult(t, reject()); res.Already {
		t.Errorf("first reject %+v, want a write", res)
	}
	if res := actResult(t, reject()); !res.Already {
		t.Errorf("second reject %+v, want already", res)
	}
	if _, err := d.Exec(`UPDATE agent_actions SET status = 'failed', error = 'boom' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	retry := actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry})
	if res := actResult(t, callAct(t, tw, retry, socket)); res.Status != "applied" {
		t.Errorf("retry %+v, want applied", res)
	}
	resp := callAct(t, tw, actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}), socket)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeChanged {
		t.Errorf("dismiss of a call that is not a session call: %s %+v, want changed", resp.Status, resp.Refusal)
	}
}

// replyRecipe is a recipe that reacts to its own Inbox buttons.
const replyRecipe = "---\nname: Triage\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n  - inbox:reply\n" +
	"outputs: [inbox]\n---\nA reply test recipe.\n\n```js\nreturn 1\n```\n"

func TestInboxAct_ReplyPressQueuesTheRun(t *testing.T) {
	r, err := automations.ParseRecipe("triage", []byte(replyRecipe), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	hash := automations.ApprovalHash(r)
	d := seeded(t, []string{
		fmt.Sprintf(`INSERT INTO automations (id, slug, scope, path, name, enabled, origin, recipe_text, approval_hash, confirmed_hash)
			VALUES (1, 'triage', 'personal', '/recipes/triage.md', 'Triage', 1, 'owner', '%s', '%s', '%s')`,
			escapeSQL(replyRecipe), hash, hash),
		`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`,
		`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, content_hash, actions_json)
			VALUES (1, 1, 1, 'inbox', 'Bug A-1', 'body', 'h1', '[{"label":"Backlog","kind":"reply","reply":"backlog"}]')`,
	})
	wakes := 0
	tw := actTower(d, actNow, ActDeps{Wake: func() { wakes++ }})
	index := 0
	p := actParams(t, "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: &index, ActionKind: "reply"})
	res := actResult(t, callAct(t, tw, p, socket))
	if res.RunID == 0 || res.Already {
		t.Fatalf("result %+v, want a queued run", res)
	}
	run, err := d.GetAutomationRun(res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != db.RunQueued || run.Trigger != db.TriggerReply {
		t.Errorf("run %s/%s, want a queued reply run", run.Status, run.Trigger)
	}
	if wakes != 1 {
		t.Errorf("%d wakes, want 1", wakes)
	}
	// The same request again answers its stored result; a new press is already.
	if again := actResult(t, callAct(t, tw, p, socket)); again != res {
		t.Errorf("resend %+v, want the stored %+v", again, res)
	}
	second := actResult(t, callAct(t, tw, actParams(t, "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: &index, ActionKind: "reply"}), socket))
	if !second.Already || second.RunID != res.RunID {
		t.Errorf("second press %+v, want already with run %d", second, res.RunID)
	}
	// A press naming another kind than the button's is not the button drawn
	// (its hub grant was decided for that kind).
	wrong := callAct(t, tw, actParams(t, "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: &index, ActionKind: "target"}), socket)
	if wrong.Status != api.StatusRefused || wrong.Refusal.Code != api.CodeChanged {
		t.Errorf("a press naming target on a Reply: %s %+v, want changed", wrong.Status, wrong.Refusal)
	}
	// A typed text is refused, never dropped.
	resp := callAct(t, tw, actParams(t, "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: &index, Text: "hi", ActionKind: "reply"}), socket)
	if resp.Status != api.StatusRefused {
		t.Errorf("a press with text answered %s, want refused", resp.Status)
	}
}

func escapeSQL(s string) string {
	out := []byte{}
	for i := range len(s) {
		if s[i] == '\'' {
			out = append(out, '\'')
		}
		out = append(out, s[i])
	}
	return string(out)
}

func TestInboxAct_RunNowIsNonIdempotent(t *testing.T) {
	d := seeded(t, []string{
		`INSERT INTO automations (id, slug, scope, path, name, enabled, origin) VALUES (1, 'digest', 'personal', '/r/d.md', 'Digest', 1, 'owner')`,
		`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`,
		`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, content_hash) VALUES (1, 1, 1, 'inbox', 'C', 'b', 'h1')`,
	})
	calls := 0
	runNow := func(_ context.Context, id int64) (int64, error) {
		calls++
		if id != 1 {
			t.Errorf("RunNow(%d), want automation 1", id)
		}
		return 42, nil
	}
	tw := actTower(d, actNow, ActDeps{RunNow: runNow})
	p := actParams(t, "o1", api.ActRunNow, api.ActParams{})
	if res := actResult(t, callAct(t, tw, p, socket)); res.RunID != 42 {
		t.Fatalf("result %+v, want run 42", res)
	}
	if res := actResult(t, callAct(t, tw, p, socket)); res.RunID != 42 || calls != 1 {
		t.Errorf("resend %+v after %d calls, want the stored run and one call", res, calls)
	}
	var state string
	if err := d.QueryRow(`SELECT state FROM tower_requests`).Scan(&state); err != nil || state != "done" {
		t.Errorf("ledger %q %v, want done", state, err)
	}
	// A refusal is recorded too: its resend answers the same refusal.
	tw = actTower(d, actNow, ActDeps{RunNow: func(context.Context, int64) (int64, error) {
		calls++
		return 0, &CannotRunError{Reason: "Digest is off — turn it on first"}
	}})
	p = actParams(t, "o1", api.ActRunNow, api.ActParams{})
	for range 2 {
		resp := callAct(t, tw, p, socket)
		if resp.Status != api.StatusRefused || resp.Refusal.Sentence != "Couldn't run it now: digest is off — turn it on first." {
			t.Errorf("got %s %+v", resp.Status, resp.Refusal)
		}
	}
	if calls != 2 {
		t.Errorf("%d RunNow calls, want the refused one once", calls)
	}
	// Without RunNow the verb is unsupported.
	resp := callAct(t, actTower(d, actNow, ActDeps{}), actParams(t, "o1", api.ActRunNow, api.ActParams{}), socket)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeUnsupported {
		t.Errorf("no RunNow: %s %+v, want unsupported", resp.Status, resp.Refusal)
	}
}

func TestInboxAct_ReplyProposeAndReplyWaiting(t *testing.T) {
	d := seeded(t, []string{`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, permalink, created_at)
		VALUES (1, '3:C1', '1.0', 'U1', 'mention', 'https://acme.slack.com/archives/C1/p1', '2026-11-16T07:00:00Z')`})
	reg := tools.New(d)
	schema, err := jsonschema.For[struct {
		Channel   string `json:"channel"`
		Text      string `json:"text"`
		Reason    string `json:"reason"`
		AccountID int64  `json:"account_id"`
	}](nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := reg.Register(&tools.Tool{Name: "send_slack_message", Description: "t", InputSchema: schema,
		Access: tools.AccessWrite, Surfaces: []string{tools.InboxSurface},
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { return nil, nil }}); err != nil {
		t.Fatal(err)
	}
	tw := actTower(d, actNow, ActDeps{Registry: reg})
	p := api.ActParams{RefKind: api.RefInboxItem, RefID: 1, Text: " On it "}
	actResult(t, callAct(t, tw, actParams(t, "messages", api.ActReplyPropose, p), socket))
	var tool, args, status string
	if err := d.QueryRow(`SELECT tool, args_json, status FROM agent_actions WHERE context_type = 'inbox_item' AND context_id = '1'`).
		Scan(&tool, &args, &status); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(args), &got); err != nil {
		t.Fatal(err)
	}
	if tool != "send_slack_message" || status != "pending" || got["text"] != "On it" ||
		got["reason"] != "Reply from Messages" || got["account_id"] != float64(3) {
		t.Errorf("proposal %s %s %s, want a pending Slack reply", tool, status, args)
	}
	resp := callAct(t, tw, actParams(t, "messages", api.ActReplyPropose, p), socket)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeReplyWaiting {
		t.Fatalf("second reply %s %+v, want reply_waiting", resp.Status, resp.Refusal)
	}
	if resp.Refusal.Sentence != "Couldn't send the reply: a reply already waits in Needs approval." {
		t.Errorf("sentence %q", resp.Refusal.Sentence)
	}
}

func TestActIdempotentAndGrantTables(t *testing.T) {
	index := 0
	cases := []struct {
		verb       api.ActVerb
		p          api.ActParams
		idempotent bool
		grant      string
	}{
		{api.ActRead, api.ActParams{}, true, ""},
		{api.ActDone, api.ActParams{}, true, ""},
		{api.ActDismiss, api.ActParams{}, true, ""},
		{api.ActPress, api.ActParams{Index: &index, ActionKind: "reply"}, false, "typing"},
		{api.ActPress, api.ActParams{Index: &index, ActionKind: "target"}, false, "permissions"},
		{api.ActPress, api.ActParams{Index: &index}, false, "permissions"},
		{api.ActRunNow, api.ActParams{}, false, ""},
		{api.ActReplyPropose, api.ActParams{Text: "hi"}, true, "typing"},
		{api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalApprove}, false, "permissions"},
		{api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry}, false, "permissions"},
		{api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}, true, "permissions"},
		{api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalReject}, true, ""},
	}
	// Every ref verb: guarded; only make_task (actions propose --approve)
	// needs a grant.
	for _, v := range api.RefVerb("").EnumValues() {
		grant := ""
		if api.RefVerb(v) == api.RefMakeTask {
			grant = "permissions"
		}
		cases = append(cases, struct {
			verb       api.ActVerb
			p          api.ActParams
			idempotent bool
			grant      string
		}{api.ActRef, api.ActParams{RefVerb: api.RefVerb(v)}, true, grant})
	}
	approvals := map[string]bool{}
	for _, c := range cases {
		if c.verb == api.ActApproval {
			approvals[string(c.p.ApprovalVerb)] = true
		}
	}
	for _, v := range api.ApprovalVerb("").EnumValues() {
		if !approvals[v] {
			t.Errorf("approval verb %s has no row", v)
		}
	}
	seen := map[api.ActVerb]bool{}
	for _, c := range cases {
		seen[c.verb] = true
		p := actParams(t, "o1", c.verb, c.p)
		idem, err := ActIdempotent(p)
		if err != nil || idem != c.idempotent {
			t.Errorf("%s %+v: idempotent %v %v, want %v", c.verb, c.p, idem, err, c.idempotent)
		}
		grant, err := ActGrant(p)
		if err != nil || grant != c.grant {
			t.Errorf("%s %+v: grant %q %v, want %q", c.verb, c.p, grant, err, c.grant)
		}
	}
	for _, v := range api.ActVerb("").EnumValues() {
		if !seen[api.ActVerb(v)] {
			t.Errorf("verb %s has no row", v)
		}
	}
}

// TestInboxAct_MakeTaskAppliesTheEventChange: ref make_task with ref_id =
// the track event (TrackActionPress's id) proposes, approves and applies
// apply_track_action in one press; a second press is already.
func TestInboxAct_MakeTaskAppliesTheEventChange(t *testing.T) {
	d := seeded(t, []string{
		`INSERT INTO targets (id, text, level, status, period_start, period_end) VALUES (3, 'Ship', 'day', 'todo', '2026-11-16', '2026-11-16')`,
		`INSERT INTO tracks (id, text, origin, linked_target_id) VALUES (1, 'Billing', 'custom', 3)`,
		`INSERT INTO track_events (id, track_id, summary, created_at, proposed_action, action_status)
			VALUES (2, 1, 'Done', '2026-11-16T09:00:00Z', '{"type":"update_status","status":"done"}', 'pending')`,
	})
	tw := actTower(d, actNow, fixtureDeps(t, d))
	p := api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefMakeTask, EventID: 2}
	if res := actResult(t, callAct(t, tw, actParams(t, "tracks", api.ActRef, p), socket)); res.Already || res.Status != "applied" {
		t.Fatalf("first press %+v, want applied", res)
	}
	var status, actionStatus string
	if err := d.QueryRow(`SELECT status FROM targets WHERE id = 3`).Scan(&status); err != nil || status != "done" {
		t.Errorf("task %q %v, want done", status, err)
	}
	if err := d.QueryRow(`SELECT action_status FROM track_events WHERE id = 2`).Scan(&actionStatus); err != nil || actionStatus != "applied" {
		t.Errorf("event %q %v, want applied", actionStatus, err)
	}
	if res := actResult(t, callAct(t, tw, actParams(t, "tracks", api.ActRef, p), socket)); !res.Already {
		t.Errorf("second press %+v, want already", res)
	}
	resp := callAct(t, actTower(d, actNow, ActDeps{}), actParams(t, "tracks", api.ActRef, p), socket)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeUnsupported {
		t.Errorf("no registry: %s %+v, want unsupported", resp.Status, resp.Refusal)
	}
}

// TestInboxAct_ApprovedCreateTrackStartsWatching: an approve (or retry) of
// create_track that applied starts its track's watch after the apply, as the
// Mac's startWatchingIfTrack; a watch that does not start is the result's
// error, and the approve stands.
func TestInboxAct_ApprovedCreateTrackStartsWatching(t *testing.T) {
	d := seeded(t, []string{`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'create_track', '` + pendingArgs + `', 'r', 'pending', '2026-11-16T09:00:00Z'),
		       (2, 'create_track', '` + pendingArgs + `', 'r', 'failed', '2026-11-16T09:00:00Z')`})
	reg := tools.New(d)
	tool := fakeTool(t, "create_track", nil, nil)
	tool.Execute = func(context.Context, *db.DB, tools.Call) (any, error) { return map[string]any{"track_id": 7}, nil }
	if err := reg.Register(tool); err != nil {
		t.Fatal(err)
	}
	var started []int64
	var startErr error
	tw := actTower(d, actNow, ActDeps{Registry: reg, StartWatch: func(_ context.Context, id int64) error {
		started = append(started, id)
		return startErr
	}})
	res := actResult(t, callAct(t, tw, actParams(t, "a1", api.ActApproval,
		api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(pendingArgs)}), socket))
	if res.Status != "applied" || res.Error != "" || len(started) != 1 || started[0] != 7 {
		t.Fatalf("approve %+v, started %v; want applied and track 7 watched", res, started)
	}
	startErr = fmt.Errorf("the watch recipe could not be written")
	res = actResult(t, callAct(t, tw, actParams(t, "a2", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry}), socket))
	if res.Status != "applied" || res.Error != "Approved, but the track is not watched yet: the watch recipe could not be written" {
		t.Errorf("retry %+v, want applied with the watch error", res)
	}
	if len(started) != 2 {
		t.Errorf("%d starts, want one per applied create_track", len(started))
	}
}
