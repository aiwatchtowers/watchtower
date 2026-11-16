package actions

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"reflect"
	"slices"
	"testing"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The chat kinds' place in the canonical lists (iPhone chat spec §4.5).
func TestChatKindsAreClaimedAndChatTurnEchoesReceived(t *testing.T) {
	for _, k := range []string{"chat_new", "chat_turn", "chat_action_answer", "chat_manage"} {
		if !slices.Contains(NonIdempotentKinds, k) {
			t.Errorf("%s is not claimed begun", k)
		}
	}
	for _, k := range []string{"chat_cancel", "chat_feed_request", "chat_page", "chat_search", "chat_read", "chat_branch_select"} {
		if slices.Contains(NonIdempotentKinds, k) {
			t.Errorf("%s is claimed begun: a repeat must re-run", k)
		}
	}
	if !slices.Contains(ReceivedEchoKinds, "chat_turn") {
		t.Error("chat_turn gets no received echo")
	}
}

// TestChatTurn_RepeatReplaysEcho: the same chat_turn read again (a resync,
// the phone's retry of the record) gets the stored echo with its ids; the
// turn never runs twice.
func TestChatTurn_RepeatReplaysEcho(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		calls := 0
		w.disp.Register("chat_turn", func(context.Context, Request) Outcome {
			calls++
			return Outcome{Status: wire.StatusApplied, Result: map[string]any{
				"user_message_id": 11, "assistant_message_id": 12, "turn_id": "T-1"}}
		}, KindOptions{})
		seq := w.act("chat_turn")
		w.settle()
		if err := w.phone.WriteCopy(seq); err != nil {
			t.Fatal(err)
		}
		if r := w.pass(); r.Repeats != 1 {
			t.Fatalf("pass %+v, want one repeat", r)
		}
		w.settle()
		if calls != 1 {
			t.Fatalf("the turn ran %d times", calls)
		}
		e := w.wantEcho(seq, wire.StatusApplied, "")
		if string(e.Result["turn_id"]) != `"T-1"` || string(e.Result["assistant_message_id"]) != "12" {
			t.Fatalf("echo result %v", e.Result)
		}
	})
}

// TestChatTurn_CrashMidApplyIsOutcomeUnknown: a hub that stops while a
// chat_turn applies answers outcome_unknown once and never starts it again.
func TestChatTurn_CrashMidApplyIsOutcomeUnknown(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		calls := 0
		w.disp.Register("chat_turn", func(context.Context, Request) Outcome {
			calls++
			panic("the hub stops mid-apply")
		}, KindOptions{})
		seq := w.act("chat_turn")
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("the handler's panic did not stop the pass")
				}
			}()
			_, _ = w.proc.Pass(w.ctx)
		}()
		if phase, _, _, err := w.st.Phase(w.ledgerKey(seq)); err != nil || phase != state.PhaseBegun {
			t.Fatalf("after the crash: phase %q, %v", phase, err)
		}
		w.settle()
		if calls != 1 {
			t.Fatalf("the turn ran %d times", calls)
		}
		w.wantEcho(seq, wire.StatusFailed, reasonOutcomeUnknown)
	})
}

// chatUploadWorld installs a scripted chat attachment intake.
type chatUploadWorld struct {
	*world
	next  Outcome
	calls []ChatAttachmentIntake
}

func newChatUploadWorld(t *testing.T) *chatUploadWorld {
	w := &chatUploadWorld{world: newWorld(t, transport.KindRelay)}
	w.disp.SetChatAttachments(func(_ context.Context, in ChatAttachmentIntake) Outcome {
		w.calls = append(w.calls, in)
		return w.next
	}, []string{"chat_feed"})
	return w
}

func (w *chatUploadWorld) upload(id string, device *secure.ID) {
	w.t.Helper()
	m := map[string]any{"upload_id": id, "conversation_id": 7, "name": "notes.md", "mime": "text/markdown",
		"size": 6, "status": "pending"}
	if device != nil {
		m["device_id"] = device.String()
	}
	body, _ := json.Marshal(m)
	if _, err := w.phone.WriteChatAttachment(id, body, nil, nil); err != nil {
		w.t.Fatal(err)
	}
}

func (w *chatUploadWorld) echo(id string) map[string]any {
	w.t.Helper()
	w.sync(w.phone)
	e, ok := w.phone.ChatUploadEchoes[id]
	if !ok {
		w.t.Fatalf("no echo of chat upload %s", id)
	}
	return e
}

func TestChatAttachmentUploadIsStoredOnceAndEchoed(t *testing.T) {
	w := newChatUploadWorld(t)
	var nudged []string
	w.proc.cfg.Nudge = func(k []string) { nudged = append(nudged, k...) }
	w.next = Outcome{Status: wire.StatusApplied, Result: map[string]any{"attachment_id": int64(42)}}
	id := w.phone.ID()
	w.upload("u-1", &id)
	w.pass()
	e := w.echo("u-1")
	if e["status"] != wire.StatusApplied || e["attachment_id"] != float64(42) || e["name"] != "notes.md" || e["error_message"] != nil {
		t.Fatalf("echo %v", e)
	}
	if len(w.calls) != 1 || w.calls[0].ConversationID != 7 || w.calls[0].Name != "notes.md" || w.calls[0].Device != id ||
		w.calls[0].Size != 6 || w.calls[0].Mime != "text/markdown" {
		t.Fatalf("intake calls %+v", w.calls)
	}
	if !slices.Equal(nudged, []string{"chat_feed"}) {
		t.Fatalf("nudges %v", nudged)
	}
	// The phone writes the same upload again: the stored answer, no second file.
	w.upload("u-1", &id)
	w.pass()
	if len(w.calls) != 1 {
		t.Fatalf("a stored upload was taken again: %d calls", len(w.calls))
	}
	if e := w.echo("u-1"); e["attachment_id"] != float64(42) {
		t.Fatalf("replayed echo %v", e)
	}
}

func TestChatAttachmentUploadRefusalsAndRetry(t *testing.T) {
	w := newChatUploadWorld(t)
	w.next = Outcome{Status: wire.StatusFailed, Reason: "not_found", Message: "The file did not reach your Mac. Send it again."}
	id := w.phone.ID()
	w.upload("u-2", &id)
	w.pass()
	e := w.echo("u-2")
	if e["status"] != wire.StatusFailed || e["reason"] != "not_found" || e["attachment_id"] != nil {
		t.Fatalf("echo %v", e)
	}
	// Retry: the phone writes the failed upload again; it is tried again.
	w.next = Outcome{Status: wire.StatusApplied, Result: map[string]any{"attachment_id": int64(5)}}
	w.upload("u-2", &id)
	w.pass()
	if e := w.echo("u-2"); e["status"] != wire.StatusApplied || len(w.calls) != 2 {
		t.Fatalf("retry echo %v, %d calls", e, len(w.calls))
	}
	// Another phone's id in the payload: refused, the intake never runs.
	other := secure.ID{0x77}
	w.upload("u-3", &other)
	w.pass()
	if e := w.echo("u-3"); e["status"] != wire.StatusFailed || e["error_message"] != notLinkedMessage {
		t.Fatalf("echo %v", e)
	}
	if len(w.calls) != 2 {
		t.Fatal("the intake ran for another phone's upload")
	}
}

// TestChatAttachmentUploadMatchesTheKitFixture: the upload payload of the
// shared chat fixture (WatchtowerKit/Tests/Fixtures/chat/actions.json) is
// read as the phone writes it, and the hub's echoes carry the fixture's
// keys and values (the device and hub ids are this test's).
func TestChatAttachmentUploadMatchesTheKitFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/chat/actions.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Upload struct {
			Kind, RecordIDPrefix string
			Payload              map[string]any `json:"payload"`
			EchoApplied          map[string]any `json:"echo_applied"`
			EchoFailed           map[string]any `json:"echo_failed"`
		} `json:"upload"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if f.Upload.Kind != KindChatAttachment {
		t.Fatalf("kind %q", f.Upload.Kind)
	}
	for _, tc := range []struct {
		out  Outcome
		want map[string]any
	}{
		{Outcome{Status: wire.StatusApplied, Result: map[string]any{"attachment_id": int64(1)}}, f.Upload.EchoApplied},
		{Outcome{Status: wire.StatusFailed, Reason: "not_found", Message: "The file did not reach your Mac. Send it again."}, f.Upload.EchoFailed},
	} {
		w := newChatUploadWorld(t)
		w.next = tc.out
		p := maps.Clone(f.Upload.Payload)
		p["device_id"] = w.phone.ID().String()
		p["hub_id"] = w.proc.cfg.Keys.HubID().String()
		id := p["upload_id"].(string)
		body, _ := json.Marshal(p)
		if _, err := w.phone.WriteChatAttachment(id, body, nil, nil); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if len(w.calls) != 1 || w.calls[0].ConversationID != 2 || w.calls[0].Name != "notes.md" || w.calls[0].Size != 6 {
			t.Fatalf("intake %+v", w.calls)
		}
		got := w.echo(id)
		want := maps.Clone(tc.want)
		want["device_id"], want["hub_id"] = p["device_id"], p["hub_id"]
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("echo %v\nwant %v", got, want)
		}
	}
}
