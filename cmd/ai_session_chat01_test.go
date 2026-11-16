package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
)

// CHAT-01's row guards, moved from the Desktop's ChatViewModelTests with
// their names when the Swift writer (persistTurnStart, ChatTurnStore) was
// deleted (mobile Inbox Task 18): `ai session --persist` writes the rows
// now. The Swift tests of the same names check the Mac's side against a
// fake session. BEHAVIOR CHAT-01 — see docs/inventory/chat.md

func TestChat01UserMessageIsPersistedBeforeTheTurnIsSent(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	var userRowsAtSend []string
	backend.onTurn = func(chat.Command) {
		for _, row := range persistedRows(t, d, r.convID) {
			if row.Role == "user" {
				userRowsAtSend = append(userRowsAtSend, row.Text)
			}
		}
	}
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hello"})
	r.untilTurnEnd()
	r.close()
	assert.Equal(t, []string{"hello"}, userRowsAtSend)
}

func TestChat01NothingIsSentWhenTheMessageCannotBeSaved(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	_, err := d.Exec(`CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
		BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hello"})
	evs := r.untilTurnEnd()
	end := evs[len(evs)-1]
	assert.Equal(t, chat.EventError, end.Type, "the Mac gets the turn's error and keeps the text")
	assert.Equal(t, "t1", end.TurnID)
	r.close()
	turns, _ := backend.counts()
	assert.Zero(t, turns, "nothing reached the provider")
	assert.Empty(t, persistedRows(t, d, r.convID))
}

func TestChat01PartialTextSurvivesStop(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, _ := startPersistSession(t, backend)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	r.next(chat.EventTextDelta)
	r.send(chat.Command{Type: chat.CommandCancel})
	r.next(chat.EventTurnSaved)
	rows := persistedRows(t, openRunDB(t, r), r.convID)
	r.close()
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status})
}

// The session ends with the turn open (the app quit, the process told to
// stop): what streamed stays `partial`, and the next session's first turn
// replays the history from the database.
func TestChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes(t *testing.T) {
	backend := newPersistBackend()
	backend.hang = true
	r, _ := startPersistSession(t, backend)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	<-backend.delta
	r.send(chat.Command{Type: chat.CommandClose})
	require.NoError(t, <-r.done)
	rows := persistedRows(t, openRunDB(t, r), r.convID)
	require.Len(t, rows, 2)
	assert.Equal(t, []string{"partial ", "partial"}, []string{rows[1].Text, rows[1].Status})
}

func TestChat01RegenerateRowExistsUnderTheNewTurnIDWhenSent(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	first := r.untilTurnEnd()
	owner := first[indexOf(first, chat.EventStarted)].OwnerMessageID
	var atSend []persistedRow
	backend.onTurn = func(c chat.Command) {
		if c.TurnID == "t2" {
			atSend = persistedRows(t, d, r.convID)
		}
	}
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Mode: "regenerate", ParentID: owner})
	r.untilTurnEnd()
	r.close()
	require.Len(t, atSend, 3)
	reply := atSend[2]
	assert.Equal(t, []string{"assistant", "t2", "partial"}, []string{reply.Role, reply.TurnID, reply.Status})
	assert.Equal(t, owner, reply.ParentID.Int64)
	backend.mu.Lock()
	defer backend.mu.Unlock()
	assert.Equal(t, "t2", backend.turns[1].TurnID)
}

func TestChat01EditRowsExistUnderTheNewTurnIDWhenSent(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	first := r.untilTurnEnd()
	owner := first[indexOf(first, chat.EventStarted)].OwnerMessageID
	var atSend []persistedRow
	backend.onTurn = func(c chat.Command) {
		if c.TurnID == "t2" {
			atSend = persistedRows(t, d, r.convID)
		}
	}
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Mode: "edit", EditMessageID: owner, Text: "q2"})
	r.untilTurnEnd()
	r.close()
	require.Len(t, atSend, 4)
	assert.Equal(t, []string{"q2", ""}, []string{atSend[2].Text, atSend[3].Text})
	assert.Equal(t, []string{"t2", "t2"}, []string{atSend[2].TurnID, atSend[3].TurnID})
	assert.False(t, atSend[2].ParentID.Valid, "a sibling of the original owner message")
}

func TestChat01FailedSendKeepsTheOwnerMessageAnswered(t *testing.T) {
	backend := newPersistBackend()
	backend.failTurn = "t1"
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "q"})
	r.untilTurnEnd()
	r.next(chat.EventTurnSaved)
	var atSend []persistedRow
	backend.onTurn = func(c chat.Command) {
		if c.TurnID == "t2" {
			atSend = persistedRows(t, d, r.convID)
		}
	}
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t2", Text: "q2"})
	r.untilTurnEnd()
	r.close()
	require.Len(t, atSend, 4)
	roles := []string{atSend[0].Role, atSend[1].Role, atSend[2].Role, atSend[3].Role}
	statuses := []string{atSend[0].Status, atSend[1].Status, atSend[2].Status, atSend[3].Status}
	assert.Equal(t, []string{"user", "assistant", "user", "assistant"}, roles)
	assert.Equal(t, []string{"complete", "error", "complete", "partial"}, statuses)
	backend.mu.Lock()
	defer backend.mu.Unlock()
	assert.True(t, backend.turns[1].Replay, "a failed turn forces a replay")
}

func TestChat01LegacyUnansweredQuestionIsKeptBeforeTheNextTurn(t *testing.T) {
	backend := newPersistBackend()
	r, _ := startPersistSession(t, backend)
	d := openRunDB(t, r)
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, status) VALUES (?, 'user', 'old q', 1, 'complete')`, r.convID)
	require.NoError(t, err)
	question, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, question, r.convID)
	require.NoError(t, err)
	r.next(chat.EventSessionReady)
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "next"})
	r.untilTurnEnd()
	r.close()
	rows := persistedRows(t, d, r.convID)
	require.Len(t, rows, 4)
	assert.Equal(t, []string{"user", "assistant", "user", "assistant"}, []string{rows[0].Role, rows[1].Role, rows[2].Role, rows[3].Role})
	assert.Equal(t, question, rows[0].ID)
	assert.Equal(t, []string{"partial", ""}, []string{rows[1].Status, rows[1].Text})
	assert.Equal(t, "next", rows[2].Text)
}
