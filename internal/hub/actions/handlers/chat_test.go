package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/tools"
)

// fakeChatRunner runs the start transaction through a real store (so the
// lease, busy and refusals are the store's) and records the cancels.
type fakeChatRunner struct {
	store   *chatstore.Store
	runs    []chatstore.StartRequest
	cancels []string
	cancel  bool
}

func (f *fakeChatRunner) Turn(ctx context.Context, req chatengine.TurnRequest) (chatstore.Started, error) {
	f.runs = append(f.runs, req.StartRequest)
	return f.store.Start(ctx, req.StartRequest)
}

func (f *fakeChatRunner) Cancel(conv int64, turnID string) (bool, error) {
	f.cancels = append(f.cancels, fmt.Sprintf("%d/%s", conv, turnID))
	return f.cancel, nil
}

type fakeChatRequests struct{ feeds, pages, searches []string }

func (f *fakeChatRequests) WatchFeed(conv int64, purpose string, at time.Time) {
	f.feeds = append(f.feeds, fmt.Sprintf("%d/%s/%d", conv, purpose, at.Unix()))
}

func (f *fakeChatRequests) RequestPage(conv, before int64, at time.Time) {
	f.pages = append(f.pages, fmt.Sprintf("%d/%d/%d", conv, before, at.Unix()))
}

func (f *fakeChatRequests) RequestSearch(q string, at time.Time) {
	f.searches = append(f.searches, fmt.Sprintf("%s/%d", q, at.Unix()))
}

type chatEnv struct {
	*env
	runner   *fakeChatRunner
	requests *fakeChatRequests
	chat     *chatstore.Store
	files    string
	on       bool
	reason   string
	reg      *tools.Registry
	now      time.Time
}

// newChatEnv is an env whose handlers have chat on and the phone linked
// with the chat grant (on by default) and permissions.
func newChatEnv(t *testing.T, server bool) *chatEnv {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), disp: actions.NewDispatcher()}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e.store = st
	e.device = [16]byte{0x0a, 0x0b}
	c := &chatEnv{env: e, requests: &fakeChatRequests{}, files: filepath.Join(t.TempDir(), "chat_files"), on: true,
		now: time.Unix(1_800_000_000, 0)}
	c.chat = chatstore.New(e.db, db.ChatLeaseHub, "hub-1", chatstore.WithClock(func() time.Time { return c.now }))
	c.runner = &fakeChatRunner{store: c.chat, cancel: true}
	c.reg = tools.New(e.db)
	if err := c.reg.Register(tools.NewClaudeAIConnectorCall()); err != nil {
		t.Fatal(err)
	}
	schema, err := jsonschema.For[struct {
		Text string `json:"text"`
	}](nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.reg.Register(&tools.Tool{
		Name: "fake_send", Description: "a write a chat proposes", InputSchema: schema, Access: tools.AccessWrite, External: true,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { return "sent", nil },
	}); err != nil {
		t.Fatal(err)
	}
	e.h = Register(e.disp, Deps{
		DB: e.db, Store: st, Sessions: e.port, ServerHost: server, Clock: func() time.Time { return c.now },
		Chat: &ChatDeps{
			Available: func() (bool, string) { return c.on, c.reason },
			Runner:    c.runner, Store: c.chat, Requests: c.requests, Tools: c.reg, FilesDir: c.files,
		},
	})
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: e.device.String(), Name: "phone", Scope: "private", LinkedAt: c.now,
			StartSessionsAllowed: true, PermissionsAllowed: true})
	})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func (c *chatEnv) conversation() int64 {
	c.t.Helper()
	id, err := c.chat.NewConversation(context.Background(), nil, nil)
	if err != nil {
		c.t.Fatal(err)
	}
	return id
}

// run applies kind with params through its registered handler.
func (c *chatEnv) run(kind string, params map[string]any) actions.Outcome {
	c.t.Helper()
	r := c.request(kind, nil, params)
	r.Action.CreatedAt = wire.Time{Time: c.now.Add(-10 * time.Second)}
	fn, ok := c.h.chatKinds()[kind]
	if !ok {
		c.t.Fatalf("no chat kind %s", kind)
	}
	return fn(context.Background(), r)
}

func (c *chatEnv) setGrant(column string, on bool) {
	c.t.Helper()
	q := map[string]string{
		"chat_allowed":        `UPDATE devices SET chat_allowed = ?`,
		"permissions_allowed": `UPDATE devices SET permissions_allowed = ?`,
	}[column]
	if err := c.env.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(q, on)
		return err
	}); err != nil {
		c.t.Fatal(err)
	}
}

// chatKindParams are valid params of every chat kind (the gate refuses
// before they are read).
func chatKindParams(conv int64) map[string]map[string]any {
	return map[string]map[string]any{
		"chat_new":           {"client_key": "8F1C2B3A-0000-4000-8000-000000000001"},
		"chat_turn":          {"conversation_id": conv, "mode": "send", "text": "hi", "attachment_ids": []int64{}},
		"chat_cancel":        {"conversation_id": conv, "turn_id": "T"},
		"chat_feed_request":  {"conversation_id": conv, "purpose": "open"},
		"chat_page":          {"conversation_id": conv, "before_message_id": 5},
		"chat_search":        {"query": "payments"},
		"chat_read":          {"conversation_id": conv, "message_id": 1},
		"chat_branch_select": {"message_id": 1},
		"chat_manage":        {"conversation_id": conv, "op": "pin"},
		"chat_action_answer": {"action_id": 1, "decision": "reject", "args_sha256": "x"},
	}
}

func TestChatHandlers_RefuseWithoutChatGrant(t *testing.T) {
	for _, server := range []bool{false, true} {
		c := newChatEnv(t, server)
		conv := c.conversation()
		c.setGrant("chat_allowed", false)
		for kind, params := range chatKindParams(conv) {
			out := c.run(kind, params)
			wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
			if !strings.HasPrefix(out.Message, chatNotAllowedLead) {
				t.Errorf("%s: %q", kind, out.Message)
			}
			line := "watchtower hub allow " + c.device.String() + " chat"
			if server != strings.Contains(out.Message, line) {
				t.Errorf("%s on server=%v: %q", kind, server, out.Message)
			}
		}
		if len(c.runner.runs) != 0 || len(c.requests.feeds)+len(c.requests.pages)+len(c.requests.searches) != 0 {
			t.Fatal("a refused action reached the runner or the requests")
		}
		var n int
		if err := c.db.QueryRow(`SELECT COUNT(*) FROM chat_conversations`).Scan(&n); err != nil || n != 1 {
			t.Fatalf("chats after refusals: %d %v", n, err)
		}
	}
}

func TestChatHandlers_RefuseWhenNotOnRelay(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	for _, tc := range []struct{ reason, msg string }{
		{wire.ChatOffNotRelay, "Chat works over Relay"},
		{wire.ChatOffRunnerDown, "Chat can't run on your Mac right now"},
		{wire.ChatOffDesktopTooOld, "Update Watchtower on your Mac"},
		{wire.ChatOffPolicy, "Chat is turned off by your organization"},
	} {
		c.on, c.reason = false, tc.reason
		for kind, params := range chatKindParams(conv) {
			out := c.run(kind, params)
			wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
			if !strings.HasPrefix(out.Message, tc.msg) {
				t.Errorf("%s/%s: %q", tc.reason, kind, out.Message)
			}
		}
	}
	if len(c.runner.runs) != 0 {
		t.Fatal("a turn ran while chat was off")
	}
	// A hub with no chat at all (workbench_only: no ChatDeps) refuses too,
	// never dereferencing a missing runner.
	e := newEnv(t)
	for kind, params := range chatKindParams(conv) {
		r := e.request(kind, nil, params)
		out := e.h.chatKinds()[kind](context.Background(), r)
		wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
	}
}

func TestChatTurn_StartsAndAnswersWithIDs(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	out := c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": "hello",
		"attachment_ids": []int64{}, "routing": map[string]any{"mode": "pinned", "provider": "claude", "model": "opus"}})
	wantOutcome(t, out, wire.StatusApplied, "")
	if out.Result["turn_id"] == "" || out.Result["user_message_id"] == nil || out.Result["assistant_message_id"] == nil {
		t.Fatalf("result %+v", out.Result)
	}
	req := c.runner.runs[0]
	if req.ConversationID != conv || req.Text != "hello" || req.Routing == nil || req.Routing.Provider != "claude" {
		t.Fatalf("start request %+v", req)
	}
	// Refusals read from the params, before the runner.
	long := strings.Repeat("я", MaxChatText+1)
	wantOutcome(t, c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": long}), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "shout", "text": "x"}), wire.StatusFailed, reasonInvalidParams)
	if len(c.runner.runs) != 1 {
		t.Fatalf("runs %d", len(c.runner.runs))
	}
	// Exactly at the cap is fine for the handler (the store takes it).
	exact := strings.Repeat("a", MaxChatText)
	if _, refused := chatTurnRequest(c.request("chat_turn", nil, map[string]any{"conversation_id": conv, "mode": "send", "text": exact})); refused != nil {
		t.Fatalf("32 000 characters refused: %+v", refused)
	}
}

func TestChatTurn_BusyReturnsConversationBusy(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	// The Mac's turn holds the conversation's lease.
	mac := chatstore.New(c.db, db.ChatLeaseDesktop, "app-1", chatstore.WithClock(func() time.Time { return c.now }))
	if _, err := mac.Start(context.Background(), chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: "mac"}); err != nil {
		t.Fatal(err)
	}
	before := c.count(`SELECT COUNT(*) FROM chat_messages`)
	out := c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": "phone"})
	wantOutcome(t, out, wire.StatusFailed, reasonConversationBusy)
	if c.count(`SELECT COUNT(*) FROM chat_messages`) != before {
		t.Fatal("a busy turn wrote rows")
	}
	wantOutcome(t, c.run("chat_turn", map[string]any{"conversation_id": 9999, "mode": "send", "text": "x"}), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, c.run("chat_turn", map[string]any{"conversation_id": c.conversation(), "mode": "send", "text": "x",
		"attachment_ids": []int64{4242}}), wire.StatusFailed, reasonAttachmentMissing)
}

func TestChatCancel(t *testing.T) {
	c := newChatEnv(t, false)
	wantOutcome(t, c.run("chat_cancel", map[string]any{"conversation_id": 3, "turn_id": "T-1"}), wire.StatusApplied, "")
	c.runner.cancel = false
	wantOutcome(t, c.run("chat_cancel", map[string]any{"conversation_id": 3, "turn_id": "T-2"}), wire.StatusFailed, reasonNotFound)
	if strings.Join(c.runner.cancels, ",") != "3/T-1,3/T-2" {
		t.Fatalf("cancels %v", c.runner.cancels)
	}
}

func TestChatNew(t *testing.T) {
	c := newChatEnv(t, false)
	out := c.run("chat_new", map[string]any{"client_key": "K", "routing": map[string]any{"mode": "auto"}})
	wantOutcome(t, out, wire.StatusApplied, "")
	id, _ := out.Result["conversation_id"].(int64)
	if id <= 0 || c.count(`SELECT COUNT(*) FROM chat_conversations WHERE id = ? AND routing_mode = 'preferred_reserve'`, id) != 1 {
		t.Fatalf("result %+v", out.Result)
	}
	wantOutcome(t, c.run("chat_new", map[string]any{"client_key": "K", "project_id": 777}), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, c.run("chat_new", map[string]any{}), wire.StatusFailed, reasonInvalidParams)
}

func TestChatFeedRequest_ZeroRepublishesList(t *testing.T) {
	c := newChatEnv(t, false)
	out := c.run("chat_feed_request", map[string]any{"conversation_id": 0, "purpose": "open"})
	wantOutcome(t, out, wire.StatusApplied, "")
	if len(c.requests.feeds) != 0 {
		t.Fatalf("id 0 watched a feed: %v", c.requests.feeds)
	}
	// The applied answer's nudge publishes chat_list at once (PublishNow).
	found := false
	for _, k := range NudgeTable["chat_feed_request"] {
		found = found || k == "chat_list"
	}
	if !found {
		t.Fatal("chat_feed_request does not publish chat_list")
	}
}

func TestChatRequests_CountFromTheRequest(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	asked := c.now.Add(-10 * time.Second).Unix()
	wantOutcome(t, c.run("chat_feed_request", map[string]any{"conversation_id": conv}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_feed_request", map[string]any{"conversation_id": conv, "purpose": "prefetch"}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_page", map[string]any{"conversation_id": conv, "before_message_id": 40}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_search", map[string]any{"query": "pay"}), wire.StatusApplied, "")
	want := []string{fmt.Sprintf("%d/open/%d", conv, asked), fmt.Sprintf("%d/prefetch/%d", conv, asked)}
	if strings.Join(c.requests.feeds, ",") != strings.Join(want, ",") {
		t.Fatalf("feeds %v, want %v", c.requests.feeds, want)
	}
	if c.requests.pages[0] != fmt.Sprintf("%d/40/%d", conv, asked) || c.requests.searches[0] != fmt.Sprintf("pay/%d", asked) {
		t.Fatalf("pages %v searches %v", c.requests.pages, c.requests.searches)
	}
	wantOutcome(t, c.run("chat_feed_request", map[string]any{"conversation_id": 9999}), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, c.run("chat_feed_request", map[string]any{"conversation_id": conv, "purpose": "peek"}), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, c.run("chat_search", map[string]any{"query": strings.Repeat("q", MaxChatSearchQuery+1)}), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, c.run("chat_search", map[string]any{"query": "  "}), wire.StatusFailed, reasonInvalidParams)
}

func TestChatManage_RenameSetsUserTitle(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "rename", "title": "Q3 plan"}), wire.StatusApplied, "")
	if c.scalar(`SELECT title || '/' || title_source FROM chat_conversations WHERE id = ?`, conv) != "Q3 plan/user" {
		t.Fatal(c.scalar(`SELECT title || '/' || title_source FROM chat_conversations WHERE id = ?`, conv))
	}
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "pin"}), wire.StatusApplied, "")
	if c.scalar(`SELECT pinned FROM chat_conversations WHERE id = ?`, conv) != "1" {
		t.Fatal("not pinned")
	}
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "unpin"}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "archive"}), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": 9999, "op": "pin"}), wire.StatusFailed, reasonNotFound)
}

func TestChatManage_DeleteRemovesAttachmentFolder(t *testing.T) {
	c := newChatEnv(t, false)
	conv, other := c.conversation(), c.conversation()
	kind := chatstore.AttachmentKind{Class: "text", Mime: "text/plain"}
	for _, id := range []int64{conv, other} {
		if _, err := chatstore.SaveAttachment(context.Background(), c.db, c.files, id, "a.txt", kind, []byte("x"), 1); err != nil {
			t.Fatal(err)
		}
	}
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "delete"}), wire.StatusApplied, "")
	if c.count(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, conv) != 0 ||
		c.count(`SELECT COUNT(*) FROM chat_attachments WHERE conversation_id = ?`, conv) != 0 {
		t.Fatal("the chat or its rows survived")
	}
	if _, err := os.Stat(filepath.Join(c.files, "conversations", fmt.Sprint(conv))); !os.IsNotExist(err) {
		t.Fatalf("the chat's folder survived: %v", err)
	}
	if _, err := os.Stat(filepath.Join(c.files, "conversations", fmt.Sprint(other))); err != nil {
		t.Fatalf("another chat's folder went: %v", err)
	}
	wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "delete"}), wire.StatusFailed, reasonNotFound)
}

func TestChatReadAndBranch(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	st, err := c.chat.Start(context.Background(), chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: "q"})
	if err != nil {
		t.Fatal(err)
	}
	wantOutcome(t, c.run("chat_read", map[string]any{"conversation_id": conv, "message_id": st.AssistantMessageID}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_branch_select", map[string]any{"message_id": st.UserMessageID}), wire.StatusApplied, "")
	wantOutcome(t, c.run("chat_branch_select", map[string]any{"message_id": 99999}), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, c.run("chat_read", map[string]any{"conversation_id": 9999, "message_id": 1}), wire.StatusFailed, reasonNotFound)
}

// chatAction inserts a chat's pending action and returns its id and args
// hash.
func (c *chatEnv) chatAction(tool, status string) (int64, string) {
	c.t.Helper()
	args := `{"text":"hi"}`
	id, err := c.db.InsertAgentAction(db.AgentAction{Tool: tool, ArgsJSON: args, Surface: "chat", ConversationID: c.conversation(),
		TurnID: "T", Status: status})
	if err != nil {
		c.t.Fatal(err)
	}
	return id, tools.ArgsSHA256(args)
}

func TestChatActionAnswer_NeedsPermissions(t *testing.T) {
	c := newChatEnv(t, true)
	id, sum := c.chatAction("claude_ai_connector_call", "pending")
	c.setGrant("permissions_allowed", false)
	out := c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": sum})
	wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
	if !strings.Contains(out.Message, "watchtower hub allow "+c.device.String()+" permissions") {
		t.Fatalf("message %q", out.Message)
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "pending" {
		t.Fatal("decided without the permissions grant")
	}
	c.setGrant("permissions_allowed", true)
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "reject", "args_sha256": sum}), wire.StatusApplied, "")
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "rejected" {
		t.Fatal("not rejected")
	}
}

func TestChatActionAnswer_StaleHashRefused(t *testing.T) {
	c := newChatEnv(t, false)
	id, sum := c.chatAction("claude_ai_connector_call", "pending")
	out := c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": "deadbeef"})
	wantOutcome(t, out, wire.StatusFailed, reasonChanged)
	if out.Message != "The action changed — look again" {
		t.Fatalf("message %q", out.Message)
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "pending" {
		t.Fatal("a stale approve decided the row")
	}
	out = c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": sum})
	wantOutcome(t, out, wire.StatusApplied, "")
	c.h.WaitChat()
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id); got != "approved" {
		t.Fatalf("status %q: a session-applied call stays approved for its session", got)
	}
	// An action no session runs is run after the answer, as `actions
	// approve` runs it.
	send, sendSum := c.chatAction("fake_send", "pending")
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": send, "decision": "approve", "args_sha256": sendSum}),
		wire.StatusApplied, "")
	c.h.WaitChat()
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, send); got != "applied" {
		t.Fatalf("an approved action of no session: %q", got)
	}
}

func TestChatActionAnswer_DeadSessionRowIsFinal(t *testing.T) {
	c := newChatEnv(t, false)
	id, sum := c.chatAction("claude_ai_connector_call", "pending")
	// The chat's gate failed the row: its session died before an answer.
	if _, err := c.db.TransitionAgentAction(id, []string{"pending"}, "failed", "", "session ended before approval"); err != nil {
		t.Fatal(err)
	}
	for _, decision := range []string{"approve", "reject"} {
		out := c.run("chat_action_answer", map[string]any{"action_id": id, "decision": decision, "args_sha256": sum})
		wantOutcome(t, out, wire.StatusFailed, reasonNotPending)
		if out.Result["status"] != "failed" {
			t.Fatalf("%s: result %+v", decision, out.Result)
		}
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "failed" {
		t.Fatal("the final row changed")
	}
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": 4242, "decision": "reject"}), wire.StatusFailed, reasonNotFound)
}

// TestChatActionAnswer_ApplyRunsOnTheHubsBackground: the apply after an
// approve goes through ChatDeps.Spawn (the hub's stop waits for it); a hub
// that is stopping refuses it, and the approval stays for a later apply.
func TestChatActionAnswer_ApplyRunsOnTheHubsBackground(t *testing.T) {
	c := newChatEnv(t, false)
	var spawned []func()
	accept := true
	c.h.d.Chat.Spawn = func(work func()) bool {
		if accept {
			spawned = append(spawned, work)
		}
		return accept
	}
	id, sum := c.chatAction("fake_send", "pending")
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": sum}), wire.StatusApplied, "")
	if len(spawned) != 1 {
		t.Fatalf("spawned %d", len(spawned))
	}
	spawned[0]()
	c.h.WaitChat()
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id); got != "applied" {
		t.Fatalf("status %q", got)
	}
	accept = false
	id, sum = c.chatAction("fake_send", "pending")
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": sum}), wire.StatusApplied, "")
	c.h.WaitChat()
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id); got != "approved" {
		t.Fatalf("status %q: refused work must leave the approval", got)
	}
}

// discussChat inserts a Discuss chat (context_type set) with one message:
// not a main chat, so the phone never reaches it (iPhone chat spec §1).
func (c *chatEnv) discussChat() (conv, msg int64) {
	c.t.Helper()
	res, err := c.db.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at) VALUES ('Standup', 'meeting', '7', 1, 1)`)
	if err != nil {
		c.t.Fatal(err)
	}
	conv, _ = res.LastInsertId()
	res, err = c.db.Exec(`INSERT INTO chat_messages (conversation_id, role, text, status, created_at) VALUES (?, 'assistant', 'a', 'complete', 1)`, conv)
	if err != nil {
		c.t.Fatal(err)
	}
	msg, _ = res.LastInsertId()
	return conv, msg
}

func TestChatHandlers_DiscussChatIsNotFound(t *testing.T) {
	c := newChatEnv(t, true)
	conv, msg := c.discussChat()
	for name, tc := range map[string]struct {
		kind   string
		params map[string]any
	}{
		"feed request":  {"chat_feed_request", map[string]any{"conversation_id": conv, "purpose": "open"}},
		"page":          {"chat_page", map[string]any{"conversation_id": conv, "before_message_id": msg}},
		"read":          {"chat_read", map[string]any{"conversation_id": conv, "message_id": msg}},
		"branch select": {"chat_branch_select", map[string]any{"message_id": msg}},
		"pin":           {"chat_manage", map[string]any{"conversation_id": conv, "op": "pin"}},
		"rename":        {"chat_manage", map[string]any{"conversation_id": conv, "op": "rename", "title": "Mine"}},
		"delete":        {"chat_manage", map[string]any{"conversation_id": conv, "op": "delete"}},
	} {
		if out := c.run(tc.kind, tc.params); out.Status != wire.StatusFailed || out.Reason != reasonNotFound {
			t.Errorf("%s: %s/%s", name, out.Status, out.Reason)
		}
	}
	if len(c.requests.feeds) != 0 || len(c.requests.pages) != 0 {
		t.Fatalf("watched a Discuss chat: %v %v", c.requests.feeds, c.requests.pages)
	}
	if c.scalar(`SELECT title || '/' || pinned FROM chat_conversations WHERE id = ?`, conv) != "Standup/0" {
		t.Fatal("a Discuss chat was written")
	}
	wantOutcome(t, c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "a.txt", []byte("a"), -1)), wire.StatusFailed, reasonNotFound)
	if n := c.count(`SELECT COUNT(*) FROM chat_attachments`); n != 0 {
		t.Fatalf("%d attachment rows", n)
	}

	// An action of a Discuss chat is not answered from the phone.
	id, err := c.db.InsertAgentAction(db.AgentAction{Tool: "fake_send", ArgsJSON: `{"text":"hi"}`, Surface: "chat", ConversationID: conv,
		TurnID: "T", Status: "pending"})
	if err != nil {
		t.Fatal(err)
	}
	sum := tools.ArgsSHA256(`{"text":"hi"}`)
	for _, decision := range []string{"approve", "reject"} {
		wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": id, "decision": decision, "args_sha256": sum}),
			wire.StatusFailed, reasonNotFound)
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "pending" {
		t.Fatal("a Discuss chat's action was decided from the phone")
	}
}
