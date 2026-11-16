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
