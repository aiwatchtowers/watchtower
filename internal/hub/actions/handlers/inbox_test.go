package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/policy"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

var inboxNow = time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)

// actCall is one inbox.act that reached the fake tower's writer.
type actCall struct {
	origin tower.Origin
	req    api.ActRequest
}

// fakeAct is a tower registry with inbox.act registered as the real one is
// (its idempotency and grant by verb) over a writer that records each call
// and answers ok.
type fakeAct struct {
	mu    sync.Mutex
	calls []actCall
}

func (f *fakeAct) register(_ *db.DB, r *tower.Registry) {
	tower.Register(r, "inbox.act", func(_ context.Context, c *tower.Ctx, req api.ActRequest) (api.ActResult, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.calls = append(f.calls, actCall{origin: c.Origin, req: req})
		return api.ActResult{Already: false, RunID: 7}, nil
	}, tower.Spec{IdempotentFor: inboxfeed.ActIdempotent, GrantFor: inboxfeed.ActGrant})
}

func (f *fakeAct) taken() []actCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.calls)
}

// newInboxEnv is an env whose handlers call a tower over its database with
// the commands register adds.
func newInboxEnv(t *testing.T, register func(*db.DB, *tower.Registry)) *env {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), disp: actions.NewDispatcher()}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e.store = st
	e.device = secure.ID{0x0c, 0x0d}
	var r tower.Registry
	register(e.db, &r)
	tw := tower.New(e.db, tower.Options{Registry: &r, Now: func() time.Time { return inboxNow }, Sentence: inboxfeed.FaultSentence})
	e.h = Register(e.disp, Deps{DB: e.db, Store: st, Sessions: e.port, Tower: tw})
	return e
}

// linkGrants links the env's phone with the typing and permissions grants
// given.
func (e *env) linkGrants(typing, permissions bool) {
	e.t.Helper()
	err := e.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: e.device.String(), Name: "phone", Scope: "private", LinkedAt: time.Now(),
			TypingAllowed: typing, PermissionsAllowed: permissions,
		})
	})
	if err != nil {
		e.t.Fatal(err)
	}
}

var inboxRequestSeq atomic.Int64

// actRequest is an inbox_act action carrying the generated ActRequest.
func (e *env) actRequest(target string, verb api.ActVerb, p api.ActParams) actions.Request {
	e.t.Helper()
	b, err := json.Marshal(api.ActRequest{
		WriteParams: api.WriteParams{RequestID: fmt.Sprintf("00000000-0000-4000-8000-%012d", inboxRequestSeq.Add(1))},
		Target:      target, Verb: verb, Params: p,
	})
	if err != nil {
		e.t.Fatal(err)
	}
	var params map[string]any
	if err := json.Unmarshal(b, &params); err != nil {
		e.t.Fatal(err)
	}
	return e.request(inboxActKind, nil, params)
}

// everyVerb is one call of each inbox.act verb (and each approval verb).
var everyVerb = []struct {
	name   string
	target string
	verb   api.ActVerb
	params api.ActParams
}{
	{"read", "o1", api.ActRead, api.ActParams{ContentHash: "h1"}},
	{"done", "o1", api.ActDone, api.ActParams{ContentHash: "h1"}},
	{"dismiss", "o1", api.ActDismiss, api.ActParams{ContentHash: "h1"}},
	{"press_reply", "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: ptr(0), ActionKind: "reply"}},
	{"press_target", "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: ptr(1), ActionKind: "target"}},
	{"run_now", "o1", api.ActRunNow, api.ActParams{}},
	{"ref_done", "tracks", api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefDone}},
	{"ref_make_task", "tracks", api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefMakeTask, EventID: 2}},
	{"reply_propose", "messages", api.ActReplyPropose, api.ActParams{RefKind: api.RefInboxItem, RefID: 1, Text: "On it"}},
	{"approval_approve", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: "s"}},
	{"approval_reject", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalReject}},
	{"approval_retry", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry}},
	{"approval_dismiss", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}},
}

func ptr[T any](v T) *T { return &v }

// TestInboxAct_PerVerb: with every grant, each verb reaches the tower's
// writer once, as the hub with the phone's device, and answers applied with
// the act's result.
func TestInboxAct_PerVerb(t *testing.T) {
	for _, v := range everyVerb {
		t.Run(v.name, func(t *testing.T) {
			f := &fakeAct{}
			e := newInboxEnv(t, f.register)
			e.linkGrants(true, true)
			r := e.actRequest(v.target, v.verb, v.params)
			out := e.h.inboxAct(context.Background(), r)
			wantOutcome(t, out, wire.StatusApplied, "")
			calls := f.taken()
			if len(calls) != 1 {
				t.Fatalf("%d writer calls, want 1", len(calls))
			}
			c := calls[0]
			if c.origin.Transport != "hub" || c.origin.Device != e.device.String() || c.origin.Desktop != nil {
				t.Errorf("origin %+v, want the hub with the phone", c.origin)
			}
			if c.req.Verb != v.verb || c.req.Target != v.target {
				t.Errorf("request %+v", c.req)
			}
			if out.Result["run_id"] != float64(7) {
				t.Errorf("result %v, want the act's result", out.Result)
			}
		})
	}
}

// approvalEnv is an env over the real inbox.act with one pending proposal #1
// of a fake tool; applies run when the test calls them.
func approvalEnv(t *testing.T) (*env, *[]func()) {
	t.Helper()
	var later []func()
	e := newInboxEnv(t, func(d *db.DB, r *tower.Registry) {
		reg := tools.New(d)
		if err := reg.Register(approvalTool(t)); err != nil {
			t.Fatal(err)
		}
		inboxfeed.RegisterAct(r, inboxfeed.ActDeps{Registry: reg, Background: func(fn func()) { later = append(later, fn) }})
	})
	e.exec(`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'fake', '{"text":"hello"}', 'r', 'pending', '2026-11-16T09:00:00Z')`)
	return e, &later
}

// approvalTool is a write tool named fake whose apply answers at once.
func approvalTool(t *testing.T) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[struct {
		Text string `json:"text"`
	}](nil)
	if err != nil {
		t.Fatal(err)
	}
	return &tools.Tool{
		Name: "fake", Description: "test tool", InputSchema: schema, Access: tools.AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Revise: func(_ context.Context, _ *db.DB, _, patch json.RawMessage) (json.RawMessage, error) {
			return patch, nil
		},
		Execute: func(context.Context, *db.DB, tools.Call) (any, error) { return map[string]any{"ok": true}, nil },
	}
}

func approveRequest(e *env, args string) actions.Request {
	return e.actRequest("a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(args)})
}

// TestInboxAct_ApproveNeedsPermissions: an approve from a phone without the
// permissions grant is refused before the tower and the proposal stays
// pending; with it, the hub decides and the tool runs in the background.
func TestInboxAct_ApproveNeedsPermissions(t *testing.T) {
	e, later := approvalEnv(t)
	e.linkGrants(true, false)
	out := e.h.inboxAct(context.Background(), approveRequest(e, `{"text":"hello"}`))
	wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
	if out.Message != inboxPermissionsNotAllowedMsg {
		t.Errorf("message %q", out.Message)
	}
	if s := e.scalar(`SELECT status FROM agent_actions WHERE id = 1`); s != "pending" {
		t.Fatalf("row %s, want pending", s)
	}
	if n := e.count(`SELECT COUNT(*) FROM tower_requests`); n != 0 {
		t.Fatalf("%d ledger rows: the refusal reached the tower", n)
	}

	e.linkGrants(true, true)
	out = e.h.inboxAct(context.Background(), approveRequest(e, `{"text":"hello"}`))
	wantOutcome(t, out, wire.StatusApplied, "")
	if out.Result["status"] != "applying" {
		t.Fatalf("result %v, want applying", out.Result)
	}
	if len(*later) != 1 {
		t.Fatalf("%d background runs, want 1", len(*later))
	}
	(*later)[0]()
	if s := e.scalar(`SELECT status FROM agent_actions WHERE id = 1`); s != "applied" {
		t.Errorf("row %s, want applied", s)
	}
}

// TestInboxAct_ServerHostNamesTheAllowCommand: on a server hub the refusal
// names `watchtower hub allow` with the grant.
func TestInboxAct_ServerHostNamesTheAllowCommand(t *testing.T) {
	f := &fakeAct{}
	e := newInboxEnv(t, f.register)
	e.h.d.ServerHost = true
	e.linkGrants(false, false)
	out := e.h.inboxAct(context.Background(), e.actRequest("messages", api.ActReplyPropose,
		api.ActParams{RefKind: api.RefInboxItem, RefID: 1, Text: "ok"}))
	want := inboxTypingNotAllowedMsg + serverAllowSteps(e.device, "typing")
	if out.Message != want {
		t.Fatalf("message %q, want %q", out.Message, want)
	}
}

// TestInboxAct_ApproveWithStaleArgsIsArgsChanged: a proposal changed on the
// Mac is refused args_changed: failed conflict with the tower's sentence and
// its code.
func TestInboxAct_ApproveWithStaleArgsIsArgsChanged(t *testing.T) {
	e, _ := approvalEnv(t)
	e.linkGrants(true, true)
	out := e.h.inboxAct(context.Background(), approveRequest(e, `{"text":"other"}`))
	wantOutcome(t, out, wire.StatusFailed, reasonConflict)
	if out.Result["code"] != "args_changed" {
		t.Errorf("result %v, want code args_changed", out.Result)
	}
	if out.Message != "This proposal changed on the Mac — look again before approving." {
		t.Errorf("message %q", out.Message)
	}
	if s := e.scalar(`SELECT status FROM agent_actions WHERE id = 1`); s != "pending" {
		t.Errorf("row %s, want pending", s)
	}
}

// TestInboxAct_PatchIsRefusedFromThePhone: the Mac's Edit… is the Mac's: a
// patch from the phone is not_permitted and nothing is decided.
func TestInboxAct_PatchIsRefusedFromThePhone(t *testing.T) {
	e, later := approvalEnv(t)
	e.linkGrants(true, true)
	out := e.h.inboxAct(context.Background(), e.actRequest("a1", api.ActApproval, api.ActParams{
		ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(`{"text":"hello"}`),
		Patch: json.RawMessage(`{"text":"edited"}`),
	}))
	wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
	if out.Result["code"] != "not_permitted" {
		t.Errorf("result %v", out.Result)
	}
	if s := e.scalar(`SELECT status FROM agent_actions WHERE id = 1`); s != "pending" || len(*later) != 0 {
		t.Errorf("row %s, %d runs: the patch was decided", s, len(*later))
	}
}

// TestInboxAct_ReplyNeedsTyping: a Reply press and reply_propose need the
// typing grant; permissions alone is not enough.
func TestInboxAct_ReplyNeedsTyping(t *testing.T) {
	for _, v := range everyVerb {
		if v.name != "press_reply" && v.name != "reply_propose" {
			continue
		}
		t.Run(v.name, func(t *testing.T) {
			f := &fakeAct{}
			e := newInboxEnv(t, f.register)
			e.linkGrants(false, true)
			out := e.h.inboxAct(context.Background(), e.actRequest(v.target, v.verb, v.params))
			wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
			if out.Message != inboxTypingNotAllowedMsg || len(f.taken()) != 0 {
				t.Fatalf("message %q, %d writer calls", out.Message, len(f.taken()))
			}
		})
	}
}

// TestInboxAct_OtherVerbsNeedNoGrant: a phone with no grant still reads,
// marks done, dismisses, runs now, acts on a ref (not make_task) and
// rejects; every owner gesture needs its grant (ask #1349).
func TestInboxAct_OtherVerbsNeedNoGrant(t *testing.T) {
	needs := map[string]bool{
		"press_reply": true, "press_target": true, "ref_make_task": true, "reply_propose": true,
		"approval_approve": true, "approval_retry": true, "approval_dismiss": true,
	}
	for _, v := range everyVerb {
		t.Run(v.name, func(t *testing.T) {
			f := &fakeAct{}
			e := newInboxEnv(t, f.register)
			e.linkGrants(false, false)
			out := e.h.inboxAct(context.Background(), e.actRequest(v.target, v.verb, v.params))
			if needs[v.name] {
				wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
				return
			}
			wantOutcome(t, out, wire.StatusApplied, "")
			if len(f.taken()) != 1 {
				t.Fatalf("%d writer calls", len(f.taken()))
			}
		})
	}
}

// TestInboxAct_PolicyKeepsTheInboxOnTheMac (POLICY-03): under workbench_only
// no Inbox write runs from the phone.
func TestInboxAct_PolicyKeepsTheInboxOnTheMac(t *testing.T) {
	f := &fakeAct{}
	e := newInboxEnv(t, f.register)
	e.h.d.Policy = func() string { return policy.MobileWorkbenchOnly }
	e.linkGrants(true, true)
	out := e.h.inboxAct(context.Background(), e.actRequest("o1", api.ActRead, api.ActParams{ContentHash: "h1"}))
	wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
	if out.Message != inboxPolicyMsg || len(f.taken()) != 0 {
		t.Fatalf("message %q, %d writer calls", out.Message, len(f.taken()))
	}
}

// TestInboxAct_NoTowerIsNotSupported: a hub without the daemon's tower
// refuses the kind.
func TestInboxAct_NoTowerIsNotSupported(t *testing.T) {
	e := newEnv(t)
	out := e.h.inboxAct(context.Background(), e.actRequest("o1", api.ActRead, api.ActParams{}))
	wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
}

// TestInboxAct_UnreadableParamsAreInvalid: params that are no ActRequest
// never reach the tower.
func TestInboxAct_UnreadableParamsAreInvalid(t *testing.T) {
	f := &fakeAct{}
	e := newInboxEnv(t, f.register)
	e.linkGrants(true, true)
	out := e.h.inboxAct(context.Background(), e.request(inboxActKind, nil, map[string]any{"verb": 3}))
	wantOutcome(t, out, wire.StatusFailed, reasonInvalidParams)
	if len(f.taken()) != 0 {
		t.Fatal("unreadable params reached the writer")
	}
}

// TestInboxAct_NudgesInboxKinds: an applied inbox_act refreshes the cards
// and the folders' counts.
func TestInboxAct_NudgesInboxKinds(t *testing.T) {
	if got := inboxActOptions().Nudges; !slices.Equal(got, []string{"inbox_card", "inbox_folder"}) {
		t.Fatalf("nudges %v", got)
	}
}

// TestInboxActIdempotencyMatchesTheContract pins inbox_act's idempotency
// and grant per verb to the shared contract fixture's inbox_act_idempotency
// section (the phone reads the same rows): the dispatcher claims exactly
// the non-idempotent ones, and every verb is listed.
func TestInboxActIdempotencyMatchesTheContract(t *testing.T) {
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Rows []struct {
			Verb         api.ActVerb      `json:"verb"`
			ApprovalVerb api.ApprovalVerb `json:"approval_verb"`
			ActionKind   string           `json:"action_kind"`
			RefVerb      api.RefVerb      `json:"ref_verb"`
			Idempotent   bool             `json:"idempotent"`
			Grant        string           `json:"grant"`
		} `json:"inbox_act_idempotency"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	verbs, approvals := map[string]bool{}, map[string]bool{}
	claim := inboxActOptions().NonIdempotentFor
	for _, row := range f.Rows {
		params, err := json.Marshal(api.ActRequest{Target: "o1", Verb: row.Verb, Params: api.ActParams{
			ApprovalVerb: row.ApprovalVerb, ActionKind: row.ActionKind, RefVerb: row.RefVerb,
		}})
		if err != nil {
			t.Fatal(err)
		}
		idem, err := inboxfeed.ActIdempotent(params)
		if err != nil || idem != row.Idempotent || claim(params) == row.Idempotent {
			t.Errorf("%+v: idempotent %v (%v), claimed %v", row, idem, err, claim(params))
		}
		if grant, err := inboxfeed.ActGrant(params); err != nil || grant != row.Grant {
			t.Errorf("%+v: grant %q (%v)", row, grant, err)
		}
		verbs[string(row.Verb)] = true
		if row.ApprovalVerb != "" {
			approvals[string(row.ApprovalVerb)] = true
		}
	}
	for _, v := range api.ActVerb("").EnumValues() {
		if !verbs[v] {
			t.Errorf("verb %s is not in the contract", v)
		}
	}
	for _, v := range api.ApprovalVerb("").EnumValues() {
		if !approvals[v] {
			t.Errorf("approval verb %s is not in the contract", v)
		}
	}
}
