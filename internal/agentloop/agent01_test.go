package agentloop

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// AGENT-01 on the runtime-B path: a write-tool call in the loop records exactly
// one pending agent_actions row and never executes the tool. The proposal
// carries the loop's own binding (surface/conversation/turn). This mirrors the
// MCP guard TestAgent01_WriteToolCallRecordsProposalOnly for the in-process loop.
func TestRuntimeB_WriteToolRecordsProposalOnly(t *testing.T) {
	database, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewCreateTarget()))

	srv, _ := scriptedServer(t,
		toolCallResp("create_target", `{"text":"ship it","reason":"the owner asked"}`),
		finalResp("Proposal recorded — it awaits your approval."))

	c := &Client{
		model: "m", baseURL: srv.URL, httpc: http.DefaultClient, reg: reg,
		binding: tools.Binding{Surface: "main", ConversationID: 5, TurnID: "t1"}, maxIter: 6,
	}

	text, _, err := c.run(context.Background(), "", "remember to ship it", nil)
	require.NoError(t, err)
	assert.Contains(t, text, "approval")

	rows, err := database.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	require.Len(t, rows, 1, "exactly one proposal recorded")
	assert.Equal(t, "pending", rows[0].Status, "trust=ask: pending means the tool never executed (AGENT-01)")
	assert.Equal(t, "create_target", rows[0].Tool)
	assert.Equal(t, "main", rows[0].Surface, "the loop's binding reaches the proposal")
	assert.Equal(t, int64(5), rows[0].ConversationID)
	assert.Equal(t, "t1", rows[0].TurnID)
}
