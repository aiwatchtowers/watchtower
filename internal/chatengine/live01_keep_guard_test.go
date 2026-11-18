package chatengine

import (
	"context"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestKeepRefusedForLiveConversation (BEHAVIOR LIVE-01): keeping an
// artifact of a conversation that used Live Slack is refused, nothing kept.
// Moved here from internal/chatstore/moved_guards_test.go with its name and
// assertions when the main chat's keep became the engine's artifact_manage
// (merge of #1822 into #1170, ask #1469); TestChatengine_ArtifactKeepWritesKnowledgeRow
// is main's twin of it and stays.
func TestKeepRefusedForLiveConversation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		conv := newConversation(t, g.d)
		st := finishedTurn(t, g, conv, "draft")
		seedArtifact(t, g.d, conv, st.AssistantMessageID, "plan", 0)
		ctx := context.Background()
		keep := func() error {
			_, err := g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactKeep, Conversation: conv, Key: "plan", Version: 1})
			return err
		}
		require.NoError(t, keep())
		_, err := g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactUnkeep, Conversation: conv, Key: "plan"})
		require.NoError(t, err)
		_, err = g.d.Exec(`UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?`, st.AssistantMessageID, conv)
		require.NoError(t, err)
		err = keep()
		require.Error(t, err)
		assert.Equal(t, "forbidden", ErrorCode(err), "refused as not permitted")
		var kept int
		require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_knowledge_artifacts WHERE conversation_id = ?`, conv).Scan(&kept))
		assert.Zero(t, kept)
	})
}
