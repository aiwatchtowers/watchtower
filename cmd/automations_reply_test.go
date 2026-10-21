package cmd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

// replyRecipeText is a confirmed-able recipe that reacts to its own Inbox
// buttons (inbox:reply needs outputs: [inbox]).
const replyRecipeText = "---\nname: Triage\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n  - inbox:reply\n" +
	"outputs: [inbox]\n---\nA reply test recipe.\n\n```js\nreturn 1\n```\n"

const replyCardActions = `[{"label":"Backlog","kind":"reply","reply":"backlog","data":{"k":1}},` +
	`{"label":"Source","kind":"link","open":"https://example.com/a-1"}]`

// seedReplyCard stores an inbox card of automation a on a finished run.
func seedReplyCard(t *testing.T, d *db.DB, a int64, actions string) int64 {
	t.Helper()
	var run int64
	require.NoError(t, d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status)
		VALUES (?, 'manual', 'succeeded') RETURNING id`, a).Scan(&run))
	var id int64
	require.NoError(t, d.QueryRow(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, link, actions_json)
		VALUES (?, ?, 'inbox', 'Bug A-1', 'body', 'https://example.com/a-1', ?) RETURNING id`, a, run, actions).Scan(&id))
	return id
}

// withReplyWake counts the wakes a reply attempts.
func withReplyWake(t *testing.T) *int {
	t.Helper()
	n := 0
	orig := replyWake
	replyWake = func(*config.Config) (bool, error) { n++; return false, nil }
	t.Cleanup(func() { replyWake = orig })
	return &n
}

func replyRunCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM automation_runs WHERE trigger = 'reply'`).Scan(&n))
	return n
}

func assertNotPressed(t *testing.T, d *db.DB, out int64) {
	t.Helper()
	var pressed bool
	require.NoError(t, d.QueryRow(`SELECT pressed_at IS NOT NULL FROM automation_outputs WHERE id = ?`, out).Scan(&pressed))
	assert.False(t, pressed, "card %d pressed", out)
}

// AGENT-07: only the owner presses an Inbox button.
func TestAutomationsCLI_ReplyRefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			c := newAutoCLI(t)
			a := c.confirmedRecipe(t, "triage", replyRecipeText)
			out := seedReplyCard(t, c.d, a.ID, replyCardActions)
			asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
			t.Setenv(marker, "1")

			_, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
			require.Error(t, err)
			assert.Contains(t, err.Error(), "refusing to press an Inbox button under an AI agent")
			assert.Contains(t, err.Error(), marker)
			assert.Zero(t, replyRunCount(t, c.d), "no run under %s", marker)
			assertNotPressed(t, c.d, out)
			assert.Empty(t, *asked, "the owner is never asked under %s", marker)
		})
	}
}

// AUTO-09: reply only queues the run and wakes the daemon.
func TestAuto09_ReplyCommandOnlyQueues(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "triage", replyRecipeText)
	out := seedReplyCard(t, c.d, a.ID, replyCardActions)
	asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
	wakes := withReplyWake(t)

	got := runAutomationsJSON(t, "reply", "--output", idArg(out), "--action", "0")
	wantKeys(t, got, "run_id", "daemon_running")
	assert.Equal(t, false, got["daemon_running"])
	runID := int64(got["run_id"].(float64))
	run, err := c.d.GetAutomationRun(runID)
	require.NoError(t, err)
	assert.Equal(t, db.RunQueued, run.Status)
	assert.Equal(t, db.TriggerReply, run.Trigger)
	assert.Equal(t, a.ID, run.AutomationID)
	var steps int
	require.NoError(t, c.d.QueryRow(`SELECT COUNT(*) FROM automation_run_steps WHERE run_id = ?`, runID).Scan(&steps))
	assert.Zero(t, steps, "nothing ran in-process")
	assert.Zero(t, c.gen.CallCount())
	assert.Equal(t, 1, *wakes, "the wake was attempted once")

	require.Len(t, *asked, 1)
	assert.Equal(t, "press an Inbox button", (*asked)[0].Verb)
	for _, want := range []string{"Triage", "Bug A-1", "Backlog", "backlog"} {
		assert.Contains(t, (*asked)[0].Detail, want)
	}
}

func TestAutomationsCLI_ReplyTextOutput(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "triage", replyRecipeText)
	out := seedReplyCard(t, c.d, a.ID, replyCardActions)
	withReplyWake(t)
	text, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
	require.NoError(t, err, text)
	assert.Regexp(t, `^Queued run #\d+\.\n`+daemonNotRunningNote+"\n$", text)
}

func TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability(t *testing.T) {
	t.Run("disabled", func(t *testing.T) {
		c := newAutoCLI(t)
		a := c.confirmedRecipe(t, "triage", replyRecipeText)
		out := seedReplyCard(t, c.d, a.ID, replyCardActions)
		require.NoError(t, c.d.SetAutomationEnabled(a.ID, false, time.Now()))
		asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
		_, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
		require.ErrorContains(t, err, "cannot run: it is disabled")
		assert.Zero(t, replyRunCount(t, c.d))
		assertNotPressed(t, c.d, out)
		assert.Empty(t, *asked)
	})
	t.Run("no inbox:reply", func(t *testing.T) {
		c := newAutoCLI(t)
		text := strings.Replace(replyRecipeText, "  - inbox:reply\n", "", 1)
		a := c.confirmedRecipe(t, "triage", text)
		out := seedReplyCard(t, c.d, a.ID, replyCardActions)
		asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
		_, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
		require.ErrorContains(t, err, "no longer reacts to its Inbox buttons (inbox:reply)")
		assert.Zero(t, replyRunCount(t, c.d))
		assertNotPressed(t, c.d, out)
		assert.Empty(t, *asked)
	})
}

func TestAutomationsCLI_ReplySecondPressSaysSent(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "triage", replyRecipeText)
	out := seedReplyCard(t, c.d, a.ID, replyCardActions)
	withReplyWake(t)
	first := runAutomationsJSON(t, "reply", "--output", idArg(out), "--action", "0")
	runID := int64(first["run_id"].(float64))

	_, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
	require.ErrorContains(t, err, "Sent — run #"+idArg(runID))
	assert.Equal(t, 1, replyRunCount(t, c.d))

	// Still "Sent" once the automation is off.
	require.NoError(t, c.d.SetAutomationEnabled(a.ID, false, time.Now()))
	_, err = runAutomations(t, "reply", "--output", idArg(out), "--action", "0")
	require.ErrorContains(t, err, "Sent — run #"+idArg(runID))
}

func TestAutomationsCLI_ReplyRefusesALinkActionAndAMissingCard(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "triage", replyRecipeText)
	out := seedReplyCard(t, c.d, a.ID, replyCardActions)
	asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
	_, err := runAutomations(t, "reply", "--output", idArg(out), "--action", "1")
	require.ErrorIs(t, err, db.ErrNotAReplyAction)
	_, err = runAutomations(t, "reply", "--output", "999999", "--action", "0")
	require.ErrorIs(t, err, db.ErrOutputNotFound)
	assert.Zero(t, replyRunCount(t, c.d))
	assert.Empty(t, *asked, "the owner is never asked about a press that cannot happen")
}

func TestAutomationsCLI_ReplyFlagsRequired(t *testing.T) {
	newAutoCLI(t)
	asked := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
	for _, args := range [][]string{
		{"reply", "--action", "0"},
		{"reply", "--output", "1"},
		{"reply", "--output", "1", "--action", "-1"},
		{"reply", "--output", "0", "--action", "0"},
	} {
		_, err := runAutomations(t, args...)
		require.Error(t, err, "%v", args)
		assert.Contains(t, err.Error(), "usage: watchtower automations reply --output <id> --action <index>", "%v", args)
	}
	assert.Empty(t, *asked)
}

func TestAutomationsCLI_OutputsJSONCardKeys(t *testing.T) {
	c := newAutoCLI(t)
	a := c.confirmedRecipe(t, "triage", replyRecipeText)
	seedReplyCard(t, c.d, a.ID, replyCardActions)
	withReplyWake(t)

	rows := runAutomationsJSONList(t, "outputs")
	require.Len(t, rows, 1)
	wantKeys(t, rows[0], "id", "automation_id", "run_id", "kind", "title", "body", "priority", "created_at",
		"read_at", "dismissed_at", "link", "actions", "done_at", "press")
	assert.Equal(t, "https://example.com/a-1", rows[0]["link"])
	assert.Nil(t, rows[0]["done_at"])
	assert.Nil(t, rows[0]["press"])
	actions := rows[0]["actions"].([]any)
	require.Len(t, actions, 2)
	assert.Equal(t, map[string]any{"label": "Backlog", "kind": "reply", "reply": "backlog",
		"data": map[string]any{"k": float64(1)}}, actions[0])

	got := runAutomationsJSON(t, "reply", "--output", idArg(int64(rows[0]["id"].(float64))), "--action", "0")
	rows = runAutomationsJSONList(t, "outputs")
	press, ok := rows[0]["press"].(map[string]any)
	require.True(t, ok, "press = %v", rows[0]["press"])
	wantKeys(t, press, "action", "run_id", "pressed_at")
	assert.Equal(t, float64(0), press["action"])
	assert.Equal(t, got["run_id"], press["run_id"])
	_, err := time.Parse(time.RFC3339, press["pressed_at"].(string))
	require.NoError(t, err)

	// The reply run deleted: run_id null, the press kept.
	_, err = c.d.Exec(`DELETE FROM automation_runs WHERE id = ?`, int64(got["run_id"].(float64)))
	require.NoError(t, err)
	out, err := runAutomations(t, "outputs", "--json")
	require.NoError(t, err)
	var after []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &after))
	press = after[0]["press"].(map[string]any)
	assert.Nil(t, press["run_id"])
	assert.Contains(t, press, "run_id")
}
