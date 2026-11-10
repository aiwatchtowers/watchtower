package coach

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/prompts"
)

// chatEnv is a temp home and Codex home with a few owner files: Claude skills
// "a", "crlf", "twice" and "marked" (an installed pack copy under its own
// name), and an empty Codex rules file.
func chatEnv(t *testing.T, d dbs) (Env, *Applier) {
	t.Helper()
	a := fileApplier(t, d)
	env := a.env()
	writeFile(t, ClaudeSkillPath(env, "a"), "Read the plan.\nRun tests.\n")
	writeFile(t, ClaudeSkillPath(env, "crlf"), "a\r\nb\r\n")
	writeFile(t, ClaudeSkillPath(env, "twice"), "x\ny\nx\n")
	writeFile(t, ClaudeSkillPath(env, "marked"), "---\nname: marked\n"+devpack.MarkerKey+": 1\n---\nBody.\n")
	writeFile(t, codexRulesPath(env), "")
	writeFile(t, claudeSettingsPath(env.Home), `{"permissions":{"allow":["Bash(ls:*)"]}}`)
	return env, a
}

// chatEdit is a valid edit appending a line to Claude skill "a".
func chatEdit() ChatEdit {
	return ChatEdit{Destination: DestClaudeSkillUser, Skill: "a", Kind: "add", Replace: "Check the board.",
		Title: "Check the board first", Why: "The owner asked for it twice.", Metric: "corrections",
		Evidence: []string{"c7"}}
}

func TestValidateChatProposal_Refusals(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	wb, _ := d.workbench(t, "acme", 0)

	// An open proposal on the session text of the workbench (rule 12) and a
	// declined one whose edit is proposed again (rule 11).
	open := propose(t, d, db.CoachProposal{Destination: DestSession, WorkbenchID: wb, Fingerprint: "open-session"})
	sameEdit := ChatEdit{Destination: DestChat, Kind: "add", Replace: "Answer briefly.", Title: "t", Why: "w",
		Metric: "corrections"}
	first, err := ValidateChatProposal(context.Background(), d.DB, sameEdit, env)
	require.NoError(t, err)
	declined := propose(t, d, first)
	require.NoError(t, d.DecideCoachProposal(declined, "open", "declined", applyNow))

	with := func(f func(e *ChatEdit)) ChatEdit {
		e := chatEdit()
		f(&e)
		return e
	}
	pack := devpack.WorkbenchSkillName
	cases := []struct {
		name string
		edit ChatEdit
		want string
	}{
		{"unknown destination", with(func(e *ChatEdit) { e.Destination = "repo_readme" }),
			`destination "repo_readme" cannot be edited from the chat`},
		{"empty title", with(func(e *ChatEdit) { e.Title = "  " }), "title and why are required"},
		{"empty why", with(func(e *ChatEdit) { e.Why = "" }), "title and why are required"},
		{"long title", with(func(e *ChatEdit) { e.Title = strings.Repeat("t", 121) }), "title is over 120 characters"},
		{"long why", with(func(e *ChatEdit) { e.Why = strings.Repeat("w", 601) }), "why is over 600 characters"},
		{"bad kind", with(func(e *ChatEdit) { e.Kind = "move" }), "kind must be add, cut or replace"},
		{"bad metric", with(func(e *ChatEdit) { e.Metric = "speed" }),
			"metric must be corrections, task_cost, owner_loop or review_findings"},
		{"prompt id missing", with(func(e *ChatEdit) { e.Destination, e.Skill = DestPromptAdd, "" }),
			"prompt_addition needs prompt_id"},
		{"skill missing", with(func(e *ChatEdit) { e.Skill = "" }), "claude_skill_user needs skill"},
		{"prompt id elsewhere", with(func(e *ChatEdit) { e.PromptID = prompts.SpecReview }),
			"claude_skill_user takes no prompt_id"},
		{"skill elsewhere", with(func(e *ChatEdit) { e.Destination = DestChat }), "chat takes no skill"},
		{"workbench on a global text", with(func(e *ChatEdit) { e.WorkbenchID = wb }),
			"claude_skill_user has no per-workbench text"},
		{"no such workbench", with(func(e *ChatEdit) { e.Destination, e.Skill, e.WorkbenchID = DestSession, "", 999 }),
			"workbench 999 not found"},
		{"unknown prompt", with(func(e *ChatEdit) { e.Destination, e.Skill, e.PromptID = DestPromptAdd, "", "no.such" }),
			"unknown prompt no.such"},
		{"built-in prompt", with(func(e *ChatEdit) {
			e.Destination, e.Skill, e.PromptID = DestPromptAdd, "", prompts.BriefingDaily
		}), prompts.BriefingDaily + " belongs to a built-in automation"},
		{"custom-track prompt", with(func(e *ChatEdit) {
			e.Destination, e.Skill, e.PromptID = DestPromptAdd, "", prompts.TrackRun
		}), prompts.TrackRun + " does not take additions"},
		{"bad skill name", with(func(e *ChatEdit) { e.Skill = "../x" }), `"../x" is not a skill name`},
		{"overlay of a non-pack skill", with(func(e *ChatEdit) { e.Destination = DestPackOverlay }),
			"a is not a Watchtower pack skill"},
		{"pack skill as a user skill", with(func(e *ChatEdit) { e.Skill = pack }),
			pack + " is a Watchtower pack skill: propose a pack_overlay"},
		{"marked copy as a user skill", with(func(e *ChatEdit) { e.Skill = "marked" }),
			"marked is a Watchtower pack skill: propose a pack_overlay"},
		{"skill not found", with(func(e *ChatEdit) { e.Skill = "gone" }), "skill gone not found"},
		{"find matches nothing", with(func(e *ChatEdit) { e.Find = "Lint." }), "find matches no text"},
		{"find twice", with(func(e *ChatEdit) { e.Skill, e.Find, e.Kind = "twice", "x", "replace" }),
			"find matches 2 times; it must match once"},
		{"part of a line", with(func(e *ChatEdit) { e.Find, e.Kind = "the plan", "replace" }),
			"find must cover whole lines"},
		{"crlf across lines", with(func(e *ChatEdit) { e.Skill, e.Find, e.Kind = "crlf", "a\nb", "replace" }),
			"find matches no text"},
		{"crlf line", with(func(e *ChatEdit) { e.Skill, e.Find, e.Kind = "crlf", "a", "replace" }),
			"find must cover whole lines"},
		{"allow find absent", with(func(e *ChatEdit) { e.Destination, e.Skill, e.Find = DestSettingsAllow, "", "Bash(cat:*)" }),
			"find matches no text"},
		{"allow with find", with(func(e *ChatEdit) { e.Destination, e.Skill, e.Find = DestSettingsAllow, "", "Bash(ls:*)" }),
			"the allow rules may only grow: leave find empty"},
		{"changes nothing", with(func(e *ChatEdit) { e.Find, e.Replace, e.Kind = "Run tests.\n", "Run tests.\n", "replace" }),
			"the edit changes nothing"},
		{"kind does not fit", with(func(e *ChatEdit) { e.Kind = "cut" }), "kind cut does not fit the edit"},
		{"skill over budget", with(func(e *ChatEdit) { e.Replace = strings.Repeat("z", skillGrowth+40) }),
			fmt.Sprintf("the text is over its budget of %d characters", skillBudget(len("Read the plan.\nRun tests.\n")))},
		{"unsafe codex rule", with(func(e *ChatEdit) {
			e.Destination, e.Skill, e.Replace = DestCodexRulesAllow, "", `prefix_rule(pattern=["rm"], decision="allow")`
		}), validateCodexRules("", `prefix_rule(pattern=["rm"], decision="allow")`+"\n").Error()},
		{"spacing only", with(func(e *ChatEdit) { e.Find, e.Replace, e.Kind = "Run tests.\n", "run tests\n", "replace" }),
			"the edit changes only spacing, case or punctuation"},
		{"same edit again", sameEdit, fmt.Sprintf("already proposed as #%d (declined)", declined)},
		{"text busy", with(func(e *ChatEdit) { e.Destination, e.Skill, e.WorkbenchID = DestSession, "", wb }),
			fmt.Sprintf("proposal #%d is already open for this text — decide it first", open)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ValidateChatProposal(context.Background(), d.DB, c.edit, env)
			require.Error(t, err)
			assert.ErrorIs(t, err, ErrRefused)
			assert.Equal(t, c.want, err.Error())
		})
	}

	t.Run("cancelled context", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := ValidateChatProposal(ctx, d.DB, chatEdit(), env)
		require.ErrorIs(t, err, context.Canceled)
		assert.NotErrorIs(t, err, ErrRefused)
	})
}

func TestValidateChatProposal_ReadyForInsert(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	e := chatEdit()
	e.Title = "  Check   the board\nfirst "
	e.Why = "  The owner asked for it twice.  "
	e.Evidence = []string{"c7", "s1", "c7", "bogus", "ask:4#f1", "ask:4#f2"}
	p, err := ValidateChatProposal(context.Background(), d.DB, e, env)
	require.NoError(t, err)
	assert.Equal(t, "chat", p.Origin)
	assert.Equal(t, DestClaudeSkillUser, p.Destination)
	assert.Equal(t, "a", p.Skill)
	assert.Empty(t, p.PromptID)
	assert.Equal(t, "Check the board first", p.Title)
	assert.Equal(t, "The owner asked for it twice.", p.Why)
	assert.Equal(t, "Read the plan.\nRun tests.\n", p.BeforeText)
	assert.Equal(t, "Read the plan.\nRun tests.\nCheck the board.", p.AfterText)
	assert.NotEmpty(t, p.Fingerprint)
	assert.Equal(t, []db.CoachEvidence{{Kind: "chat", Ref: "c7"}, {Kind: "session", Ref: "s1"},
		{Kind: "ask", Ref: "ask:4#f1"}, {Kind: "ask", Ref: "ask:4#f2"}}, p.Evidence)
	assert.Equal(t, 3, p.Sources)

	conv := newConversation(t, d)
	id, err := d.InsertChatCoachProposal(p, &conv, applyNow)
	require.NoError(t, err)
	assert.NotZero(t, id)
}

func TestValidateChatProposal_NoSourceFloorNoCap(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	for i, dest := range []string{DestSession, DestProcedure, DestChat} {
		propose(t, d, db.CoachProposal{Destination: dest, Fingerprint: fmt.Sprintf("weekly%d", i)})
	}
	for _, skill := range []string{"crlf", "twice", "x"} {
		p := db.CoachProposal{Destination: DestClaudeSkillUser, Skill: skill, Fingerprint: "chat-" + skill,
			Kind: "add", Metric: "corrections", Title: "t", Why: "w", Sources: 1}
		_, err := d.InsertChatCoachProposal(p, nil, t0)
		require.NoError(t, err)
	}
	p, err := ValidateChatProposal(context.Background(), d.DB, chatEdit(), env)
	require.NoError(t, err)
	assert.Equal(t, "chat", p.Origin)
	assert.Equal(t, 1, p.Sources)
}

func TestValidateChatProposal_SkillsAreSeparateTexts(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	writeFile(t, ClaudeSkillPath(env, "b"), "Read the plan.\n")
	p, err := ValidateChatProposal(context.Background(), d.DB, chatEdit(), env)
	require.NoError(t, err)
	id, err := d.InsertChatCoachProposal(p, nil, applyNow)
	require.NoError(t, err)

	b := chatEdit()
	b.Skill = "b"
	_, err = ValidateChatProposal(context.Background(), d.DB, b, env)
	require.NoError(t, err)

	again := chatEdit()
	again.Replace = "Ask before deleting."
	_, err = ValidateChatProposal(context.Background(), d.DB, again, env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, fmt.Sprintf("proposal #%d is already open for this text — decide it first", id), err.Error())
}

func TestValidateChatProposal_AfterAcceptRevalidates(t *testing.T) {
	d := openDBs(t)
	env, a := chatEnv(t, d)
	writeFile(t, codexAgentsMDPath(env), "Keep answers short.\n")
	p1Edit := ChatEdit{Destination: DestCodexAgentsMDUser, Kind: "replace", Find: "Keep answers short.\n",
		Replace: "Keep answers short and plain.\n", Title: "Plain answers", Why: "w", Metric: "corrections"}
	p1, err := ValidateChatProposal(context.Background(), d.DB, p1Edit, env)
	require.NoError(t, err)
	id1, err := d.InsertChatCoachProposal(p1, nil, applyNow)
	require.NoError(t, err)

	p2Edit := ChatEdit{Destination: DestCodexAgentsMDUser, Kind: "add", Find: "Keep answers short.\n",
		Replace: "Keep answers short.\nName the file.\n", Title: "Name files", Why: "w", Metric: "corrections"}
	_, err = ValidateChatProposal(context.Background(), d.DB, p2Edit, env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, fmt.Sprintf("proposal #%d is already open for this text — decide it first", id1), err.Error())

	require.NoError(t, a.acceptErr(id1, ""))
	_, err = ValidateChatProposal(context.Background(), d.DB, p2Edit, env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, "find matches no text", err.Error())

	p2Edit.Find, p2Edit.Replace = "Keep answers short and plain.\n", "Keep answers short and plain.\nName the file.\n"
	p2, err := ValidateChatProposal(context.Background(), d.DB, p2Edit, env)
	require.NoError(t, err)
	assert.Equal(t, "Keep answers short and plain.\n", p2.BeforeText)
}

// newConversation is a tuning conversation row.
func newConversation(t *testing.T, d dbs) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, created_at, updated_at)
		VALUES ('', 'analytics_tuning', 0, 0)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestValidateChatProposal_DeletedConversationProposalCanBeDeclined(t *testing.T) {
	d := openDBs(t)
	env, a := chatEnv(t, d)
	conv := newConversation(t, d)
	p, err := ValidateChatProposal(context.Background(), d.DB, chatEdit(), env)
	require.NoError(t, err)
	id, err := d.InsertChatCoachProposal(p, &conv, applyNow)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)

	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, id, open[0].ID)
	assert.Nil(t, open[0].ConversationID)

	require.NoError(t, a.Decline(id))
	other := chatEdit()
	other.Replace = "Ask before deleting."
	_, err = ValidateChatProposal(context.Background(), d.DB, other, env)
	require.NoError(t, err)
}

func TestValidateChatProposal_SameEditAgainRefused(t *testing.T) {
	d := openDBs(t)
	env, a := chatEnv(t, d)
	p, err := ValidateChatProposal(context.Background(), d.DB, chatEdit(), env)
	require.NoError(t, err)
	id, err := d.InsertChatCoachProposal(p, nil, applyNow)
	require.NoError(t, err)
	require.NoError(t, a.Decline(id))

	_, err = ValidateChatProposal(context.Background(), d.DB, chatEdit(), env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, fmt.Sprintf("already proposed as #%d (declined)", id), err.Error())
}

func TestValidateAfter_PromptRefusalText(t *testing.T) {
	cur := CurrentText{Destination: DestPromptAdd, PromptID: prompts.BriefingDaily}
	err := ValidateAfter(cur, "Keep it short.")
	require.Error(t, err)
	assert.Equal(t, prompts.BriefingDaily+" belongs to a built-in automation", err.Error())

	cur.PromptID = prompts.TrackRun
	require.EqualError(t, ValidateAfter(cur, "Keep it short."), prompts.TrackRun+" does not take additions")
	require.NoError(t, PromptAdditionRefusal(prompts.SpecReview))
}

func TestReadText_ReadsTheDestination(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	cur, err := ReadText(d.DB, env, DestClaudeSkillUser, 0, "", "a")
	require.NoError(t, err)
	assert.Equal(t, "Read the plan.\nRun tests.\n", cur.Text)
	assert.Equal(t, skillBudget(len(cur.Text)), cur.Budget)
	_, err = ReadText(d.DB, env, DestClaudeSkillUser, 0, "", "gone")
	require.ErrorIs(t, err, errSkillNotFound)
}

func TestValidateChatProposal_UnreadableTexts(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	target := ClaudeSkillPath(env, "real")
	writeFile(t, target, "Body.\n")
	require.NoError(t, os.MkdirAll(filepath.Dir(ClaudeSkillPath(env, "link")), 0o700))
	require.NoError(t, os.Symlink(target, ClaudeSkillPath(env, "link")))
	writeFile(t, filepath.Join(env.Home, ".agents", "skills", "two", "SKILL.md"), "Body.\n")
	writeFile(t, filepath.Join(env.CodexHome, "skills", "two", "SKILL.md"), "Body.\n")

	link := chatEdit()
	link.Skill = "link"
	two := chatEdit()
	two.Destination, two.Skill = DestCodexSkillUser, "two"
	rules := ChatEdit{Destination: DestCodexRulesAllow, Kind: "add", Replace: CodexRuleLine([]string{"cat"}),
		Title: "t", Why: "w", Metric: "corrections"}

	for name, c := range map[string]struct {
		edit ChatEdit
		want string
	}{
		"symlinked skill": {link, "SKILL.md is a symlink, not a regular file, too large or not text"},
		"skill twice": {two, "Codex sees this skill in two folders (~/.agents/skills and " +
			filepath.Join(env.CodexHome, "skills") + ") — remove one copy first."},
	} {
		_, err := ValidateChatProposal(context.Background(), d.DB, c.edit, env)
		require.ErrorIs(t, err, ErrRefused, name)
		assert.Equal(t, c.want, err.Error(), name)
	}

	require.NoError(t, os.Remove(codexRulesPath(env)))
	_, err := ValidateChatProposal(context.Background(), d.DB, rules, env)
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, errCodexRulesMissing.Error(), err.Error())

	// A failure the owner cannot act on comes back as is, not as a refusal.
	require.NoError(t, d.Close())
	_, err = ValidateChatProposal(context.Background(), d.DB, ChatEdit{Destination: DestChat, Kind: "add",
		Replace: "Answer briefly.", Title: "t", Why: "w", Metric: "corrections"}, env)
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrRefused)
}

func TestValidateChatProposal_EveryDestinationKindPasses(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	base := ChatEdit{Kind: "add", Title: "t", Why: "w", Metric: "corrections"}
	for _, c := range []struct {
		dest, prompt, skill, replace, after string
	}{
		{DestPromptAdd, prompts.SpecReview, "", "Do not flag naming choices.", "Do not flag naming choices."},
		{DestPackOverlay, "", devpack.WorkbenchSkillName, "Ask before a long run.", "Ask before a long run."},
		{DestSettingsAllow, "", "", "Bash(cat:*)", "Bash(ls:*)\nBash(cat:*)"},
		{DestCodexRulesAllow, "", "", CodexRuleLine([]string{"cat"}), CodexRuleLine([]string{"cat"}) + "\n"},
	} {
		e := base
		e.Destination, e.PromptID, e.Skill, e.Replace = c.dest, c.prompt, c.skill, c.replace
		p, err := ValidateChatProposal(context.Background(), d.DB, e, env)
		require.NoError(t, err, c.dest)
		assert.Equal(t, c.after, p.AfterText, c.dest)
		assert.Equal(t, c.prompt, p.PromptID, c.dest)
		assert.Equal(t, c.skill, p.Skill, c.dest)
		assert.Contains(t, p.Fingerprint, c.dest+"|0|"+c.prompt+c.skill+"|", c.dest)
	}
}

func TestValidateChatProposal_EvidenceCapped(t *testing.T) {
	d := openDBs(t)
	env, _ := chatEnv(t, d)
	e := chatEdit()
	e.Evidence = nil
	for i := range maxEvidence + 3 {
		e.Evidence = append(e.Evidence, fmt.Sprintf("s%d", i+1))
	}
	p, err := ValidateChatProposal(context.Background(), d.DB, e, env)
	require.NoError(t, err)
	assert.Len(t, p.Evidence, maxEvidence)
	assert.Equal(t, maxEvidence+3, p.Sources)
}
