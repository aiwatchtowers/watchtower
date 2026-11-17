package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/hub/chatrun"
)

// TestDriverStopsWhenConversationDeleted is the CHAT-01 guard of the same
// name, moved from the Swift ChatTurnLeaseTests with the turn's writes
// (#1170 Task 18). Spec §7 "Conversation deleted during a Mac-run turn":
// the session finds the chat gone, stops the turn's writes and cancels it
// once; no orphan rows, steps or lease are left, `turn_saved` lets the Mac
// go, and the session ends so it is never reused (the Mac side is
// ChatTurnLeaseTests.testDriverStopsWhenConversationDeleted).
// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
func TestDriverStopsWhenConversationDeleted(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, tick, clock := startPersistSessionClock(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	r.next(chat.EventStarted)
	<-backend.delta
	settle(tick, clock)
	_, cancels := backend.counts()
	require.Zero(t, cancels)

	// Deleted from the phone: the cascade takes the rows and the lease.
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, r.convID)
	require.NoError(t, err)
	clock.advance(chatrun.HeartbeatEvery)
	// settle returns once the loop TOOK its second tick, not once it handled
	// it: that tick's lease watch may run after the delete above and find the
	// chat gone itself. Then the session ends at once and nothing reads a
	// further tick — so the next tick is offered only while the run is alive,
	// never waited for (a bare send hung CI for 20 min, PR #963).
	ended := false
	select {
	case tick <- clock.now():
	case err := <-r.done:
		ended = true
		require.NoError(t, err)
	}
	assert.Equal(t, "t1", r.next(chat.EventTurnSaved).TurnID, "the Mac lets the turn go")
	assert.Equal(t, chat.StatusInterrupted, r.next(chat.EventTurnDone).Status, "the turn is cancelled")
	// The session has no chat left to serve: it ends by itself, so the Mac
	// never reuses it. Every wait below ends with the run: the event stream
	// closes when the command returns (in process, no child to reap).
	for range r.events {
	}
	if !ended {
		require.NoError(t, <-r.done)
	}

	_, cancels = backend.counts()
	assert.Equal(t, 1, cancels, "once")
	assert.Empty(t, persistedRows(t, d, r.convID))
	var steps int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_turn_steps`).Scan(&steps))
	assert.Zero(t, steps, "no orphan step")
	lease, err := d.GetChatLease(r.convID)
	require.NoError(t, err)
	assert.Nil(t, lease)
}
