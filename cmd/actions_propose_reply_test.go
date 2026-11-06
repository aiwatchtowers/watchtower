package cmd

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/slack"
	"watchtower/internal/tools"
)

// replyFixture is one connected Slack workspace (acme, #general), one Jira
// site with ABC-7 and one Linear workspace with ENG-7 — what a Reply from an
// Inbox row (Inbox builder B, ask #445) proposes against. No token exists
// (HOME is a temp dir), so a client call would fail the row: a pending row
// with no result is proof nothing reached Slack, Jira or Linear.
type replyFixture struct {
	slackAcct, jiraAcct, linearAcct int64
}

func seedReplyFixture(t *testing.T, database *db.DB) replyFixture {
	t.Helper()
	var f replyFixture
	var err error
	f.slackAcct, err = database.CreateSlackAccount(db.SlackAccount{TeamName: "Acme", TeamDomain: "acme", Label: "Acme"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertChannel(db.Channel{ID: slack.Namespace(f.slackAcct, "CGEN"), Name: "general", Type: "public"}))

	f.jiraAcct, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{AccountID: f.jiraAcct, Key: "ABC-7", ID: "1", ProjectKey: "ABC",
		Summary: "Fix the release notes", Status: "To Do", Labels: "[]", Components: "[]", FixVersions: "[]"}))

	f.linearAcct, err = database.CreateLinearAccount("acme")
	require.NoError(t, err)
	require.NoError(t, database.UpdateLinearAccountConnection(f.linearAcct, "org-acme", "acme", "acme"))
	require.NoError(t, database.UpsertLinearIssue(db.LinearIssue{AccountID: f.linearAcct, ID: "id-ENG-7", Key: "ENG-7",
		TeamID: "team-ENG", TeamKey: "ENG", Title: "Ship the queue", StateName: "Todo", StateType: "unstarted",
		CreatedAt: "2026-10-18T08:00:00Z", UpdatedAt: "2026-10-18T08:00:00Z"}))
	return f
}

const slackMessageLink = "https://acme.slack.com/archives/CGEN/p1700000000123456"

// replyArgs is the Desktop's Reply press for tool (InboxReplyPolicy.args):
// bound to the item's own permalink or key and account.
func (f replyFixture) replyArgs(tool string) string {
	var a map[string]any
	switch tool {
	case "send_slack_message":
		a = map[string]any{"channel": slackMessageLink, "account_id": f.slackAcct, "text": "On it",
			"reason": "Reply from Waiting for me"}
	case "add_jira_comment":
		a = map[string]any{"key": "ABC-7", "account_id": f.jiraAcct, "body": "On it", "reason": "Reply from Waiting for me"}
	case "add_linear_comment":
		a = map[string]any{"key": "ENG-7", "account_id": f.linearAcct, "body": "On it", "reason": "Reply from Waiting for me"}
	}
	raw, _ := json.Marshal(a)
	return string(raw)
}

func replyPressArgs(tool, args string, extra ...string) []string {
	return append([]string{"--tool", tool, "--surface", "inbox", "--context", "inbox_item:42", "--args", args, "--json"}, extra...)
}

func TestActionsPropose_ReplyRecordsOnePendingRow(t *testing.T) {
	for _, tool := range tools.InboxReplyTools() {
		t.Run(tool, func(t *testing.T) {
			database := writeActionsConfig(t)
			f := seedReplyFixture(t, database)
			got := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)

			out, err := runPropose(t, replyPressArgs(tool, f.replyArgs(tool))...)
			require.NoError(t, err, out)

			var env proposeEnvelope
			require.NoError(t, json.Unmarshal([]byte(out), &env), out)
			assert.True(t, env.OK)
			assert.False(t, env.AppliedOK)
			assert.Equal(t, tool, env.Action.Tool)
			assert.Equal(t, "pending", env.Action.Status)
			assert.Equal(t, "inbox", env.Action.Surface)
			assert.Empty(t, *got, "a proposal needs no Confirm: nothing is applied")

			assert.Equal(t, 1, actionRowCount(t, database))
			var ctxType, ctxID, status, result, appliedAt string
			require.NoError(t, database.QueryRow(`SELECT context_type, context_id, status, result_json, applied_at FROM agent_actions`).
				Scan(&ctxType, &ctxID, &status, &result, &appliedAt))
			assert.Equal(t, "inbox_item", ctxType)
			assert.Equal(t, "42", ctxID)
			assert.Equal(t, "pending", status)
			assert.Empty(t, result, "nothing was sent")
			assert.Empty(t, appliedAt, "nothing was applied")
		})
	}
}

// A Slack Reply is bound to the item's own place at propose time: a message
// link replies in its thread, a reply's link in the parent thread, and an
// unresolvable link writes no row (send_slack_message's Normalize).
func TestActionsPropose_SlackReplyPinsItsThread(t *testing.T) {
	cases := map[string]string{
		"a message link":         slackMessageLink,
		"a reply-in-thread link": "https://acme.slack.com/archives/CGEN/p1700000099000001?thread_ts=1700000000.123456&cid=CGEN",
	}
	for name, link := range cases {
		t.Run(name, func(t *testing.T) {
			database := writeActionsConfig(t)
			f := seedReplyFixture(t, database)
			args, _ := json.Marshal(map[string]any{"channel": link, "account_id": f.slackAcct, "text": "On it",
				"reason": "Reply from Messages"})

			out, err := runPropose(t, replyPressArgs("send_slack_message", string(args))...)
			require.NoError(t, err, out)

			var stored string
			require.NoError(t, database.QueryRow(`SELECT args_json FROM agent_actions`).Scan(&stored))
			var a struct {
				Target struct {
					ChannelID string `json:"channel_id"`
					ThreadTS  string `json:"thread_ts"`
				} `json:"target"`
			}
			require.NoError(t, json.Unmarshal([]byte(stored), &a), stored)
			assert.Equal(t, "CGEN", a.Target.ChannelID)
			assert.Equal(t, "1700000000.123456", a.Target.ThreadTS, "the reply goes into the item's thread")
		})
	}
	t.Run("a link that does not resolve", func(t *testing.T) {
		database := writeActionsConfig(t)
		f := seedReplyFixture(t, database)
		args, _ := json.Marshal(map[string]any{"channel": "https://acme.slack.com/archives/CNOPE/p1700000000123456",
			"account_id": f.slackAcct, "text": "On it", "reason": "Reply from Messages"})

		out, err := runPropose(t, replyPressArgs("send_slack_message", string(args))...)
		require.Error(t, err, out)
		assert.Zero(t, actionRowCount(t, database), "no row")
	})
}

// AGENT-03/AGENT-07 (ask #451): a Reply is never proposed and applied in one
// press — --approve is refused for the three Reply tools before the owner is
// asked and before a row is written; apply_track_action's one press stays.
func TestActionsPropose_RefusesApproveForReplyTools(t *testing.T) {
	for _, tool := range tools.InboxReplyTools() {
		t.Run(tool, func(t *testing.T) {
			database := writeActionsConfig(t)
			f := seedReplyFixture(t, database)
			got := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)

			out, err := runPropose(t, replyPressArgs(tool, f.replyArgs(tool), "--approve")...)
			require.Error(t, err, out)
			assert.Contains(t, err.Error(), "a reply is approved in Needs approval")
			assert.Empty(t, *got, "refused before the owner is asked")
			assert.Zero(t, actionRowCount(t, database), "no row")
		})
	}
	t.Run("apply_track_action keeps its one press", func(t *testing.T) {
		database := writeActionsConfig(t)
		targetID, eventID := seedTrackEvent(t, database)
		out, err := runPropose(t, pressArgs(eventID, "--approve")...)
		require.NoError(t, err, out)
		var env proposeEnvelope
		require.NoError(t, json.Unmarshal([]byte(out), &env), out)
		assert.True(t, env.AppliedOK)
		assert.Equal(t, "done", targetStatus(t, database, targetID))
	})
}

// AGENT-07: a Reply press is refused under every agent marker before
// anything is read, no row written.
func TestActionsPropose_ReplyRefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			database := writeActionsConfig(t)
			f := seedReplyFixture(t, database)
			t.Setenv(marker, "1")
			for _, tool := range tools.InboxReplyTools() {
				out, err := runPropose(t, replyPressArgs(tool, f.replyArgs(tool))...)
				require.Error(t, err, out)
				assert.Contains(t, err.Error(), marker)
			}
			assert.Zero(t, actionRowCount(t, database))
		})
	}
}

func TestActionsPropose_ContextFlagIsAnInboxItem(t *testing.T) {
	const want = "want inbox_item:<positive id>"
	const both = "--context replaces --context-type and --context-id"
	cases := map[string]struct {
		flags []string
		msg   string
	}{
		"no id":             {[]string{"--context", "inbox_item:"}, `--context "inbox_item:": ` + want},
		"another type":      {[]string{"--context", "x:1"}, `--context "x:1": ` + want},
		"a negative id":     {[]string{"--context", "inbox_item:-1"}, `--context "inbox_item:-1": ` + want},
		"a zero id":         {[]string{"--context", "inbox_item:0"}, `--context "inbox_item:0": ` + want},
		"a padded id":       {[]string{"--context", "inbox_item:01"}, `--context "inbox_item:01": ` + want},
		"no separator":      {[]string{"--context", "inbox_item"}, `--context "inbox_item": ` + want},
		"with context-type": {[]string{"--context", "inbox_item:1", "--context-type", "inbox_item"}, both},
		"with context-id":   {[]string{"--context", "inbox_item:1", "--context-id", "1"}, both},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			database := writeActionsConfig(t)
			f := seedReplyFixture(t, database)
			args := append([]string{"--tool", "add_jira_comment", "--surface", "inbox",
				"--args", f.replyArgs("add_jira_comment"), "--json"}, tc.flags...)
			out, err := runPropose(t, args...)
			require.Error(t, err, out)
			assert.Contains(t, err.Error(), tc.msg)
			assert.Zero(t, actionRowCount(t, database), "no row")
		})
	}
	t.Run("a positive id is stored", func(t *testing.T) {
		database := writeActionsConfig(t)
		f := seedReplyFixture(t, database)
		out, err := runPropose(t, "--tool", "add_jira_comment", "--surface", "inbox", "--context", "inbox_item:7",
			"--args", f.replyArgs("add_jira_comment"), "--json")
		require.NoError(t, err, out)
		var ctxType, ctxID string
		require.NoError(t, database.QueryRow(`SELECT context_type, context_id FROM agent_actions`).Scan(&ctxType, &ctxID))
		assert.Equal(t, "inbox_item", ctxType)
		assert.Equal(t, strconv.Itoa(7), ctxID)
	})
}

// A second Reply to the same item while the first waits is refused before
// anything is written (approving both would post twice); another item is
// free, and so is the item once its reply is rejected.
func TestActionsPropose_SecondReplyToAnItemIsRefused(t *testing.T) {
	database := writeActionsConfig(t)
	f := seedReplyFixture(t, database)
	out, err := runPropose(t, replyPressArgs("send_slack_message", f.replyArgs("send_slack_message"))...)
	require.NoError(t, err, out)

	for _, tool := range tools.InboxReplyTools() {
		out, err = runPropose(t, replyPressArgs(tool, f.replyArgs(tool))...)
		require.Error(t, err, out)
		assert.Contains(t, err.Error(), "a reply to this item is already waiting for approval", tool)
	}
	assert.Equal(t, 1, actionRowCount(t, database), "no second row")

	other := []string{"--tool", "add_jira_comment", "--surface", "inbox", "--context", "inbox_item:43",
		"--args", f.replyArgs("add_jira_comment"), "--json"}
	out, err = runPropose(t, other...)
	require.NoError(t, err, out)

	_, err = database.Exec(`UPDATE agent_actions SET status = 'rejected' WHERE context_id = '42'`)
	require.NoError(t, err)
	out, err = runPropose(t, replyPressArgs("add_linear_comment", f.replyArgs("add_linear_comment"))...)
	require.NoError(t, err, out)
	assert.Equal(t, 3, actionRowCount(t, database))
}
