package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

type fakeSpecReviewAgent struct {
	out    string
	calls  int
	folder string
}

func (a *fakeSpecReviewAgent) Review(context.Context, string, string) (string, bool, error) {
	a.calls++
	return a.out, true, nil
}

// useSpecReviewAgent swaps the agent factory: no test reaches claude/codex.
func useSpecReviewAgent(t *testing.T, a *fakeSpecReviewAgent) {
	t.Helper()
	old := specReviewAgentFactory
	specReviewAgentFactory = func(_ *config.Config, _, folder string) specreview.Agent {
		a.folder = folder
		return a
	}
	t.Cleanup(func() { specReviewAgentFactory = old })
}

const specReviewDoc = "# Spec\n\nGoal: mute a channel for a day.\n\n## Behaviour\n\nMuting lasts twenty-four hours.\n"

// specReviewAsk files a spec review ask on a fresh workbench, queued.
func specReviewAsk(t *testing.T) (*db.DB, int64, string) {
	t.Helper()
	database, wb, _, repo := reviewFixture(t)
	var id int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: wb, Kind: "review", Title: "Spec",
			DocPath: "docs/specs/x-design.md", DocSnapshot: specReviewDoc, DocType: "spec"})
		if err != nil {
			return err
		}
		return database.QueueSpecReview(tx, id, time.Now())
	}))
	return database, id, repo
}

func runSpecReview(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"spec-review"}, args...)...)
	resetSetFlags(workbenchSpecReviewCmd.Commands()...)
	return out, err
}

func TestSpecReviewShow_JSONKeysPinned(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	_, err := database.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, updated_at) VALUES (?, 'ag:0123456789ab', 'comment', 'why?', '2026-10-25T10:00:00Z')`, id)
	require.NoError(t, err)

	out, err := runSpecReview(t, "show", "--ask", itoa(id), "--json")
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"ask_id", "attempt", "dropped", "finished_at", "marks", "model", "provider",
		"queued_at", "reason", "result", "started_at", "status"}, keys)
	assert.Equal(t, "null", string(m["result"]), "no result yet")
	assert.JSONEq(t, `{"ag:0123456789ab":{"state":"comment","body":"why?","updated_at":"2026-10-25T10:00:00Z"}}`, string(m["marks"]))
}

func TestSpecReviewStart_RunningRefused(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	ok, err := database.ClaimSpecReview(id, 99, time.Now())
	require.NoError(t, err)
	require.True(t, ok)

	_, err = runSpecReview(t, "start", "--ask", itoa(id), "--force")
	require.Error(t, err)
	var ec *exitCodeError
	require.True(t, errors.As(err, &ec), "%v", err)
	assert.Equal(t, 3, ec.code)
	assert.Contains(t, err.Error(), "already running")
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "running", row.Status)
	assert.Equal(t, 99, row.PID)
}

func TestSpecReviewStart_ForceRequeuesFinished(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	ok, err := database.ClaimSpecReview(id, 99, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, database.FailSpecReview(id, 99, "boom", time.Now()))

	_, err = runSpecReview(t, "start", "--ask", itoa(id))
	var ec *exitCodeError
	require.True(t, errors.As(err, &ec), "%v", err)
	assert.Equal(t, 3, ec.code)

	_, err = runSpecReview(t, "start", "--ask", itoa(id), "--force")
	require.NoError(t, err) // launches /usr/bin/false (the test exe)
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "queued", row.Status)
	assert.Equal(t, 2, row.Attempt)
}

func TestSpecReviewStart_NotASpecRefused(t *testing.T) {
	database, wb, _, _ := reviewFixture(t)
	var id int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: wb, Kind: "review", Title: "Guide",
			DocPath: "docs/guide/a.md", DocSnapshot: "# A\n", DocType: "other"})
		return err
	}))
	_, err := runSpecReview(t, "start", "--ask", itoa(id))
	require.Error(t, err)
	_, err = database.GetSpecReview(id)
	assert.ErrorIs(t, err, db.ErrSpecReviewNotFound)
}

func TestSpecReviewRun_StoresResultThroughTheAgent(t *testing.T) {
	database, id, repo := specReviewAsk(t)
	agent := &fakeSpecReviewAgent{out: `{"summary":"Looks right.","agreements":[],"decided_alone":[],"blind_spots":[],"checks":[],"resolved":[],"notes":[]}`}
	useSpecReviewAgent(t, agent)

	_, err := runSpecReview(t, "run", "--ask", itoa(id))
	require.NoError(t, err)
	assert.Equal(t, 1, agent.calls)
	assert.Equal(t, repo, agent.folder, "no session: the workbench folder")
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)

	out, err := runSpecReview(t, "show", "--ask", itoa(id), "--json")
	require.NoError(t, err)
	var m struct {
		Result specreview.Result `json:"result"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	assert.Equal(t, "Looks right.", m.Result.Summary)
}
