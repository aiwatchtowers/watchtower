package cmd

import (
	"context"

	"watchtower/internal/chat"
)

// aiSessionFlagStubReply (hidden, tests only): the session answers every
// turn with this text at once instead of calling a provider. The Desktop's
// chat timing test (ChatPersistTimingTests) measures the start path with it;
// nothing else passes it.
var aiSessionFlagStubReply string

func init() {
	f := aiSessionCmd.Flags()
	f.StringVar(&aiSessionFlagStubReply, "test-stub-reply", "", "tests only: answer every turn with this text, no provider")
	_ = f.MarkHidden("test-stub-reply")
}

// stubSessionBackend answers each turn with one text delta and turn_done.
type stubSessionBackend struct{ reply string }

func (stubSessionBackend) Start(context.Context) (string, error) { return "", nil }

func (b stubSessionBackend) Turn(_ context.Context, c chat.Command, emit func(chat.Event)) error {
	emit(chat.Event{Type: chat.EventTurnStart, TurnID: c.TurnID})
	emit(chat.Event{Type: chat.EventTextDelta, TurnID: c.TurnID, Text: b.reply})
	emit(chat.Event{Type: chat.EventTurnDone, TurnID: c.TurnID, Status: chat.StatusComplete})
	return nil
}

func (stubSessionBackend) Cancel() error { return nil }
func (stubSessionBackend) Close() error  { return nil }
