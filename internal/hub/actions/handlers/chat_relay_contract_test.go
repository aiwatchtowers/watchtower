package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"testing"

	"watchtower/internal/chatengine"
	"watchtower/internal/hub/wire"
)

// relayOps is internal/chatengine/testdata/relay_ops.json, read by the phone
// too (RelayChatClientTests.testRelayOpsContract).
type relayOps struct {
	Relay      map[string]string `json:"relay"`
	NotOnRelay []string          `json:"not_on_relay"`
	ManageOps  []string          `json:"chat_manage_ops"`
}

// chatAttachmentUpload is the relay's carrier of the engine's attach: a
// sealed upload the processor hands to IntakeChatAttachment, no action kind.
const chatAttachmentUpload = "chat_attachment"

func readRelayOps(t *testing.T) relayOps {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "chatengine", "testdata", "relay_ops.json"))
	if err != nil {
		t.Fatal(err)
	}
	var ops relayOps
	if err := json.Unmarshal(raw, &ops); err != nil {
		t.Fatal(err)
	}
	return ops
}

// TestChatRelayOps_EveryEngineOpIsRoutedOrListed pins which chat.sock
// operations travel over the relay (final review I2): every op the engine
// registers is either carried by a hub chat kind or on the not-on-relay list
// the phone answers itself, never both and never neither.
func TestChatRelayOps_EveryEngineOpIsRoutedOrListed(t *testing.T) {
	c := newChatEnv(t, false)
	ops := readRelayOps(t)
	var listed []string
	for op, kind := range ops.Relay {
		listed = append(listed, op)
		if kind == chatAttachmentUpload {
			continue
		}
		if _, ok := c.h.chatKinds()[kind]; !ok {
			t.Errorf("engine op %s is routed to %s, which is no hub chat kind", op, kind)
		}
	}
	for _, op := range ops.NotOnRelay {
		if _, both := ops.Relay[op]; both {
			t.Errorf("%s is both routed and not on the relay", op)
		}
		listed = append(listed, op)
	}
	sort.Strings(listed)
	if got := c.runner.Ops(); !reflect.DeepEqual(got, listed) {
		t.Fatalf("engine ops %v, relay contract %v: a new op goes in relay_ops.json's relay or not_on_relay", got, listed)
	}
}

// TestChatRelayOps_TurnParamsReachTheEngine: the relay's chat_turn reads its
// params with the engine's own decoder, so every turn field chat.sock
// carries — screen_context and artifact_comment_ids included — reaches the
// engine from the phone as it would from the Mac.
func TestChatRelayOps_TurnParamsReachTheEngine(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	params := map[string]any{
		"conversation_id": conv, "mode": "send", "text": "hi @Alice", "attachment_ids": []int64{},
		"routing": map[string]any{"mode": "pinned", "provider": "claude", "model": "opus"}, "client_key": "K-9",
		"compose":              map[string]any{"skill": "weekly-report", "mentions": []any{map[string]any{"kind": "person", "id": "U1", "label": "Alice"}}},
		"screen_context":       "<screen>Home</screen>",
		"artifact_comment_ids": []int64{},
	}
	wantOutcome(t, c.run("chat_turn", params), wire.StatusApplied, "")
	if len(c.runner.turns) != 1 {
		t.Fatalf("turns %d", len(c.runner.turns))
	}
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	want, err := chatengine.DecodeTurn(raw)
	if err != nil {
		t.Fatal(err)
	}
	got := c.runner.turns[0]
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("relay turn %+v, chat.sock turn %+v", got, want)
	}
	if got.ScreenContext != "<screen>Home</screen>" || got.ClientKey != "K-9" || got.Compose == nil || got.Routing == nil {
		t.Fatalf("a turn field was dropped on the relay: %+v", got)
	}
}

// TestChatRelayOps_ManageOpsOnTheRelay: the hub's chat_manage takes exactly
// the listed ops from the phone (use_preferred among them, unified chat
// T17); the chat.sock-only ops are refused invalid_params.
func TestChatRelayOps_ManageOpsOnTheRelay(t *testing.T) {
	c := newChatEnv(t, false)
	ops := readRelayOps(t)
	if !slices.Contains(ops.ManageOps, chatengine.ManageUsePreferred) {
		t.Fatalf("chat_manage_ops %v lacks use_preferred", ops.ManageOps)
	}
	for _, op := range ops.ManageOps {
		if op == chatengine.ManageDelete {
			continue // applied by TestChatManage_DeleteRemovesAttachmentFolder; it would remove the chat here
		}
		params := map[string]any{"conversation_id": c.conversation(), "op": op, "title": "x"}
		if out := c.run("chat_manage", params); out.Status != wire.StatusApplied {
			t.Errorf("%s: %s %s", op, out.Status, out.Reason)
		}
	}
	for _, op := range []string{chatengine.ManageMove, chatengine.ManageArchive, chatengine.ManageDiscard} {
		if slices.Contains(ops.ManageOps, op) {
			t.Errorf("%s is chat.sock only", op)
		}
		wantOutcome(t, c.run("chat_manage", map[string]any{"conversation_id": c.conversation(), "op": op}), wire.StatusFailed, reasonInvalidParams)
	}
}
