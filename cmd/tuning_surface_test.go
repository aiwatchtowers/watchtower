package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tuning"
)

// tuningSurfaceEnv is a temp workspace and home (coachSetup), a workbench
// over folder, a tuning conversation on it and buildToolRegistry over the
// workspace's database with the real tuningDeps.
type tuningSurfaceEnv struct {
	d    *db.DB
	reg  *tools.Registry
	wb   int64
	conv int64
	home string
}

func newTuningSurfaceEnv(t *testing.T, folder string) *tuningSurfaceEnv {
	t.Helper()
	d := coachSetup(t)
	home, err := coachHome()
	require.NoError(t, err)
	wb, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	e := &tuningSurfaceEnv{d: d, reg: buildToolRegistry(cfg, d), wb: wb, home: home}
	e.conv = e.newConversation(t)
	return e
}

func (e *tuningSurfaceEnv) newConversation(t *testing.T) int64 {
	t.Helper()
	res, err := e.d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', ?, ?, 1, 1)`, tuning.ContextType, strconv.FormatInt(e.wb, 10))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func (e *tuningSurfaceEnv) binding(conv int64) tools.Binding {
	return tools.Binding{Surface: tools.SurfaceTuning, ConversationID: conv, ContextType: tuning.ContextType,
		ContextID: strconv.FormatInt(e.wb, 10), DirectApply: true}
}

func (e *tuningSurfaceEnv) propose(reg *tools.Registry, args map[string]any) (tools.Receipt, error) {
	raw, _ := json.Marshal(args)
	return reg.Propose(context.Background(), "propose_tuning_edit", raw, e.binding(e.conv))
}

func (e *tuningSurfaceEnv) count(t *testing.T, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, e.d.QueryRow(query, args...).Scan(&n))
	return n
}

func repoClaudeMDEdit() map[string]any {
	return map[string]any{"destination": coach.DestRepoClaudeMD, "kind": "add", "replace": "Run tests.",
		"title": "Run tests first", "why": "The owner asked twice.", "metric": "corrections"}
}

func claudeMDEdit(find, replace, title string) map[string]any {
	return map[string]any{"destination": coach.DestClaudeMDUser, "kind": "replace", "find": find, "replace": replace,
		"title": title, "why": "The owner asked twice.", "metric": "corrections"}
}

// A repository proposal through the registry the MCP child builds: filed
// while CLAUDE.md has uncommitted changes (the dirty check is Accept's, spec
// §4.3a), then refused by `coach accept` with code dirty; a folder that is
// not a git work tree is refused at propose. Proves tuningDeps wires
// CoachEnv.RepoState (a nil one refuses every repository proposal).
func TestTuningSurface_RepoProposalThroughRealRegistry(t *testing.T) {
	repo := gitBranchRepo(t)
	e := newTuningSurfaceEnv(t, repo)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "CLAUDE.md"), []byte("Mine.\n"), 0o644))

	rc, err := e.propose(e.reg, repoClaudeMDEdit())
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)
	ps, err := e.d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, ps, 1)
	assert.Equal(t, e.wb, ps[0].WorkbenchID, "the panel's workbench by default")

	out, err := runCoach(t, "", "accept", strconv.FormatInt(ps[0].ID, 10), "--json")
	require.Error(t, err)
	assert.JSONEq(t, `"dirty"`, string(coachJSONObject(t, out)["code"]))

	plain, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wbPlain, err := e.d.CreateWorkbench("acme-plain", plain)
	require.NoError(t, err)
	args := repoClaudeMDEdit()
	args["workbench_id"] = wbPlain
	_, err = e.propose(e.reg, args)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), coach.RepoNotGitLine)
	assert.Equal(t, 1, e.count(t, `SELECT COUNT(*) FROM coach_proposals`))
}

// Every write tool the tuning surface lists is propose_tuning_edit: a
// surface-less tool (refused by directApplyGate anyway) is not listed there.
func TestTuningSurface_OnlyWriteToolIsTheProposal(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	defer database.Close()
	reg := buildToolRegistry(&config.Config{ActiveWorkspace: "test-ws"}, database)
	require.NoError(t, reg.Register(&tools.Tool{Name: "surfaceless_write", Access: tools.AccessWrite,
		InputSchema: &jsonschema.Schema{Type: "object"},
		Validate:    func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:     func(context.Context, *db.DB, tools.Call) (any, error) { return nil, nil }}))
	var writes []string
	for _, tl := range reg.List(tools.SurfaceTuning) {
		if tl.Access != tools.AccessRead {
			writes = append(writes, tl.Name)
		}
	}
	assert.Equal(t, []string{"propose_tuning_edit"}, writes)
	assert.True(t, surfaceToolNames(reg, "main")["surfaceless_write"], "a surface-less tool stays on the other surfaces")
}

// The MCP child killed after its proposal committed: its agent_actions row is
// left executing; a new process's registry retrying the same call is refused
// by the fingerprint, and no second card appears.
func TestTuningSurface_ChildKilledAfterProposalCommit(t *testing.T) {
	e := newTuningSurfaceEnv(t, t.TempDir())
	writeClaudeMD(t, e.home, "Old line.\n")
	args := claudeMDEdit("Old line.", "New line.", "Say it new")
	rc, err := e.propose(e.reg, args)
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)
	ps, err := e.d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, ps, 1)
	_, err = e.d.Exec(`UPDATE agent_actions SET status = 'executing' WHERE id = ?`, rc.ActionID)
	require.NoError(t, err)

	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	_, err = e.propose(buildToolRegistry(cfg, e.d), args)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), fmt.Sprintf("already proposed as #%d", ps[0].ID))
	assert.Equal(t, 1, e.count(t, `SELECT COUNT(*) FROM coach_proposals`))
}

// READ-01 on the tuning surface: the budget is per conversation, so New
// starts a fresh one.
func TestTuningSurface_ReadLimitResetsOnNewConversation(t *testing.T) {
	e := newTuningSurfaceEnv(t, t.TempDir())
	e.reg.SetReadLimits(tools.ReadLimits{Calls: 1, Rows: 5000, ResponseRows: 200, ResponseBytes: 1 << 20})
	args := json.RawMessage(`{"prompt_id":"digest.channel"}`)
	_, err := e.reg.CallRead(context.Background(), "get_prompt", args, e.binding(e.conv))
	require.NoError(t, err)
	_, err = e.reg.CallRead(context.Background(), "get_prompt", args, e.binding(e.conv))
	assert.True(t, errors.Is(err, tools.ErrReadLimit), "%v", err)
	_, err = e.reg.CallRead(context.Background(), "get_prompt", args, e.binding(e.newConversation(t)))
	assert.NoError(t, err)
}

// Accept racing a new proposal on the same text: while A is open, B is
// refused (one open proposal per destination text); after Accept, B's find
// is checked against the changed file.
func TestTuningSurface_AcceptRacingNewProposal(t *testing.T) {
	e := newTuningSurfaceEnv(t, t.TempDir())
	writeClaudeMD(t, e.home, "old\n")
	rc, err := e.propose(e.reg, claudeMDEdit("old", "new", "Say new"))
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)
	ps, err := e.d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, ps, 1)
	a := ps[0].ID

	var ve *tools.ValidationError
	_, err = e.propose(e.reg, claudeMDEdit("old", "newer", "Say newer"))
	require.ErrorAs(t, err, &ve, "one open proposal per destination text")

	out, err := runCoach(t, "", "accept", strconv.FormatInt(a, 10), "--json")
	require.NoError(t, err, out)
	raw, err := os.ReadFile(filepath.Join(e.home, ".claude", "CLAUDE.md"))
	require.NoError(t, err)
	require.Equal(t, "new\n", string(raw))

	_, err = e.propose(e.reg, claudeMDEdit("old", "newer", "Say newer"))
	require.ErrorAs(t, err, &ve, "the old text is gone")
	rc, err = e.propose(e.reg, claudeMDEdit("new", "newer", "Say newer"))
	require.NoError(t, err)
	assert.Equal(t, "applied", rc.Status, rc.Message)
	assert.Equal(t, 2, e.count(t, `SELECT COUNT(*) FROM coach_proposals`))
}

// A tuning proposal writes only its own applied agent_actions row: a main
// chat's pending row is untouched (spec §4.1).
func TestTuningSurface_MainChatRowsUntouched(t *testing.T) {
	e := newTuningSurfaceEnv(t, t.TempDir())
	writeClaudeMD(t, e.home, "old\n")
	mainRC, err := e.reg.Propose(context.Background(), "create_target",
		json.RawMessage(`{"text":"Ship it","reason":"The owner asked."}`), tools.Binding{Surface: "main", ConversationID: 1})
	require.NoError(t, err)
	before, err := e.d.GetAgentAction(mainRC.ActionID)
	require.NoError(t, err)

	rc, err := e.propose(e.reg, claudeMDEdit("old", "new", "Say new"))
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)

	after, err := e.d.GetAgentAction(mainRC.ActionID)
	require.NoError(t, err)
	assert.Equal(t, before, after)
	assert.Equal(t, 1, e.count(t, `SELECT COUNT(*) FROM agent_actions WHERE surface = ?`, tools.SurfaceTuning))
}

// The tuning chat's turns are recorded under their own purpose, the literal
// the Desktop's TuningChatSurface.purpose sends.
func TestTuningSurface_ChatPurposeAccepted(t *testing.T) {
	assert.Equal(t, "tuning.chat", tuning.ChatPurpose)
	assert.True(t, queryPurposes[tuning.ChatPurpose])
}

func writeClaudeMD(t *testing.T, home, text string) {
	t.Helper()
	path := filepath.Join(home, ".claude", "CLAUDE.md")
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o644))
}

// tuningDeps' report adapters over the real `agents report` and `usage llm`:
// an empty workbench reports with no error, an unknown session is the
// tool's "not found", and the usage period reaches the report.
func TestTuningDeps_ReportsThroughRealRegistry(t *testing.T) {
	e := newTuningSurfaceEnv(t, t.TempDir())
	call := func(name, args string) (map[string]any, error) {
		res, err := e.reg.CallRead(context.Background(), name, json.RawMessage(args), e.binding(e.conv))
		if err != nil {
			return nil, err
		}
		raw, err := json.Marshal(res)
		require.NoError(t, err)
		var m map[string]any
		require.NoError(t, json.Unmarshal(raw, &m))
		return m, nil
	}
	for _, args := range []string{`{"days":0}`, `{"days":7,"agent":"codex"}`} {
		rep, err := call("get_agent_report", args)
		require.NoError(t, err, args)
		assert.Contains(t, rep, "sessions", args)
	}
	_, err := call("get_agent_session", `{"session":"nope"}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "session nope not found", ve.Msg)
	usage, err := call("get_llm_usage", `{"period":"7d"}`)
	require.NoError(t, err)
	assert.Equal(t, "7d", usage["period"])
}

// The tuning surface is no trust place: its binding applies directly and the
// card's Accept is the owner's approval, so the listing shows no trust for
// propose_tuning_edit and the CLI refuses to set one.
func TestTuningSurface_NoTrustPlace(t *testing.T) {
	writeActionsConfig(t)
	out, err := runActions(t, "tools", "--json")
	require.NoError(t, err)
	var listed []struct {
		Name           string            `json:"name"`
		TrustBySurface map[string]string `json:"trust_by_surface"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &listed), out)
	found := false
	for _, l := range listed {
		if l.Name == "propose_tuning_edit" {
			found = true
			assert.Empty(t, l.TrustBySurface)
		}
	}
	require.True(t, found, out)
	_, err = runActions(t, "trust", "propose_tuning_edit", "execute", "--surface", tools.SurfaceTuning)
	require.ErrorIs(t, err, tools.ErrSurfaceNotOffered)
}
