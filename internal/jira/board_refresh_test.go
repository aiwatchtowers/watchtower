package jira

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// refreshTestDB seeds one selected board for the refresh tests. Field
// discovery is marked fresh with no useful fields and project_key is empty,
// so AnalyzeBoard never reaches the (nil) Jira client and FetchBoardRawData
// yields the same zero-value config — and so the same hash — every call.
func refreshTestDB(t *testing.T, configHash, generatedAt, overridesJSON string) *db.DB {
	t.Helper()
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO jira_custom_fields (account_id, id, name, field_type, is_useful, synced_at)
		VALUES (1, 'customfield_1', 'X', 'string', 0, ?)`, time.Now().UTC().Format(time.RFC3339))
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_boards (account_id, id, name, project_key, board_type, is_selected, issue_count, synced_at,
		config_hash, profile_generated_at, llm_profile_json, raw_columns_json, raw_config_json, workflow_summary, user_overrides_json)
		VALUES (1, 1, 'Test Board', '', 'scrum', 1, 0, ?, ?, ?, '{"workflow_stages":[{"name":"x"}]}', '[]', '{}', 'old', ?)`,
		time.Now().UTC().Format(time.RFC3339), configHash, generatedAt, overridesJSON)
	require.NoError(t, err)
	return d
}

// zeroConfigHash is the hash FetchBoardRawData produces for refreshTestDB's board.
func zeroConfigHash() string { return ComputeConfigHash(&BoardRawData{}) }

const freshProfileJSON = `{"workflow_stages":[{"name":"In Progress","phase":"active_work"}],
	"workflow_summary":"new summary","stale_thresholds":{"Code Review":5,"QA":7}}`

// A changed config inside the 24h cooldown is skipped without an LLM call.
func TestCheckAndRefreshProfiles_CooldownSkipsWithoutLLM(t *testing.T) {
	d := refreshTestDB(t, "oldhash", time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), "")
	gen := &scriptedAI{reply: freshProfileJSON}
	results, err := NewBoardAnalyzer(nil, d, gen, 1).CheckAndRefreshProfiles(context.Background(), true)
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.True(t, results[0].Skipped)
	assert.Empty(t, gen.calls)
}

// An unchanged config hash produces no result and no LLM call; with
// autoRefresh off a changed board is reported but not re-analyzed.
func TestCheckAndRefreshProfiles_UnchangedAndReportOnly(t *testing.T) {
	gen := &scriptedAI{reply: freshProfileJSON}
	d := refreshTestDB(t, zeroConfigHash(), "", "")
	results, err := NewBoardAnalyzer(nil, d, gen, 1).CheckAndRefreshProfiles(context.Background(), true)
	require.NoError(t, err)
	assert.Empty(t, results)

	d = refreshTestDB(t, "oldhash", "", "")
	results, err = NewBoardAnalyzer(nil, d, gen, 1).CheckAndRefreshProfiles(context.Background(), false)
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.False(t, results[0].Refreshed)
	assert.False(t, results[0].Skipped)
	assert.Empty(t, gen.calls, "report-only mode never calls the LLM")
}

// A changed board past its cooldown is re-analyzed: the new profile, summary
// and hash are stored, and the owner's stale-threshold overrides are merged
// back on top of the LLM's thresholds rather than lost.
func TestCheckAndRefreshProfiles_RefreshKeepsUserOverrides(t *testing.T) {
	d := refreshTestDB(t, "oldhash", time.Now().UTC().Add(-25*time.Hour).Format(time.RFC3339),
		`{"stale_thresholds":{"Code Review":1,"Deploy":2}}`)
	gen := &scriptedAI{reply: "```json\n" + freshProfileJSON + "\n```"}

	results, err := NewBoardAnalyzer(nil, d, gen, 1).CheckAndRefreshProfiles(context.Background(), true)
	require.NoError(t, err)
	require.Len(t, results, 1)
	require.NoError(t, results[0].Error)
	assert.True(t, results[0].Refreshed)
	require.Len(t, gen.calls, 1)

	board, err := d.GetJiraBoardProfile(1, 1)
	require.NoError(t, err)
	require.NotNil(t, board)
	assert.Equal(t, zeroConfigHash(), board.ConfigHash)
	assert.Equal(t, "new summary", board.WorkflowSummary)
	assert.JSONEq(t, `{"stale_thresholds":{"Code Review":1,"Deploy":2}}`, board.UserOverridesJSON, "overrides are kept")
	var profile BoardProfile
	require.NoError(t, json.Unmarshal([]byte(board.LLMProfileJSON), &profile))
	assert.Equal(t, map[string]int{"Code Review": 1, "QA": 7, "Deploy": 2}, profile.StaleThresholds,
		"override wins, LLM-only keys stay, override-only keys are added")
}

// mergeUserOverrides rejects unparseable overrides and leaves the stored
// profile untouched when there is nothing to merge.
func TestMergeUserOverrides_BadOrEmptyOverrides(t *testing.T) {
	d := refreshTestDB(t, "h", "", "")
	a := NewBoardAnalyzer(nil, d, nil, 1)
	profile := &BoardProfile{StaleThresholds: map[string]int{"QA": 7}}
	assert.ErrorContains(t, a.mergeUserOverrides(1, profile, "{not json"), "parsing user overrides")
	require.NoError(t, a.mergeUserOverrides(1, profile, `{"terminal_stages":{"Done":true}}`))
	board, err := d.GetJiraBoardProfile(1, 1)
	require.NoError(t, err)
	assert.JSONEq(t, `{"workflow_stages":[{"name":"x"}]}`, board.LLMProfileJSON, "no thresholds to merge, no write")
}

// CheckConfigChanged lists only boards whose stored hash differs from the
// live config.
func TestCheckConfigChanged(t *testing.T) {
	unchanged := refreshTestDB(t, zeroConfigHash(), "", "")
	ids, err := NewBoardAnalyzer(nil, unchanged, nil, 1).CheckConfigChanged(context.Background())
	require.NoError(t, err)
	assert.Empty(t, ids)

	changed := refreshTestDB(t, "oldhash", "", "")
	ids, err = NewBoardAnalyzer(nil, changed, nil, 1).CheckConfigChanged(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []int{1}, ids)
}

// AnalyzeAllSelected counts the boards it analyzed; a failing board is
// skipped, never an error for the whole pass.
func TestAnalyzeAllSelected(t *testing.T) {
	d := refreshTestDB(t, "oldhash", "", "")
	n, err := NewBoardAnalyzer(nil, d, &scriptedAI{reply: freshProfileJSON}, 1).AnalyzeAllSelected(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	d = refreshTestDB(t, "oldhash", "", "")
	n, err = NewBoardAnalyzer(nil, d, &scriptedAI{err: errors.New("down")}, 1).AnalyzeAllSelected(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)

	d = refreshTestDB(t, "oldhash", "", "")
	n, err = NewBoardAnalyzer(nil, d, &scriptedAI{reply: `{"workflow_stages":[]}`}, 1).AnalyzeAllSelected(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n, "an empty workflow is a failed analysis")
}
