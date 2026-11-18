package chatengine

import (
	"context"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestChatengine_TitleHookAndPreferredProvider: the daemon's engine names a
// chat after its first complete answer (Config.Title, off the turn's
// goroutine) and routes an automatic chat to the preferred provider — moved
// here from the hub's options with the engine (T4).
func TestChatengine_TitleHookAndPreferredProvider(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		titled := make(chan int64, 1)
		g.cfg.PreferredProvider = "codex"
		g.cfg.Title = func(_ context.Context, conv int64) error { titled <- conv; return nil }
		_ = g.r.Close(context.Background())
		g.r = g.newEngine()
		t.Cleanup(func() { _ = g.r.Close(context.Background()) })

		conv, err := g.r.NewConversation(context.Background(), nil, nil)
		require.NoError(t, err)
		st, err := g.r.Turn(context.Background(), turnReq(conv, "hi", ""))
		require.NoError(t, err)
		assert.True(t, st.Routing.Automatic)
		assert.Equal(t, "codex", st.Routing.Provider)
		synctest.Wait()
		select {
		case got := <-titled:
			assert.Equal(t, conv, got)
		default:
			t.Fatal("no AI title after the first complete answer")
		}
	})
}

// TestChatengine_TitleWritePublishesListAndConversation: the AI title the
// hook writes after the first complete answer reaches the list's and the
// conversation's subscribers with no further turn or change.
func TestChatengine_TitleWritePublishesListAndConversation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		release := make(chan struct{})
		g.cfg.Title = func(ctx context.Context, conv int64) error {
			<-release
			_, err := g.d.ExecContext(ctx, `UPDATE chat_conversations SET title = 'Rollout plan', title_source = 'ai' WHERE id = ?`, conv)
			return err
		}
		_ = g.r.Close(context.Background())
		g.r = g.newEngine()
		t.Cleanup(func() { _ = g.r.Close(context.Background()) })

		conv, err := g.r.NewConversation(context.Background(), nil, nil)
		require.NoError(t, err)
		list := g.r.Subscribe(Target{List: true}, Client{Kind: "mac"})
		defer list.Close()
		feed := g.r.Subscribe(Target{Conversation: conv}, Client{Kind: "mac"})
		defer feed.Close()
		listRec, feedRec := record(list), record(feed)
		_, err = g.r.Turn(context.Background(), turnReq(conv, "hi", ""))
		require.NoError(t, err)
		time.Sleep(2 * time.Second) // the answer completes and every window closes
		synctest.Wait()
		titled := func(rec *recorder) bool {
			for _, s := range rec.of(EventListUpdate) {
				for _, row := range s.ev.List.Conversations {
					if row.ID == conv && row.Title == "Rollout plan" {
						return true
					}
				}
			}
			for _, s := range rec.of(EventConversationUpdate) {
				if s.ev.ConversationUpdate != nil && s.ev.ConversationUpdate.Title == "Rollout plan" {
					return true
				}
			}
			for _, s := range rec.of(EventSnapshot) {
				if s.ev.Snapshot != nil && s.ev.Snapshot.Conversation.Title == "Rollout plan" {
					return true
				}
			}
			return false
		}
		require.False(t, titled(listRec) || titled(feedRec), "titled before the hook wrote it")

		close(release)
		time.Sleep(2 * time.Second)
		synctest.Wait()
		assert.True(t, titled(listRec), "the list's subscriber did not get the AI title")
		assert.True(t, titled(feedRec), "the conversation's subscriber did not get the AI title")
	})
}
