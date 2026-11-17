package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
)

// faultyTurn is a queryTurn whose writes fail as set.
type faultyTurn struct {
	applyErr, finalizeErr error
	done                  bool
	finalized             []string
}

func (f *faultyTurn) Apply(chat.Event) error { return f.applyErr }
func (f *faultyTurn) Finalize(status string, _ *chatstore.Failure) error {
	f.finalized = append(f.finalized, status)
	return f.finalizeErr
}
func (f *faultyTurn) Done() bool { return f.done }

// saveErrors are the save_error lines written to out.
func saveErrors(t *testing.T, out *bytes.Buffer) []chat.Event {
	t.Helper()
	var got []chat.Event
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if line == "" {
			continue
		}
		var ev chat.Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		if ev.Type == chat.EventSaveError {
			got = append(got, ev)
		}
	}
	return got
}

// An embedded chat's failed reply write (`ai query --persist`) is a
// save_error, worded as `ai session --persist` words it, which the embedded
// chat shows under the thread — not a stderr line only.
func TestQueryPersist_FailedWritesEmitSaveError(t *testing.T) {
	prevTurn := aiFlagTurn
	aiFlagTurn = "t-embedded"
	t.Cleanup(func() { aiFlagTurn = prevTurn })

	var out bytes.Buffer
	turn := &faultyTurn{applyErr: errors.New("disk I/O error")}
	q := &queryPersist{turn: turn, out: chat.NewEventWriter(&out)}
	q.observer(context.Background())(chat.Event{Type: chat.EventTurnDone, TurnID: "t-embedded", Status: chat.StatusComplete})
	got := saveErrors(t, &out)
	if len(got) != 1 || got[0].TurnID != "t-embedded" || got[0].Message != "Couldn't save the reply: disk I/O error" {
		t.Fatalf("after a failed Apply: %+v", got)
	}

	// The stream left the turn open and its close-time finalize fails too.
	out.Reset()
	turn.finalizeErr = errors.New("database is locked")
	q.close()
	got = saveErrors(t, &out)
	if len(got) != 1 || got[0].Message != "Couldn't finalize the reply: database is locked" {
		t.Fatalf("after a failed close: %+v", got)
	}
	if len(turn.finalized) != 1 || turn.finalized[0] != chatstore.StatusPartial {
		t.Fatalf("finalized %v, want one partial", turn.finalized)
	}

	// A deleted conversation is not a save failure: nothing is shown.
	out.Reset()
	turn.applyErr = chatstore.ErrConversationGone
	q.observer(context.Background())(chat.Event{Type: chat.EventTextDelta, TurnID: "t-embedded", Text: "x"})
	if got := saveErrors(t, &out); len(got) != 0 {
		t.Fatalf("a gone conversation: %+v", got)
	}

	// Writes that succeed emit nothing.
	out.Reset()
	ok := &faultyTurn{done: true}
	q = &queryPersist{turn: ok, out: chat.NewEventWriter(&out)}
	q.observer(context.Background())(chat.Event{Type: chat.EventTurnDone, TurnID: "t-embedded", Status: chat.StatusComplete})
	q.close()
	if out.Len() != 0 {
		t.Fatalf("no failure, yet wrote %q", out.String())
	}
}
