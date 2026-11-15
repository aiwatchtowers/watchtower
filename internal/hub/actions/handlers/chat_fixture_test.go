package handlers

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"slices"
	"testing"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/wire"
)

type chatActionsFixture struct {
	Actions []struct {
		Name       string                     `json:"name"`
		Kind       string                     `json:"kind"`
		Params     map[string]json.RawMessage `json:"params"`
		ResultKeys []string                   `json:"result_keys"`
	} `json:"actions"`
}

// TestChatActionsFixture runs the phone's chat action params
// (WatchtowerKit/Tests/Fixtures/chat/actions.json, which the Kit's
// ChatActionParamsTests encode to) through the handlers: every case is
// applied with the result keys it names, and every chat kind has a case.
func TestChatActionsFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/chat/actions.json")
	if err != nil {
		t.Fatal(err)
	}
	var f chatActionsFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	c := newChatEnv(t, false)
	ctx := context.Background()
	if one, two := c.conversation(), c.conversation(); one != 1 || two != 2 {
		t.Fatalf("seed chats %d, %d", one, two)
	}
	st, err := c.chat.Start(ctx, chatstore.StartRequest{ConversationID: 1, Mode: chatstore.ModeSend, Text: "hello"})
	if err != nil || st.UserMessageID != 1 || st.AssistantMessageID != 2 {
		t.Fatalf("seed turn %+v %v", st, err)
	}
	if err := c.chat.Turn(st).Finalize(chatstore.StatusComplete, nil); err != nil {
		t.Fatal(err)
	}
	if id, err := c.db.InsertAgentAction(db.AgentAction{Tool: "fake_send", ArgsJSON: `{"text":"hi"}`, Surface: "chat",
		ConversationID: 1, TurnID: st.TurnID}); err != nil || id != 1 {
		t.Fatalf("seed action %d %v", id, err)
	}
	seen := map[string]bool{}
	for _, tc := range f.Actions {
		seen[tc.Kind] = true
		r := c.request(tc.Kind, nil, nil)
		r.Action.Params = tc.Params
		r.Action.CreatedAt = wire.Time{Time: c.now}
		out := c.h.chatKinds()[tc.Kind](ctx, r)
		if out.Status != wire.StatusApplied {
			t.Errorf("%s: %+v", tc.Name, out)
			continue
		}
		keys := slices.Sorted(maps.Keys(out.Result))
		if !slices.Equal(keys, tc.ResultKeys) && len(keys)+len(tc.ResultKeys) > 0 {
			t.Errorf("%s: result keys %v, want %v", tc.Name, keys, tc.ResultKeys)
		}
	}
	c.h.WaitChat()
	for kind := range c.h.chatKinds() {
		if !seen[kind] {
			t.Errorf("no fixture case of %s", kind)
		}
	}
}
