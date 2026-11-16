package chatengine

import (
	"context"
	"testing"
	"testing/synctest"

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
