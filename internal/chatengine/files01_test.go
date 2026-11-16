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
	"watchtower/internal/logcanary"
)

// TestFILES01_Chatengine runs turns whose owner text, streamed answer, a
// non-event stdout line and a spawn error carry canaries through every
// logging path of the runner (a cancel, a lost conversation, a failed
// spawn, unreadable lines, the sweep): no canary reaches the log.
func TestFILES01_Chatrun(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := logcanary.Text
		sink := logcanary.Capture(t)
		g := newRig(t, fakeOpts{block: true, text: c("answer.delta"), junk: c("stdout.junk")})

		cancelled := newConversation(t, g.d)
		st := g.send(t, cancelled, c("owner.text"), nil)
		synctest.Wait()
		_, err := g.r.Cancel(cancelled, st.TurnID)
		require.NoError(t, err)
		synctest.Wait()

		deleted := newConversation(t, g.d)
		g.send(t, deleted, c("owner.second"), nil)
		synctest.Wait()
		_, err = g.d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, deleted)
		require.NoError(t, err)
		time.Sleep(time.Second)
		synctest.Wait()

		g.f.fail = errors.New(c("spawn.error"))
		failed := newConversation(t, g.d)
		require.NoError(t, g.r.Close(context.Background()))
		g.r = New(g.cfg)
		g.send(t, failed, c("owner.third"), nil)
		synctest.Wait()
		require.NoError(t, g.r.Start(context.Background()))
		_, err = g.r.Turn(context.Background(), TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: failed,
			Mode: chatstore.ModeSend, Text: c("owner.fourth")}})
		require.NoError(t, err)
		synctest.Wait()
		require.NoError(t, g.r.Close(context.Background()))

		assert.NotEmpty(t, sink.String(), "the paths above log")
		sink.AssertClean(t)
	})
}
