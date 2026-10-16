package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedAutomationAsk files an answered question ask of a running automation
// run on workbenchID, as ask() does: no session, the run set.
func seedAutomationAsk(t *testing.T, d *db.DB, workbenchID int64) int64 {
	t.Helper()
	autoID, err := d.UpsertAutomationIndex(db.Automation{
		Slug: "deploy", Scope: "personal", Path: "/acme/automations/deploy.md", Name: "Acme deploy",
		TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
		Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
		PermissionsJSON: `["ask:owner"]`, OutputsJSON: `[]`, RecipeText: "---\nname: x\n---\n", ContentHash: "c", ApprovalHash: "h",
	})
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, recipe_hash) VALUES (?, 'manual', 'running', 'h')`, autoID)
	require.NoError(t, err)
	runID, err := res.LastInsertId()
	require.NoError(t, err)
	var id int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		id, _, err = d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: workbenchID, Kind: "question", Title: "Which store?",
			Payload:         `{"focus":[],"questions":[{"id":"1","question":"Where?","options":[{"label":"SQLite"},{"label":"Files"}]}],"checklist":[]}`,
			AutomationRunID: sql.NullInt64{Int64: runID, Valid: true}})
		return err
	}))
	return id
}

// Review focus 3: an automation's ask never reaches a session. list_asks
// does not list it (any status, any session filter), get_ask reads it as no
// ask (and delivers nothing), withdraw_ask refuses it as not found, and
// ask_owner cannot name it as previous_ask_id.
func TestAutomationAsks_InvisibleToSessionReaders(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	auto := seedAutomationAsk(t, fx.d, fx.a)
	answerAsk(t, fx.d, auto, `{"answers":[{"id":"1","labels":["SQLite"]}]}`)
	external := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAskTitled("External terminal ask")))
	answerAsk(t, fx.d, external, `{"answers":[{"id":"1","labels":["Files"]}]}`)

	for _, status := range []string{"", "answered", "all"} {
		var rows []askRow
		require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "list_asks", fmt.Sprintf(`{"status":%q}`, status))), &rows))
		require.Len(t, rows, 1, "status %q", status)
		assert.Equal(t, external, rows[0].AskID)
	}

	noAskMsg := fmt.Sprintf("no ask with id %d", auto)
	_, err := reg.CallRead(context.Background(), "get_ask", json.RawMessage(fmt.Sprintf(`{"ask_id":%d}`, auto)), directBinding(fx.a))
	assert.Equal(t, noAskMsg, refusal(t, err))
	assert.Equal(t, "answered", storedAsk(t, fx.d, fx.a, auto).Status, "get_ask delivered nothing")

	_, err = proposeIn(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"r"}`, auto))
	assert.Equal(t, noAskMsg, refusal(t, err))
	_, err = proposeIn(t, reg, fx.a, "ask_owner",
		questionAsk[:len(questionAsk)-1]+fmt.Sprintf(`,"previous_ask_id":%d}`, auto))
	assert.Equal(t, "previous_ask_id: "+noAskMsg, refusal(t, err))
	assert.Equal(t, "answered", storedAsk(t, fx.d, fx.a, auto).Status)
}
