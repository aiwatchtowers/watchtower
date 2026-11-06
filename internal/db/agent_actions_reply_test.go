package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var testReplyTools = []string{"send_slack_message", "add_jira_comment", "add_linear_comment"}

func replyRow(tool, itemID string) AgentAction {
	return AgentAction{Tool: tool, External: true, ArgsJSON: `{}`, Reason: "Reply from Messages", Surface: "inbox",
		ContextType: InboxItemContextType, ContextID: itemID}
}

// One open Reply per Inbox item: a second one — of any Reply tool — is
// refused while the first is pending, approved or executing; another item,
// another context or a closed first reply does not block it.
func TestInsertInboxReplyProposal_OneOpenReplyPerItem(t *testing.T) {
	d := OpenTestDB(t)
	first, err := d.InsertInboxReplyProposal(replyRow("send_slack_message", "42"), testReplyTools)
	require.NoError(t, err)

	for _, status := range []string{"pending", "approved", "executing"} {
		_, err = d.Exec(`UPDATE agent_actions SET status = ? WHERE id = ?`, status, first)
		require.NoError(t, err)
		for _, tool := range testReplyTools {
			_, err = d.InsertInboxReplyProposal(replyRow(tool, "42"), testReplyTools)
			var waiting *ErrReplyAlreadyWaiting
			require.ErrorAs(t, err, &waiting, "%s while #%d is %s", tool, first, status)
			assert.Equal(t, first, waiting.ID)
			assert.Contains(t, err.Error(), "a reply to this item is already waiting for approval")
		}
	}
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	assert.Equal(t, 1, n, "a refused reply writes nothing")

	_, err = d.InsertInboxReplyProposal(replyRow("add_jira_comment", "43"), testReplyTools)
	require.NoError(t, err, "another item is free")

	for _, status := range []string{"rejected", "applied", "failed"} {
		_, err = d.Exec(`UPDATE agent_actions SET status = ? WHERE context_id = '42'`, status)
		require.NoError(t, err)
		_, err = d.InsertInboxReplyProposal(replyRow("send_slack_message", "42"), testReplyTools)
		require.NoError(t, err, "a %s reply no longer blocks the item", status)
	}

	_, err = d.InsertInboxReplyProposal(AgentAction{Tool: "send_slack_message", ContextType: "track_event", ContextID: "1"},
		testReplyTools)
	require.Error(t, err, "only an inbox_item context")
}
