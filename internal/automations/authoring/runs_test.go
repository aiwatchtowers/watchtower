package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

func openRunsTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func seedRunsAutomation(t *testing.T, d *db.DB, scope string, projectID int64, slug string) int64 {
	t.Helper()
	id, err := d.UpsertAutomationIndex(db.Automation{
		Slug: slug, Scope: scope, ProjectID: projectID, Path: "/acme/" + scope + "/" + slug + ".md", Name: "Acme " + slug,
		TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
		Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
		PermissionsJSON: `["llm"]`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: x\n---\n", ContentHash: "c-" + slug, ApprovalHash: "a-" + slug,
	})
	require.NoError(t, err)
	return id
}

func seedRun(t *testing.T, d *db.DB, auto int64, status string) int64 {
	t.Helper()
	var id int64
	require.NoError(t, d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status, input_tokens, output_tokens, error)
		VALUES (?, 'manual', ?, 7, 5, 'boom') RETURNING id`, auto, status).Scan(&id))
	return id
}

func callRunTool(t *testing.T, tool *tools.Tool, args string) (map[string]any, error) {
	t.Helper()
	res, err := tool.Execute(context.Background(), nil, tools.Call{Args: json.RawMessage(args)})
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out map[string]any
	require.NoError(t, json.Unmarshal(raw, &out))
	return out, nil
}

func TestListAutomationRuns_NewestFirstAndLimit(t *testing.T) {
	d := openRunsTestDB(t)
	a := seedRunsAutomation(t, d, "personal", 0, "digest")
	var last int64
	for i := 0; i < 12; i++ {
		last = seedRun(t, d, a, "succeeded")
	}
	tool := NewListAutomationRuns(Deps{DB: d})

	out, err := callRunTool(t, tool, `{"automation":"digest"}`)
	require.NoError(t, err)
	runs := out["runs"].([]any)
	require.Len(t, runs, 10)
	assert.EqualValues(t, last, runs[0].(map[string]any)["id"])
	assert.EqualValues(t, last-9, runs[9].(map[string]any)["id"])
	assert.Equal(t, "digest", out["automation"].(map[string]any)["slug"])
	assert.EqualValues(t, 12, runs[0].(map[string]any)["tokens"])

	out, err = callRunTool(t, tool, `{"automation":"`+strconv.FormatInt(a, 10)+`","limit":80}`)
	require.NoError(t, err)
	assert.Len(t, out["runs"], 12)
}

func TestListAutomationRuns_BySlugAmbiguous(t *testing.T) {
	d := openRunsTestDB(t)
	wb, err := d.CreateWorkbench("beta", t.TempDir())
	require.NoError(t, err)
	p := seedRunsAutomation(t, d, "personal", 0, "digest")
	w := seedRunsAutomation(t, d, "workbench", wb, "digest")

	_, err = callRunTool(t, NewListAutomationRuns(Deps{DB: d}), `{"automation":"digest"}`)
	var ve *tools.ValidationError
	require.True(t, errors.As(err, &ve))
	assert.Contains(t, ve.Msg, strconv.FormatInt(p, 10))
	assert.Contains(t, ve.Msg, strconv.FormatInt(w, 10))
	assert.Contains(t, ve.Msg, strconv.FormatInt(p, 10)+" (personal)")
	assert.Contains(t, ve.Msg, strconv.FormatInt(w, 10)+" (workbench "+strconv.FormatInt(wb, 10)+")")

	_, err = callRunTool(t, NewListAutomationRuns(Deps{DB: d}), `{"automation":"nope"}`)
	require.True(t, errors.As(err, &ve))
}

func TestGetAutomationRun_CapsResultAndBody(t *testing.T) {
	d := openRunsTestDB(t)
	a := seedRunsAutomation(t, d, "personal", 0, "digest")
	run := seedRun(t, d, a, "failed")
	big := strings.Repeat("é", 10000)
	_, err := d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, name, result_summary, status, started_at)
		VALUES (?, 1, 'llm', 'llm', ?, 'ok', '2026-10-24T10:00:00Z'), (?, 2, 'tool', 't', 'short', 'ok', '2026-10-24T10:00:01Z')`, run, big, run)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body) VALUES (?, ?, 'inbox', 'T', ?)`, a, run, big)
	require.NoError(t, err)

	out, err := callRunTool(t, NewGetAutomationRun(Deps{DB: d}), `{"run_id":`+strconv.FormatInt(run, 10)+`}`)
	require.NoError(t, err)
	assert.Equal(t, "boom", out["run"].(map[string]any)["error"])
	steps := out["steps"].([]any)
	require.Len(t, steps, 2)
	s0 := steps[0].(map[string]any)
	assert.Len(t, []rune(s0["result"].(string)), 4000)
	assert.Equal(t, true, s0["truncated"])
	assert.Nil(t, steps[1].(map[string]any)["truncated"])
	o0 := out["outputs"].([]any)[0].(map[string]any)
	assert.Len(t, []rune(o0["body"].(string)), 4000)
	assert.Equal(t, true, o0["truncated"])
}

func TestGetAutomationRun_UnknownRun(t *testing.T) {
	d := openRunsTestDB(t)
	var ve *tools.ValidationError
	_, err := callRunTool(t, NewGetAutomationRun(Deps{DB: d}), `{"run_id":999}`)
	require.True(t, errors.As(err, &ve))

	a := seedRunsAutomation(t, d, "personal", 0, "gone")
	run := seedRun(t, d, a, "succeeded")
	_, err = d.Exec(`UPDATE automations SET removed_at = ? WHERE id = ?`, time.Now().UTC().Format(time.RFC3339), a)
	require.NoError(t, err)
	_, err = callRunTool(t, NewGetAutomationRun(Deps{DB: d}), `{"run_id":`+strconv.FormatInt(run, 10)+`}`)
	require.True(t, errors.As(err, &ve))
}

func TestGetAutomationRun_CapsStepsAndOutputs(t *testing.T) {
	d := openRunsTestDB(t)
	a := seedRunsAutomation(t, d, "personal", 0, "digest")
	run := seedRun(t, d, a, "succeeded")
	for i := 1; i <= 101; i++ {
		_, err := d.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, name, result_summary, status, started_at)
			VALUES (?, ?, 'tool', 't', 'r', 'ok', '2026-10-24T10:00:00Z')`, run, i)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body) VALUES (?, ?, 'inbox', 'T', 'b')`, a, run)
		require.NoError(t, err)
	}
	out, err := callRunTool(t, NewGetAutomationRun(Deps{DB: d}), `{"run_id":`+strconv.FormatInt(run, 10)+`}`)
	require.NoError(t, err)
	assert.Len(t, out["steps"], 100)
	assert.Len(t, out["outputs"], 100)
	assert.Equal(t, true, out["steps_truncated"])
	assert.Equal(t, true, out["outputs_truncated"])
	assert.EqualValues(t, 1, out["steps"].([]any)[0].(map[string]any)["seq"])

	// Exactly 100 is not truncated.
	_, err = d.Exec(`DELETE FROM automation_run_steps WHERE seq = 101`)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM automation_outputs WHERE id = (SELECT MAX(id) FROM automation_outputs)`)
	require.NoError(t, err)
	out, err = callRunTool(t, NewGetAutomationRun(Deps{DB: d}), `{"run_id":`+strconv.FormatInt(run, 10)+`}`)
	require.NoError(t, err)
	assert.Nil(t, out["steps_truncated"])
	assert.Nil(t, out["outputs_truncated"])
}
