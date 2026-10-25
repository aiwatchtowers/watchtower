package specreview

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/sessionfeed"
)

// fakeAgent answers out (or err) and runs during, if set, before it returns.
type fakeAgent struct {
	out          string
	err          error
	codeRead     bool
	calls        int
	system, user string
	folder       string
	during       func()
	sawDeadline  bool
}

func (a *fakeAgent) Review(ctx context.Context, folder, system, user string) (string, bool, error) {
	a.calls++
	a.folder = folder
	a.system, a.user = system, user
	_, a.sawDeadline = ctx.Deadline()
	if a.during != nil {
		a.during()
	}
	return a.out, a.codeRead, a.err
}

const runDoc = "# Spec\n\nGoal: the owner can mute a channel for a day.\n\n## Behaviour\n\nMuting lasts twenty-four hours\nand then expires by itself.\n"

// runReply has two agreements: the first quotes the conversation, the second
// cites a quote nobody said.
const runReply = `{
  "summary": "The spec matches the idea.",
  "idea": {"owner_quote": "mute a channel for a day", "goal_quote": "the owner can mute a channel for a day", "verdict": "matches", "note": "Same.",
           "owner_source": {"kind": "conversation", "ref": "entry:e1", "quote": "mute a channel for a day"}},
  "agreements": [
    {"text": "A mute lasts a day", "status": "as_agreed", "note": "ok",
     "source": {"kind": "conversation", "ref": "entry:e1", "quote": "mute a channel for a day"},
     "where": {"heading": "Behaviour", "quote": "Muting lasts twenty-four hours"}},
    {"text": "Mutes sync to the phone", "status": "missing", "note": "invented",
     "source": {"kind": "conversation", "ref": "entry:e1", "quote": "sync every mute to my phone"}, "where": null}
  ],
  "decided_alone": [], "blind_spots": [], "checks": [], "resolved": [], "notes": []
}`

func runFixture(t *testing.T) (*fixture, int64) {
	t.Helper()
	f := newFixture(t)
	f.feed = []sessionfeed.Entry{{ID: "e1", Kind: sessionfeed.KindOwner, Text: "Please let me mute a channel for a day."}}
	return f, f.ask(t, "spec", runDoc).ID
}

func TestRun_StoresValidatedResult(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply, codeRead: true}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	assert.Equal(t, 1, agent.calls)
	assert.Equal(t, "SYSTEM", agent.system)
	assert.Contains(t, agent.user, "=== DATA ===")
	assert.True(t, agent.sawDeadline, "the agent runs under RunTimeout")
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)
	assert.Equal(t, 1, row.Dropped)
	assert.Equal(t, "claude", row.Provider)
	assert.Equal(t, "strong-model", row.Model)
	sum := sha256.Sum256([]byte(runDoc))
	assert.Equal(t, hex.EncodeToString(sum[:]), row.DocSHA)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.Equal(t, "The spec matches the idea.", res.Summary)
	require.Len(t, res.Agreements, 1)
	assert.Equal(t, "A mute lasts a day", res.Agreements[0].Text)
	assert.True(t, res.CodeRead)
	assert.Equal(t, 1, res.Dropped)
}

func TestRun_LostClaimDoesNothing(t *testing.T) {
	f, askID := runFixture(t)
	ok, err := f.d.ClaimSpecReview(askID, 1, runNow)
	require.NoError(t, err)
	require.True(t, ok)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	assert.Zero(t, agent.calls)
	assert.Zero(t, f.feedCalls)
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "running", row.Status)
	assert.Equal(t, 1, row.PID)
}

func TestRun_AgentErrorFails(t *testing.T) {
	f, askID := runFixture(t)
	before, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	agent := &fakeAgent{err: errors.New("claude exited\nwith status 1")}
	require.Error(t, Run(context.Background(), f.deps(agent), askID))

	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Reason, "claude exited with status 1")
	assert.NotContains(t, row.Reason, "\n")
	assert.Empty(t, row.Result)
	after, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	assert.Equal(t, before, after, "the ask is unchanged")
}

func TestRun_BadReplyFails(t *testing.T) {
	f, askID := runFixture(t)
	require.Error(t, Run(context.Background(), f.deps(&fakeAgent{out: "not json"}), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.NotEmpty(t, row.Reason)
}

func TestRun_NotASpecFails(t *testing.T) {
	f := newFixture(t)
	a := f.ask(t, "other", runDoc)
	agent := &fakeAgent{out: runReply}
	require.Error(t, Run(context.Background(), f.deps(agent), a.ID))
	assert.Zero(t, agent.calls)
	row, err := f.d.GetSpecReview(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
}

func TestRun_AskWithdrawnMidRun(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply, during: func() {
		require.NoError(t, f.d.WithdrawOwnerAsk(f.wb, askID, "agent"))
	}}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)
	assert.NotEmpty(t, row.Result)
	a, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	assert.Equal(t, "withdrawn", a.Status)
}

func TestRun_FeedErrorIsANote(t *testing.T) {
	f, askID := runFixture(t)
	f.feedErr = errors.New("transcript gone")
	agent := &fakeAgent{out: `{"summary":"ok","agreements":[],"decided_alone":[],"blind_spots":[],"checks":[],"resolved":[],"notes":["model note"]}`}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.True(t, hasNote(res.Notes, "conversation not read: transcript gone"), "notes = %v", res.Notes)
	assert.True(t, hasNote(res.Notes, "model note"))
}

func TestRun_AgentGetsTheResolvedFolder(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	assert.Equal(t, f.folder, agent.folder, "no agent_cwd: the workbench folder")
}

func TestRun_AgentCwdWorktreeWins(t *testing.T) {
	f, askID := runFixture(t)
	wt := t.TempDir()
	_, err := f.d.Exec(`UPDATE terminal_sessions SET agent_cwd = ? WHERE id = ?`, wt, f.session)
	require.NoError(t, err)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	assert.Equal(t, wt, agent.folder)
}

// No readable folder: the run fails before any agent call, never runs the
// agent outside a read folder.
func TestRun_NoReadableFolderFails(t *testing.T) {
	f, askID := runFixture(t)
	_, err := f.d.Exec(`UPDATE projects SET folder_path = ? WHERE id = ?`, f.folder+"/gone", f.wb)
	require.NoError(t, err)
	agent := &fakeAgent{out: runReply}
	require.Error(t, Run(context.Background(), f.deps(agent), askID))
	assert.Zero(t, agent.calls)
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Reason, "not a readable directory")
}
