package chatengine

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatstore"
)

// The Go homes of the Mac's CHAT-01 guards that went with its Swift turn
// writer (unified chat T8; mapping in docs/inventory/chat.md).

// activePath is the conversation's messages, oldest first: role, status and
// text of each.
func activePath(t *testing.T, g *rig, conv int64) (roles, statuses, texts []string) {
	t.Helper()
	rows, err := g.d.Query(`SELECT role, status, text FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var role, status, text string
		require.NoError(t, rows.Scan(&role, &status, &text))
		roles = append(roles, role)
		statuses = append(statuses, status)
		texts = append(texts, text)
	}
	require.NoError(t, rows.Err())
	return roles, statuses, texts
}

// TestChat01_UnsavableOwnerRowSendsNothing: when the owner's row cannot be
// written (a trigger aborts it), the turn is refused, nothing is stored and
// no session gets a turn (the Swift twin was
// testChat01NothingIsSentWhenTheMessageCannotBeSaved; the draft staying in
// the composer is ChatUI's testRefusedSendRestoresDraft) (BEHAVIOR CHAT-01 —
// see docs/inventory/chat.md).
func TestChat01_UnsavableOwnerRowSendsNothing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		_, err := g.d.Exec(`CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
			BEGIN SELECT RAISE(ABORT, 'boom'); END`)
		require.NoError(t, err)

		_, err = g.r.Turn(context.Background(), turnReq(c, "hello", "k-1"))
		require.Error(t, err)
		synctest.Wait()
		assert.Zero(t, countRows(t, g.d, `conversation_id = ?`, c), "nothing is stored")
		assert.Empty(t, g.f.all(), "no session is started, so no turn is sent")
	})
}

// TestChat01_FailedSpawnLeavesOwnerMessageAnswered: a turn whose session
// cannot start ends as an `error` reply under the owner's message, so the
// next turn's replay keeps the question (Go's HistoryBefore strips only a
// trailing owner row with no reply); the next send replays (the Swift twin
// was testChat01FailedSendKeepsTheOwnerMessageAnswered) (BEHAVIOR CHAT-01 —
// see docs/inventory/chat.md).
func TestChat01_FailedSpawnLeavesOwnerMessageAnswered(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		g.f.fail = errors.New("no provider")
		g.send(t, c, "q", nil)
		synctest.Wait()
		roles, statuses, _ := activePath(t, g, c)
		assert.Equal(t, []string{"user", "assistant"}, roles)
		assert.Equal(t, []string{chatstore.StatusComplete, chatstore.StatusError}, statuses)

		g.f.fail = nil
		s2 := g.send(t, c, "q2", nil)
		assert.True(t, s2.Replay, "a failed turn forces a replay")
		roles, statuses, texts := activePath(t, g, c)
		assert.Equal(t, []string{"user", "assistant", "user", "assistant"}, roles)
		assert.Equal(t, chatstore.StatusError, statuses[1])
		assert.Equal(t, []string{"q", "q2"}, []string{texts[0], texts[2]})
		synctest.Wait()
	})
}

// TestChatengine_ArchiveHidesFromList: chat_manage archive takes the chat off
// the list and keeps its messages; an embedded chat is not archived.
func TestChatengine_ArchiveHidesFromList(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		kept, archived := newConversation(t, g.d), newConversation(t, g.d)
		g.send(t, archived, "q", nil)
		synctest.Wait()
		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: archived, Op: ManageArchive}))

		list, err := ReadList(context.Background(), g.d, time.Now())
		require.NoError(t, err)
		var ids []int64
		for _, conv := range list.Conversations {
			ids = append(ids, conv.ID)
		}
		assert.Equal(t, []int64{kept}, ids)
		assert.Equal(t, 2, countRows(t, g.d, `conversation_id = ?`, archived), "the messages stay")

		res, err := g.d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
			VALUES ('Standup', 'meeting', '7', 1, 1)`)
		require.NoError(t, err)
		embedded, err := res.LastInsertId()
		require.NoError(t, err)
		err = g.r.Manage(context.Background(), ManageRequest{Conversation: embedded, Op: ManageArchive})
		require.ErrorIs(t, err, chatstore.ErrConversationGone)
	})
}

// TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent: a regenerate's reply
// row and an edit's owner and reply rows exist under the new turn id once
// Turn returns — before the session is handed the turn, which carries that
// id — so the replay never drops the owner's question (the Swift twins were
// testChat01RegenerateRowExistsUnderTheNewTurnIDWhenSent and
// testChat01EditRowsExistUnderTheNewTurnIDWhenSent) (BEHAVIOR CHAT-01 — see
// docs/inventory/chat.md).
func TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		// Each turn waits for finish: the session is handed the turn before
		// Turn returns, so an answer that ended at once would race the reads.
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		finish := func() {
			synctest.Wait()
			p := procOf(t, g, c)
			p[len(p)-1].finish()
			synctest.Wait()
		}
		first := g.send(t, c, "q", nil)
		finish()

		regen, err := g.r.Turn(context.Background(), TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: c,
			Mode: chatstore.ModeRegenerate, MessageID: first.AssistantMessageID}})
		require.NoError(t, err)
		reply, _ := readRow(t, g.d, regen.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, reply.status)
		assert.Equal(t, regen.TurnID, turnIDOf(t, g, regen.AssistantMessageID))
		assert.Equal(t, first.UserMessageID, regen.UserMessageID, "a regenerate reuses the owner row")
		synctest.Wait()
		assert.Equal(t, regen.TurnID, lastTurnID(t, g))
		finish()

		edit, err := g.r.Turn(context.Background(), TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: c,
			Mode: chatstore.ModeEdit, MessageID: first.UserMessageID, Text: "q2"}})
		require.NoError(t, err)
		owner, _ := readRow(t, g.d, edit.UserMessageID)
		assert.Equal(t, "q2", owner.text)
		assert.Equal(t, edit.TurnID, turnIDOf(t, g, edit.UserMessageID))
		assert.Equal(t, edit.TurnID, turnIDOf(t, g, edit.AssistantMessageID))
		synctest.Wait()
		assert.Equal(t, edit.TurnID, lastTurnID(t, g))
		finish()
	})
}

func turnIDOf(t *testing.T, g *rig, messageID int64) string {
	t.Helper()
	var id string
	require.NoError(t, g.d.QueryRow(`SELECT turn_id FROM chat_messages WHERE id = ?`, messageID).Scan(&id))
	return id
}

// lastTurnID is the turn id of the last turn command any session got.
func lastTurnID(t *testing.T, g *rig) string {
	t.Helper()
	var id string
	for _, p := range g.f.all() {
		if turns := p.turnCommands(); len(turns) > 0 {
			id = turns[len(turns)-1].TurnID
		}
	}
	require.NotEmpty(t, id)
	return id
}

// TestProj01_EntitySearchNeverOffersAProjectTarget: the `@` picker and the
// project source picker (entity_search, kinds none or "target") never offer
// a workbench target, only an ordinary one with the same text (the Go home
// of the Mac's testProj01_MentionPickerNeverOffersAProjectTarget, whose
// Swift search went with the picker's move to the engine) (BEHAVIOR
// PROJ-01 — see docs/inventory/workbench.md).
func TestProj01_EntitySearchNeverOffersAProjectTarget(t *testing.T) {
	g := newRig(t, fakeOpts{})
	res, err := g.d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	project, err := res.LastInsertId()
	require.NoError(t, err)
	for _, target := range []struct {
		text    string
		project any
	}{{"Ship ordinary", nil}, {"Ship board", project}} {
		_, err := g.d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, status,
			priority, ownership, due_date, tags, source_type, project_id)
			VALUES (?, 'custom', 'project', '2026-11-16', '2026-11-16', 'in_progress', 'high', 'mine', '2020-01-01T09:00', '[]', 'chat', ?)`,
			target.text, target.project)
		require.NoError(t, err)
	}
	for _, kinds := range [][]string{nil, {"target"}} {
		hits, err := g.r.EntitySearch(context.Background(), "ship", kinds)
		require.NoError(t, err)
		var labels []string
		for _, h := range hits {
			if h.Kind == "target" {
				labels = append(labels, h.Label)
			}
		}
		assert.Equal(t, []string{"Ship ordinary"}, labels, "kinds %v", kinds)
	}
}

// TestChatengine_ListCarriesTheRunningTurnID: an answering chat's list row
// names its running turn (the Mac's Inbox strip matches a connector call to
// the turn that still holds it); an idle one names none.
func TestChatengine_ListCarriesTheRunningTurnID(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		st := g.send(t, c, "q", nil)
		synctest.Wait()
		turnOf := func() string {
			list, err := ReadList(context.Background(), g.d, time.Now())
			require.NoError(t, err)
			for _, conv := range list.Conversations {
				if conv.ID == c {
					return conv.TurnID
				}
			}
			return "missing"
		}
		assert.Equal(t, st.TurnID, turnOf())
		g.f.all()[0].finish()
		synctest.Wait()
		assert.Empty(t, turnOf())
	})
}
