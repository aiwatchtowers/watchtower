package handlers

import (
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tools"
)

// The retry and dismiss decisions of chat_action_answer (mobile Inbox spec
// §12.9): inbox.act's own rules (inboxfeed.RetryAction, DismissAction).

// failedChatAction inserts a chat's failed action of tool with error msg.
func (c *chatEnv) failedChatAction(tool, msg string) int64 {
	c.t.Helper()
	id, _ := c.chatAction(tool, "pending")
	if _, err := c.db.TransitionAgentAction(id, []string{"pending"}, "failed", "", msg); err != nil {
		c.t.Fatal(err)
	}
	return id
}

func (c *chatEnv) answer(id int64, decision string) map[string]any {
	return map[string]any{"action_id": id, "decision": decision}
}

func TestChatActionAnswer_RetryRunsApplyAfterTheAnswer(t *testing.T) {
	c := newChatEnv(t, false)
	id := c.failedChatAction("fake_send", "jira: 503")
	out := c.run("chat_action_answer", c.answer(id, "retry"))
	wantOutcome(t, out, wire.StatusApplied, "")
	if out.Result["status"] != "approved" {
		t.Fatalf("result %+v", out.Result)
	}
	c.h.WaitChat()
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id); got != "applied" {
		t.Fatalf("status %q", got)
	}
}

func TestChatActionAnswer_RetryOfASessionCallIsRefused(t *testing.T) {
	c := newChatEnv(t, false)
	id := c.failedChatAction("claude_ai_connector_call", "session ended while the call ran; outcome unknown")
	out := c.run("chat_action_answer", c.answer(id, "retry"))
	wantOutcome(t, out, wire.StatusFailed, reasonNotSupported)
	if out.Message != "This runs only in its chat on the Mac" {
		t.Fatalf("message %q", out.Message)
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "failed" {
		t.Fatal("the session call moved")
	}
}

func TestChatActionAnswer_RetryOfAnAppliedRowIsNotPending(t *testing.T) {
	c := newChatEnv(t, false)
	id, sum := c.chatAction("fake_send", "pending")
	wantOutcome(t, c.run("chat_action_answer", map[string]any{"action_id": id, "decision": "approve", "args_sha256": sum}),
		wire.StatusApplied, "")
	c.h.WaitChat()
	out := c.run("chat_action_answer", c.answer(id, "retry"))
	wantOutcome(t, out, wire.StatusFailed, reasonNotPending)
	if out.Message != "Already approved" || out.Result["status"] != "applied" || out.Result["already"] != true {
		t.Fatalf("message %q result %+v", out.Message, out.Result)
	}
}

func TestChatActionAnswer_DismissOnlyAnUnknownOutcome(t *testing.T) {
	c := newChatEnv(t, false)
	plain := c.failedChatAction("fake_send", "jira: 503")
	out := c.run("chat_action_answer", c.answer(plain, "dismiss"))
	wantOutcome(t, out, wire.StatusFailed, reasonChanged)
	if c.scalar(`SELECT dismissed_at FROM agent_actions WHERE id = ?`, plain) != "" {
		t.Fatal("an ordinary failed row was dismissed")
	}
	unknown := c.failedChatAction("claude_ai_connector_call", "session ended while the call ran; outcome unknown")
	out = c.run("chat_action_answer", c.answer(unknown, "dismiss"))
	wantOutcome(t, out, wire.StatusApplied, "")
	if out.Result["dismissed"] != true || out.Result["already"] != false {
		t.Fatalf("result %+v", out.Result)
	}
	if c.scalar(`SELECT dismissed_at FROM agent_actions WHERE id = ?`, unknown) == "" {
		t.Fatal("not dismissed")
	}
	wantOutcome(t, c.run("chat_action_answer", c.answer(4242, "dismiss")), wire.StatusFailed, reasonNotFound)
}

func TestChatActionAnswer_DismissTwiceAnswersAlready(t *testing.T) {
	c := newChatEnv(t, false)
	id := c.failedChatAction("claude_ai_connector_call", "session ended while the call ran; outcome unknown")
	wantOutcome(t, c.run("chat_action_answer", c.answer(id, "dismiss")), wire.StatusApplied, "")
	first := c.scalar(`SELECT dismissed_at FROM agent_actions WHERE id = ?`, id)
	c.now = c.now.Add(1)
	out := c.run("chat_action_answer", c.answer(id, "dismiss"))
	wantOutcome(t, out, wire.StatusApplied, "")
	if out.Result["already"] != true || out.Result["dismissed"] != true {
		t.Fatalf("result %+v", out.Result)
	}
	if got := c.scalar(`SELECT dismissed_at FROM agent_actions WHERE id = ?`, id); got != first {
		t.Fatalf("written again: %q then %q", first, got)
	}
}

func TestChatActionAnswer_RetryAndDismissNeedPermissions(t *testing.T) {
	c := newChatEnv(t, true)
	failed := c.failedChatAction("fake_send", "jira: 503")
	unknown := c.failedChatAction("claude_ai_connector_call", "session ended while the call ran; outcome unknown")
	c.setGrant("permissions_allowed", false)
	wantOutcome(t, c.run("chat_action_answer", c.answer(failed, "retry")), wire.StatusFailed, reasonDeviceNotAllowed)
	wantOutcome(t, c.run("chat_action_answer", c.answer(unknown, "dismiss")), wire.StatusFailed, reasonDeviceNotAllowed)
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, failed) != "failed" ||
		c.scalar(`SELECT dismissed_at FROM agent_actions WHERE id = ?`, unknown) != "" {
		t.Fatal("decided without the permissions grant")
	}
}

func TestChatActionAnswer_RetryAndDismissMainChatsOnly(t *testing.T) {
	c := newChatEnv(t, false)
	conv, _ := c.discussChat()
	id, err := c.db.InsertAgentAction(db.AgentAction{Tool: "fake_send", ArgsJSON: `{"text":"hi"}`, Surface: "chat", ConversationID: conv,
		TurnID: "T", Status: "pending"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.db.TransitionAgentAction(id, []string{"pending"}, "failed", "", "jira: 503"); err != nil {
		t.Fatal(err)
	}
	for _, decision := range []string{"retry", "dismiss"} {
		wantOutcome(t, c.run("chat_action_answer", c.answer(id, decision)), wire.StatusFailed, reasonNotFound)
	}
	if c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id) != "failed" {
		t.Fatal("a Discuss chat's action was retried from the phone")
	}
}

// TestChatActionAnswer_RetryRacesTheInboxRetry: the chat's Retry twice and the
// Inbox's retry (inboxfeed.RetryAction, then Apply, as inbox.act runs it) on
// one failed row, all at once: Apply claims the row, so the tool runs once.
func TestChatActionAnswer_RetryRacesTheInboxRetry(t *testing.T) {
	c := newChatEnv(t, false)
	var runs atomic.Int32
	schema, err := jsonschema.For[struct {
		Text string `json:"text"`
	}](nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.reg.Register(&tools.Tool{
		Name: "fake_count", Description: "counts its runs", InputSchema: schema, Access: tools.AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { runs.Add(1); return "ok", nil },
	}); err != nil {
		t.Fatal(err)
	}
	var held []func()
	c.h.d.Chat.Spawn = func(work func()) bool { held = append(held, work); return true }
	id := c.failedChatAction("fake_count", "flaky")
	for range 2 {
		wantOutcome(t, c.run("chat_action_answer", c.answer(id, "retry")), wire.StatusApplied, "")
	}
	row, _, run, err := inboxfeed.RetryAction(c.db, c.reg, id, c.now)
	if err != nil || !run || row == nil {
		t.Fatalf("inbox retry: run %v err %v", run, err)
	}
	var wg sync.WaitGroup
	for _, work := range held {
		wg.Go(work)
	}
	wg.Go(func() { _, _ = c.reg.Apply(context.Background(), id) })
	wg.Wait()
	c.h.WaitChat()
	if got := runs.Load(); got != 1 {
		t.Fatalf("the tool ran %d times", got)
	}
	if got := c.scalar(`SELECT status FROM agent_actions WHERE id = ?`, id); got != "applied" {
		t.Fatalf("status %q", got)
	}
}
