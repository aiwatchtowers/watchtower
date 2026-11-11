package tuning

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/prompts"
	"watchtower/internal/tools"
)

// proposeFixture is the read fixture with propose_tuning_edit registered, a
// real tuning conversation and a few owner files: ~/.claude/CLAUDE.md, Claude
// skills "a" and "crlf", and an empty Codex rules file.
func proposeFixture(t *testing.T) (*fixture, int64) {
	t.Helper()
	f := newFixture(t)
	for _, tl := range ProposalTools(f.deps) {
		require.NoError(t, f.reg.Register(tl))
	}
	res, err := f.d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', ?, ?, 1, 1)`, ContextType, fmt.Sprint(f.wb))
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	env := coach.Env{Home: f.home}
	put(t, filepath.Join(f.home, ".claude", "CLAUDE.md"), "Alpha line.\nBeta.\nBeta.\n")
	put(t, coach.ClaudeSkillPath(env, "a"), "Read the plan.\nRun tests.\n")
	put(t, coach.ClaudeSkillPath(env, "crlf"), "a\r\nb\r\n")
	put(t, filepath.Join(f.home, ".codex", "rules", "default.rules"), "")
	return f, conv
}

func (f *fixture) tuningBinding(conv int64) tools.Binding {
	b := f.binding(fmt.Sprint(f.wb))
	b.ConversationID = conv
	return b
}

func (f *fixture) propose(conv int64, args map[string]any) (tools.Receipt, error) {
	raw, _ := json.Marshal(args)
	return f.reg.Propose(context.Background(), proposeToolName, raw, f.tuningBinding(conv))
}

func (f *fixture) count(t *testing.T, table string) int {
	t.Helper()
	var n int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n))
	return n
}

// skillEdit appends a line to Claude skill "a".
func skillEdit(over map[string]any) map[string]any {
	a := map[string]any{"destination": coach.DestClaudeSkillUser, "skill": "a", "kind": "add",
		"replace": "Check the board.", "title": "Check the board first", "why": "The owner asked twice.",
		"metric": "corrections"}
	for k, v := range over {
		if v == nil {
			delete(a, k)
			continue
		}
		a[k] = v
	}
	return a
}

func TestProposeTuningEdit_Shape(t *testing.T) {
	ts := ProposalTools(Deps{})
	require.Len(t, ts, 1)
	tl := ts[0]
	assert.Equal(t, proposeToolName, tl.Name)
	assert.Equal(t, tools.AccessWrite, tl.Access)
	assert.False(t, tl.External)
	assert.False(t, tl.AlwaysAsk)
	assert.False(t, tl.CompanyData)
	assert.Equal(t, []string{tools.SurfaceTuning}, tl.Surfaces)
}

func TestProposeTuningEdit_FilesChatProposal(t *testing.T) {
	f, conv := proposeFixture(t)
	rc, err := f.propose(conv, skillEdit(map[string]any{"refs": []string{"s12", "nonsense"}}))
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)

	ps, err := f.d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, ps, 1)
	p := ps[0]
	assert.Equal(t, "chat", p.Origin)
	require.NotNil(t, p.ConversationID)
	assert.Equal(t, conv, *p.ConversationID)
	require.NotEmpty(t, p.Evidence)
	assert.Equal(t, db.CoachEvidence{Kind: "chat", Ref: fmt.Sprintf("c%d", conv)}, p.Evidence[0])
	assert.Equal(t, []db.CoachEvidence{{Kind: "chat", Ref: fmt.Sprintf("c%d", conv)}, {Kind: "session", Ref: "s12"}}, p.Evidence)
	assert.Equal(t, 2, p.Sources)
	assert.Equal(t, "a", p.Skill)
	assert.Equal(t, "Read the plan.\nRun tests.\nCheck the board.", p.AfterText)

	rows, err := f.d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, tools.SurfaceTuning, rows[0].Surface)
	assert.Equal(t, "applied", rows[0].Status)
	var result map[string]any
	require.NoError(t, json.Unmarshal([]byte(rows[0].ResultJSON), &result))
	assert.Equal(t, map[string]any{"proposal_id": float64(p.ID), "status": "open"}, result)
}

func TestProposeTuningEdit_After(t *testing.T) {
	cases := []struct {
		name, find, after, want string
	}{
		{"after a line", "Read the plan.", "Check the board.", "Read the plan.\nCheck the board.\nRun tests.\n"},
		{"after a line with its newline", "Read the plan.\n", "Check the board.\n", "Read the plan.\nCheck the board.\nRun tests.\n"},
		{"append", "", "Check the board.", "Read the plan.\nRun tests.\nCheck the board."},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, conv := proposeFixture(t)
			args := skillEdit(map[string]any{"replace": nil, "after": tc.after})
			if tc.find != "" {
				args["find"] = tc.find
			}
			rc, err := f.propose(conv, args)
			require.NoError(t, err)
			require.Equal(t, "applied", rc.Status, rc.Message)
			ps, err := f.d.ListCoachProposals("open")
			require.NoError(t, err)
			require.Len(t, ps, 1)
			assert.Equal(t, tc.want, ps[0].AfterText)
		})
	}
}

func TestProposeTuningEdit_Refusals(t *testing.T) {
	builtin := prompts.BriefingDaily
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"find matches nothing", map[string]any{"destination": coach.DestClaudeMDUser, "skill": nil,
			"find": "Gamma.", "kind": "replace"}, "find matches no text"},
		{"find matches twice", map[string]any{"destination": coach.DestClaudeMDUser, "skill": nil,
			"find": "Beta.", "kind": "replace"}, "find matches 2 times; it must match once"},
		{"find part of a line", map[string]any{"destination": coach.DestClaudeMDUser, "skill": nil,
			"find": "Alpha", "kind": "replace"}, "find must cover whole lines"},
		{"find across CRLF ends", map[string]any{"skill": "crlf", "find": "a\nb", "kind": "replace"},
			"find matches no text"},
		{"replace past the budget", map[string]any{"destination": coach.DestChat, "skill": nil,
			"replace": strings.Repeat("word ", 2000)}, "over its budget"},
		{"replace and after", map[string]any{"after": "More."}, "use replace or after, not both"},
		{"empty title", map[string]any{"title": " "}, "title and why are required"},
		{"empty why", map[string]any{"why": ""}, "title and why are required"},
		{"prompt addition without prompt", map[string]any{"destination": coach.DestPromptAdd, "skill": nil},
			"prompt_addition needs prompt_id"},
		{"built-in automation prompt", map[string]any{"destination": coach.DestPromptAdd, "skill": nil,
			"prompt_id": builtin}, builtin + " belongs to a built-in automation"},
		{"custom-track prompt", map[string]any{"destination": coach.DestPromptAdd, "skill": nil,
			"prompt_id": prompts.TrackRun}, prompts.TrackRun + " does not take additions"},
		{"skill missing", map[string]any{"skill": nil}, "claude_skill_user needs skill"},
		{"pack skill as a user skill", map[string]any{"skill": devpack.WorkbenchSkillName},
			devpack.WorkbenchSkillName + " is a Watchtower pack skill: propose a pack_overlay"},
		{"unsafe Codex allow line", map[string]any{"destination": coach.DestCodexRulesAllow, "skill": nil,
			"replace": `prefix_rule(pattern=["rm"], decision="allow")`}, "is not a safe read, search, build or test command"},
		{"repo file outside git", map[string]any{"destination": coach.DestRepoClaudeMD, "skill": nil},
			coach.RepoNotGitLine},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, conv := proposeFixture(t)
			_, err := f.propose(conv, skillEdit(tc.args))
			var ve *tools.ValidationError
			require.ErrorAs(t, err, &ve)
			assert.Contains(t, err.Error(), tc.want)
			assert.Zero(t, f.count(t, "agent_actions"))
			assert.Zero(t, f.count(t, "coach_proposals"))
		})
	}
}

func TestProposeTuningEdit_RepoFileDefaultsToThePanelsWorkbench(t *testing.T) {
	f, conv := proposeFixture(t)
	f.repoWorkbench(t, map[string]string{"CLAUDE.md": "Use make.\n"})
	_, err := f.d.Exec(`UPDATE chat_conversations SET context_id = ? WHERE id = ?`, fmt.Sprint(f.wb), conv)
	require.NoError(t, err)

	rc, err := f.propose(conv, skillEdit(map[string]any{"destination": coach.DestRepoClaudeMD, "skill": nil}))
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, rc.Message)
	ps, err := f.d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, ps, 1)
	assert.Equal(t, f.wb, ps[0].WorkbenchID)
	assert.Equal(t, coach.DestRepoClaudeMD, ps[0].Destination)
}

func TestProposeTuningEdit_ConversationRemoved(t *testing.T) {
	f, conv := proposeFixture(t)
	_, err := f.d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)

	_, err = f.propose(conv, skillEdit(nil))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "conversation removed")
	assert.Zero(t, f.count(t, "coach_proposals"))
	assert.Zero(t, f.count(t, "agent_actions"))
}

// The conversation can go between the check and the insert: the insert's
// own check answers, and nothing is filed.
func TestProposeTuningEdit_ConversationRemovedAtInsert(t *testing.T) {
	f, conv := proposeFixture(t)
	p, err := validateProposal(context.Background(), f.d, f.deps, mustJSON(t, skillEdit(nil)), f.tuningBinding(conv))
	require.NoError(t, err)
	_, err = f.d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)

	_, err = fileProposal(f.d, p, conv, testNow)
	require.EqualError(t, err, "conversation removed")
	assert.Zero(t, f.count(t, "coach_proposals"))
}

// A concurrent call filed the same edit between validation and the insert:
// the fingerprint conflict is "already proposed as #N", never a success.
func TestProposeTuningEdit_FingerprintRaceIsAlreadyProposed(t *testing.T) {
	f, conv := proposeFixture(t)
	p, err := validateProposal(context.Background(), f.d, f.deps, mustJSON(t, skillEdit(nil)), f.tuningBinding(conv))
	require.NoError(t, err)
	first, err := fileProposal(f.d, p, conv, testNow)
	require.NoError(t, err)

	_, err = fileProposal(f.d, p, conv, testNow)
	require.EqualError(t, err, fmt.Sprintf("already proposed as #%d", first))
	assert.Equal(t, 1, f.count(t, "coach_proposals"))

	// Through the tool, the coach's own check answers first.
	_, err = f.propose(conv, skillEdit(nil))
	assert.ErrorContains(t, err, fmt.Sprintf("already proposed as #%d (open)", first))
}

func TestProposeTuningEdit_NotFound(t *testing.T) {
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"workbench", map[string]any{"destination": coach.DestRepoClaudeMD, "skill": nil, "workbench_id": 99},
			"workbench 99 not found"},
		{"prompt", map[string]any{"destination": coach.DestPromptAdd, "skill": nil, "prompt_id": "nope"},
			"prompt nope not found"},
		{"skill", map[string]any{"skill": "nope"}, "skill nope not found"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, conv := proposeFixture(t)
			_, err := f.propose(conv, skillEdit(tc.args))
			var ve *tools.ValidationError
			require.ErrorAs(t, err, &ve)
			assert.Contains(t, err.Error(), tc.want)
			assert.Zero(t, f.count(t, "agent_actions"))
			assert.Zero(t, f.count(t, "coach_proposals"))
		})
	}
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	require.NoError(t, err)
	return raw
}
