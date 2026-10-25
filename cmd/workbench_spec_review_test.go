package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
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

func (a *fakeSpecReviewAgent) Review(_ context.Context, folder, _, _ string) (string, bool, error) {
	a.calls++
	a.folder = folder
	return a.out, true, nil
}

// useSpecReviewAgent swaps the agent factory: no test reaches claude/codex.
func useSpecReviewAgent(t *testing.T, a *fakeSpecReviewAgent) {
	t.Helper()
	old := specReviewAgentFactory
	specReviewAgentFactory = func(*config.Config) specreview.Agent { return a }
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
	assert.Equal(t, 1, row.Attempt, "the owner's run starts the sweep's launch count over")
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

// Ruling 8: the claude reviewer mounts no MCP server and runs read-only in
// the folder within the turn cap.
func TestSpecReviewClaudeClient_NoMCPReadFolder(t *testing.T) {
	folder := t.TempDir()
	// /usr/bin/false: argv building never reaches a real claude.
	args := specReviewClaudeClient(&config.Config{ClaudePath: "/usr/bin/false"}, "strong", folder).ArgsForTest("sys", "user")
	require.NotNil(t, args)
	assert.NotContains(t, args, "--mcp-config")
	assert.Contains(t, args, "--strict-mcp-config")
	turns := slices.Index(args, "--max-turns")
	require.GreaterOrEqual(t, turns, 0)
	assert.Equal(t, strconv.Itoa(specreview.MaxTurns), args[turns+1])
	src := slices.Index(args, "--setting-sources")
	require.GreaterOrEqual(t, src, 0)
	assert.Equal(t, "", args[src+1], "a read-folder run loads no settings")
	tools := slices.Index(args, "--tools")
	require.GreaterOrEqual(t, tools, 0)
	assert.Contains(t, args[tools+1], "Read")
	assert.NotContains(t, args[tools+1], "Bash")
}

// Ruling 8: the codex reviewer disables the owner's servers and mounts none.
func TestSpecReviewCodexClient_NoMCPServers(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"), []byte("[mcp_servers.mine]\ncommand = \"npx\"\n"), 0o600))
	t.Setenv("CODEX_HOME", home)
	folder := t.TempDir()
	// /usr/bin/false: the version probe never runs a real codex.
	args := specReviewCodexClient(&config.Config{CodexPath: "/usr/bin/false"}, "strong", folder).ArgsForTest("sys", "user")
	require.NotNil(t, args)
	joined := strings.Join(args, "\x00")
	assert.Contains(t, joined, `"mine"={enabled=false}`, "the owner's server is switched off")
	assert.NotContains(t, joined, "--db-path")
	assert.NotContains(t, joined, "enabled=true")
	sandbox := slices.Index(args, "--sandbox")
	require.GreaterOrEqual(t, sandbox, 0)
	assert.Equal(t, "read-only", args[sandbox+1])
	cd := slices.Index(args, "--cd")
	require.GreaterOrEqual(t, cd, 0)
	assert.Equal(t, folder, args[cd+1])
}

// No claude or codex run ever starts without a read folder.
func TestSpecReviewCLIAgent_EmptyFolderRefused(t *testing.T) {
	for _, p := range []string{"claude", "codex"} {
		a := &specReviewCLIAgent{cfg: &config.Config{AI: config.AIConfig{Provider: p}}, model: "m"}
		_, codeRead, err := a.Review(context.Background(), "", "sys", "user")
		require.Error(t, err, p)
		assert.False(t, codeRead, p)
	}
}
