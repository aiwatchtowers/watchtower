package coach

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
)

var judgeDecided = t0.Add(-2 * time.Hour)

// judgeFixture is a workbench with n sessions of one interrupt each over one
// task (corrections = n) and an accepted procedure edit with the given baseline.
func judgeFixture(t *testing.T, sessions int, baseline *float64) (dbs, int64, int64) {
	t.Helper()
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range sessions {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Run the tests.\nKeep diffs small."))
	id := propose(t, d, db.CoachProposal{Destination: DestProcedure, WorkbenchID: wb,
		BeforeText: "Run the tests.", AfterText: "Run the tests.\nKeep diffs small."})
	n := 0
	if baseline != nil {
		n = 3
	}
	require.NoError(t, d.MarkCoachAccepted(id, "Run the tests.\nKeep diffs small.", "", baseline, n, judgeDecided))
	return d, wb, id
}

func fl(v float64) *float64 { return &v }

func runJudge(t *testing.T, d dbs, now time.Time) (int, int) {
	t.Helper()
	j, c, err := judge(d.DB, d.al, t.TempDir(), now)
	require.NoError(t, err)
	return j, c
}

func TestJudge_Works(t *testing.T) {
	d, _, id := judgeFixture(t, 5, fl(10)) // measured 5 <= 9
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	p := proposal(t, d, id)
	assert.Equal(t, "works", p.Verdict)
	require.NotNil(t, p.VerdictValue)
	assert.InDelta(t, 5.0, *p.VerdictValue, 1e-9)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	assert.Empty(t, open)
}

func TestJudge_NoEffectMakesCut(t *testing.T) {
	d, wb, id := judgeFixture(t, 5, fl(5)) // 5 > 4.5
	now := judgeDecided.Add(15 * 24 * time.Hour)
	j, c := runJudge(t, d, now)
	assert.Equal(t, 1, j)
	assert.Equal(t, 1, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	cut := open[0]
	assert.Equal(t, "cut", cut.Kind)
	assert.Equal(t, id, cut.RevertsID)
	assert.Equal(t, DestProcedure, cut.Destination)
	assert.Equal(t, wb, cut.WorkbenchID)
	assert.Equal(t, "corrections", cut.Metric)
	assert.Equal(t, "Run the tests.\nKeep diffs small.", cut.BeforeText)
	assert.Equal(t, "Run the tests.", cut.AfterText)
	assert.Equal(t, proposal(t, d, id).Sources, cut.Sources)

	// A second run neither re-judges nor cuts again.
	j, c = runJudge(t, d, now.Add(time.Hour))
	assert.Zero(t, j+c)
}

func TestJudge_NoEffectCutPromptAddition(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range 5 {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "x"))
	_, err := d.AddPromptAddition(prompts.SpecReview, "Keep it short.", 0, t0)
	require.NoError(t, err)
	_, err = d.AddPromptAddition(prompts.SpecReview, "Other rule.", 0, t0)
	require.NoError(t, err)
	id := propose(t, d, db.CoachProposal{Destination: DestPromptAdd, PromptID: prompts.SpecReview,
		BeforeText: "Other rule.", AfterText: "Other rule.\nKeep it short."})
	require.NoError(t, d.MarkCoachAccepted(id, "Other rule.\nKeep it short.", "", fl(5), 3, judgeDecided))
	// The workbench scope of a global destination is ignored; measure is global.
	_, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	require.Equal(t, 1, c)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "Keep it short.\nOther rule.", open[0].BeforeText)
	assert.Equal(t, "Other rule.", open[0].AfterText)
}

func TestJudge_NoEditLeftNoCut(t *testing.T) {
	d, wb, id := judgeFixture(t, 5, fl(5))
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Run the tests."))
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
}

func TestJudge_NoSlotNoCut(t *testing.T) {
	d, _, id := judgeFixture(t, 5, fl(5))
	for i := range maxOpen {
		propose(t, d, db.CoachProposal{Destination: DestChat, Fingerprint: fmt.Sprintf("o%d", i),
			BeforeText: "", AfterText: fmt.Sprintf("x%d", i)})
	}
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
	n, err := d.CountOpenCoachProposals()
	require.NoError(t, err)
	assert.Equal(t, maxOpen, n)
}

func TestJudge_OpenProposalOnSameTextNoCut(t *testing.T) {
	d, wb, _ := judgeFixture(t, 5, fl(5))
	propose(t, d, db.CoachProposal{Destination: DestProcedure, WorkbenchID: wb, Fingerprint: "other",
		BeforeText: "Run the tests.\nKeep diffs small.", AfterText: "Run the tests.\nKeep diffs small.\nMore."})
	_, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, c)
}

func TestJudge_TooLittleDataThenGivesUp(t *testing.T) {
	d, _, id := judgeFixture(t, 4, fl(10))
	day15 := judgeDecided.Add(15 * 24 * time.Hour)
	j, c := runJudge(t, d, day15)
	assert.Zero(t, j+c)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)

	// Retried while young: a fifth session arrives.
	d.session(t, 1, "late", []int64{1}, 1, 1.0)
	j, _ = runJudge(t, d, day15.Add(24*time.Hour))
	assert.Equal(t, 1, j, "retried and judged")
	assert.Equal(t, "works", proposal(t, d, id).Verdict)
}

func TestJudge_TooLittleDataIsFinalAfterGiveUp(t *testing.T) {
	d, _, id := judgeFixture(t, 4, fl(10))
	// First looked at after the give-up age: too little data, then never again.
	day43 := judgeDecided.Add(43 * 24 * time.Hour)
	runJudge(t, d, day43)
	p := proposal(t, d, id)
	assert.Equal(t, "too_little_data", p.Verdict)
	d.session(t, 1, "late", []int64{1}, 1, 1.0)
	j, _ := runJudge(t, d, day43.Add(24*time.Hour))
	assert.Zero(t, j)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)
}

func TestJudge_MissingBaselineIsTooLittleData(t *testing.T) {
	d, _, id := judgeFixture(t, 5, nil)
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, j+c)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)
}

func TestJudge_NotBefore14Days(t *testing.T) {
	d, _, id := judgeFixture(t, 5, fl(5))
	j, c := runJudge(t, d, judgeDecided.Add(14*24*time.Hour-time.Minute))
	assert.Zero(t, j+c)
	assert.Empty(t, proposal(t, d, id).Verdict)
	j, _ = runJudge(t, d, judgeDecided.Add(14*24*time.Hour))
	assert.Equal(t, 1, j)
}

func TestWithoutEdit(t *testing.T) {
	cases := []struct{ name, dest, before, after, cur, want string }{
		{"appended line", DestChat, "A", "A\nB", "A\nB", "A"},
		{"line in the middle", DestChat, "A\nC", "A\nB\nC", "A\nB\nC", "A\nC"},
		{"replaced word", DestChat, "Be long.", "Be short.", "Be short.", "Be long."},
		{"replaced line", DestPromptAdd, "A\nOld", "A\nNew", "A\nNew\nZ", "A\nOld\nZ"},
		{"overlay line", DestPackOverlay, "A\nOld", "A\nNew", "A\nNew\nZ", "A\nOld\nZ"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := withoutEdit(db.CoachProposal{Destination: c.dest, BeforeText: c.before, AfterText: c.after}, c.cur)
			require.True(t, ok)
			assert.Equal(t, c.want, got)
		})
	}
	_, ok := withoutEdit(db.CoachProposal{Destination: DestChat, BeforeText: "A", AfterText: "A\nB"}, "A\nC")
	assert.False(t, ok, "added part gone")
}

func TestJudge_AllowRuleGetsVerdictButNoCut(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range 5 {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	id := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, BeforeText: "", AfterText: "Bash(ls:*)"})
	require.NoError(t, d.MarkCoachAccepted(id, "Bash(ls:*)", "", fl(5), 3, judgeDecided))
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
}

func TestJudge_ZeroBaselineIsTooLittleData(t *testing.T) {
	d, _, id := judgeFixture(t, 5, fl(0))
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, j+c)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)
}

func TestJudge_ReverseOfReplaceIsAcceptedEndToEnd(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range 5 {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Be concise and quick."))
	id := propose(t, d, db.CoachProposal{Destination: DestProcedure, WorkbenchID: wb, Kind: "replace",
		BeforeText: "Be long.", AfterText: "Be concise and quick."})
	require.NoError(t, d.MarkCoachAccepted(id, "Be concise and quick.", "", fl(5), 3, judgeDecided))
	now := judgeDecided.Add(15 * 24 * time.Hour)
	_, c := runJudge(t, d, now)
	require.Equal(t, 1, c)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "Be long.", open[0].AfterText)

	ap := newApplier(t, d)
	require.NoError(t, ap.acceptErr(open[0].ID, ""))
	got, err := d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Equal(t, "Be long.", got.Procedure)
}

func TestJudge_RestoredTextOverBudgetNoCut(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range 5 {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	long := strings.Repeat("x", instructions.MaxRunes)
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Short."))
	id := propose(t, d, db.CoachProposal{Destination: DestProcedure, WorkbenchID: wb, Kind: "replace",
		BeforeText: long, AfterText: "Short."})
	require.NoError(t, d.MarkCoachAccepted(id, "Short.", "", fl(5), 3, judgeDecided))
	// Restoring would fit exactly; a longer current text pushes it over.
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Short. And more text after it."))
	_, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, c)
}

// agentSessions stores n sessions of agent on the workbench's tasks, each
// with interrupts interrupts.
func (d dbs) agentSessions(t *testing.T, agent string, wb int64, ids []int64, n, interrupts int) {
	t.Helper()
	for i := range n {
		d.sessionOf(t, agent, wb, fmt.Sprintf("%s-%d-%d", agent, wb, i), ids, interrupts, 1.0)
	}
}

// acceptedFor files dest's accepted proposal on wb with baseline, decided at judgeDecided.
func acceptedFor(t *testing.T, d dbs, dest string, wb int64, baseline float64) int64 {
	t.Helper()
	id := propose(t, d, db.CoachProposal{Destination: dest, WorkbenchID: wb, AfterText: "Keep diffs small."})
	require.NoError(t, d.MarkCoachAccepted(id, "Keep diffs small.", "", fl(baseline), 3, judgeDecided))
	if isRepoDestination(dest) { // committed at once: measured from the Accept, as the others
		_, err := d.SetCoachMeasureFrom(id, judgeDecided)
		require.NoError(t, err)
	}
	return id
}

func TestJudge_ClaudeDestinationIgnoresCodexRows(t *testing.T) {
	for _, dest := range []string{DestClaudeMDUser, "claude_skill_user"} {
		judged := func(withCodex bool) db.CoachProposal {
			d := openDBs(t)
			wb, ids := d.workbench(t, "a", 1)
			d.agentSessions(t, "claude", wb, ids, 5, 1) // 5 corrections on the one task
			if withCodex {
				d.agentSessions(t, "codex", wb, ids, 5, 4) // all agents: 25
			}
			id := acceptedFor(t, d, dest, 0, 10)
			runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
			return proposal(t, d, id)
		}
		without, with := judged(false), judged(true)
		assert.Equal(t, "works", without.Verdict, dest)
		assert.Equal(t, without.Verdict, with.Verdict, dest)
		require.NotNil(t, with.VerdictValue, dest)
		assert.InDelta(t, *without.VerdictValue, *with.VerdictValue, 1e-9, dest)
		assert.InDelta(t, 5.0, *with.VerdictValue, 1e-9, dest)
	}
}

func TestJudge_CodexDestinationOnCodexRows(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.agentSessions(t, "claude", wb, ids, 5, 1)
	d.agentSessions(t, "codex", wb, ids, 5, 4)
	id := acceptedFor(t, d, "codex_skill_user", 0, 100)
	runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	p := proposal(t, d, id)
	assert.Equal(t, "works", p.Verdict)
	require.NotNil(t, p.VerdictValue)
	assert.InDelta(t, 20.0, *p.VerdictValue, 1e-9, "Codex rows only: 20, not 25 (all) or 5 (Claude)")
}

func TestJudge_RepoFileOnItsWorkbenchAndAgent(t *testing.T) {
	d := openDBs(t)
	a, aIDs := d.workbench(t, "a", 1)
	b, bIDs := d.workbench(t, "b", 1)
	d.agentSessions(t, "codex", a, aIDs, 5, 4)
	d.agentSessions(t, "claude", a, aIDs, 5, 1)
	d.agentSessions(t, "codex", b, bIDs, 5, 2)
	id := acceptedFor(t, d, "repo_agents_md", a, 100)
	runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	p := proposal(t, d, id)
	assert.Equal(t, "works", p.Verdict)
	require.NotNil(t, p.VerdictValue)
	assert.InDelta(t, 20.0, *p.VerdictValue, 1e-9, "workbench a's Codex rows only")
}

// Open chat proposals hold no weekly slot: a cut of an ineffective weekly
// edit is still written while maxOpen of them are open (its verdict is
// stored once, so a skipped cut would never come back).
func TestJudge_CutWrittenWhileThreeChatProposalsOpen(t *testing.T) {
	d, _, id := judgeFixture(t, 5, fl(5))
	for i := range maxOpen {
		propose(t, d, db.CoachProposal{Destination: DestChat, Origin: "chat", Fingerprint: fmt.Sprintf("c%d", i),
			BeforeText: "", AfterText: fmt.Sprintf("x%d", i)})
	}
	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Equal(t, 1, c)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, maxOpen+1)
	var cut db.CoachProposal
	for _, o := range open {
		if o.RevertsID == id {
			cut = o
		}
	}
	require.NotZero(t, cut.ID, "the cut of the weekly edit")
	assert.Equal(t, "weekly", cut.Origin)
}

// The Codex rules may only grow (like the Claude allow list): the verdict is
// stored, no cut is filed.
func TestJudge_NoCutForCodexRulesAllow(t *testing.T) {
	t.Setenv("CODEX_HOME", "")
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.agentSessions(t, "codex", wb, ids, 5, 1)
	rule := CodexRuleLine([]string{"ls"})
	// The rules file is there and holds the added line: still no cut.
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".codex", codexRulesRel), rule+"\n")
	id := propose(t, d, db.CoachProposal{Destination: DestCodexRulesAllow, BeforeText: "", AfterText: rule + "\n"})
	require.NoError(t, d.MarkCoachAccepted(id, rule+"\n", "", fl(5), 3, judgeDecided))
	j, c, err := judge(d.DB, d.al, home, judgeDecided.Add(15*24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
	n, err := d.CountOpenCoachProposals()
	require.NoError(t, err)
	assert.Zero(t, n)
}

func TestIsRepoDestination(t *testing.T) {
	for _, dest := range repoDestinationsForTest {
		assert.True(t, isRepoDestination(dest), dest)
	}
	for _, dest := range []string{DestClaudeMDUser, DestCodexAgentsMDUser, DestProcedure, DestPackOverlay} {
		assert.False(t, isRepoDestination(dest), dest)
	}
}

// A workbench repository file is the owner's to commit: never a judge's cut
// (spec §4.3a, D67).
func TestJudge_NoCutForRepoFile(t *testing.T) {
	for _, dest := range repoDestinationsForTest {
		d := openDBs(t)
		wb, ids := d.workbench(t, "a", 1)
		d.agentSessions(t, "claude", wb, ids, 5, 1)
		d.agentSessions(t, "codex", wb, ids, 5, 1)
		id := acceptedFor(t, d, dest, wb, 5)
		j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
		assert.Equal(t, 1, j, dest)
		assert.Zero(t, c, dest)
		assert.Equal(t, "no_effect", proposal(t, d, id).Verdict, dest)
		n, err := d.CountOpenCoachProposals()
		require.NoError(t, err)
		assert.Zero(t, n, dest)
	}
}

var repoDestinationsForTest = []string{DestRepoClaudeMD, DestRepoAgentsMD, DestRepoClaudeSkill,
	DestRepoCodexSkill, DestRepoWorkflow}

// A Codex skill found in both folders cannot be read: no cut, no error.
func TestJudge_NoCutForCodexSkillInTwoFolders(t *testing.T) {
	t.Setenv("CODEX_HOME", "")
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.agentSessions(t, "codex", wb, ids, 5, 1)
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".agents", "skills", "a", "SKILL.md"), "Before.\nAfter.\n")
	writeFile(t, filepath.Join(home, ".codex", "skills", "a", "SKILL.md"), "Before.\nAfter.\n")
	id := propose(t, d, db.CoachProposal{Destination: DestCodexSkillUser, Skill: "a",
		BeforeText: "Before.\n", AfterText: "Before.\nAfter.\n"})
	require.NoError(t, d.MarkCoachAccepted(id, "Before.\nAfter.\n", "", fl(5), 3, judgeDecided))
	j, c, err := judge(d.DB, d.al, home, judgeDecided.Add(15*24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, j)
	assert.Zero(t, c)
	assert.Equal(t, "no_effect", proposal(t, d, id).Verdict)
}

// A cut of an accepted chat edit is an ordinary weekly cut carrying today's
// text: origin weekly, no conversation, the original's skill and destination
// (spec D64).
func TestJudge_CutOfChatEditIsWeekly(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.agentSessions(t, "claude", wb, ids, 5, 1)
	home := t.TempDir()
	skill := filepath.Join(home, ".claude", "skills", "review", "SKILL.md")
	writeFile(t, skill, "Read the diff.\nKeep it short.\nCheck tests.\n")
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, created_at, updated_at)
		VALUES ('', 'analytics_tuning', 0, 0)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeSkillUser, Skill: "review", Origin: "chat",
		ConversationID: &conv, BeforeText: "Read the diff.\n", AfterText: "Read the diff.\nKeep it short.\n"})
	require.NoError(t, d.MarkCoachAccepted(id, "Read the diff.\nKeep it short.\n", "", fl(5), 3, judgeDecided))
	orig := proposal(t, d, id)

	j, c, err := judge(d.DB, d.al, home, judgeDecided.Add(15*24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, j)
	require.Equal(t, 1, c)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	cut := open[0]
	assert.Equal(t, "weekly", cut.Origin)
	assert.Nil(t, cut.ConversationID)
	assert.Equal(t, DestClaudeSkillUser, cut.Destination)
	assert.Equal(t, "review", cut.Skill)
	assert.Equal(t, id, cut.RevertsID)
	assert.Equal(t, "Read the diff.\nKeep it short.\nCheck tests.\n", cut.BeforeText, "today's text")
	assert.Equal(t, "Read the diff.\nCheck tests.\n", cut.AfterText)
	assert.Equal(t, cutTitle(orig.Title), cut.Title)
	assert.Equal(t, cutWhy(orig), cut.Why)
}

// repoJudgeFixture is judgeFixture's workbench and sessions (all at t0) with
// an accepted repo_claude_md edit decided at judgeDecided instead.
func repoJudgeFixture(t *testing.T, sessions int) (dbs, int64) {
	t.Helper()
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	for i := range sessions {
		d.session(t, wb, fmt.Sprintf("s%d", i), ids, 1, 1.0)
	}
	id := propose(t, d, db.CoachProposal{Destination: DestRepoClaudeMD, WorkbenchID: wb,
		BeforeText: "Run tests.\n", AfterText: "Run tests.\nKeep diffs small.\n"})
	require.NoError(t, d.MarkCoachAccepted(id, "Run tests.\nKeep diffs small.\n", "main", fl(10), 3, judgeDecided))
	return d, id
}

// Spec §4.3a (D68): a repository edit's window starts at measure_from, not at
// the Accept; every other destination's still starts at the Accept.
func TestJudge_RepoWindowStartsAtMeasureFrom(t *testing.T) {
	// The sessions (t0) fall between the Accept and the commit: not counted.
	d, id := repoJudgeFixture(t, 5)
	measureFrom := t0.Add(5 * 24 * time.Hour)
	set, err := d.SetCoachMeasureFrom(id, measureFrom)
	require.NoError(t, err)
	require.True(t, set)

	j, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, j+c, "14 days from the Accept, not yet 14 from the commit")
	assert.Empty(t, proposal(t, d, id).Verdict)

	j, c = runJudge(t, d, measureFrom.Add(15*24*time.Hour))
	assert.Zero(t, j)
	assert.Zero(t, c, "never a cut for a repository file")
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict, "the sessions before the commit are out of the window")

	// Committed before the sessions: the same sessions are measured.
	d, id = repoJudgeFixture(t, 5)
	_, err = d.SetCoachMeasureFrom(id, judgeDecided.Add(time.Hour))
	require.NoError(t, err)
	j, _ = runJudge(t, d, judgeDecided.Add(time.Hour+15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Equal(t, "works", proposal(t, d, id).Verdict)

	// A v1 destination: unchanged, measured from the Accept.
	d, _, pid := judgeFixture(t, 5, fl(10))
	j, _ = runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Equal(t, 1, j)
	assert.Equal(t, "works", proposal(t, d, pid).Verdict)
}

// Not committed in 30 days: too_little_data, and it stays so.
func TestJudge_RepoNotCommittedIn30Days(t *testing.T) {
	d, id := repoJudgeFixture(t, 5)
	j, c := runJudge(t, d, judgeDecided.Add(29*24*time.Hour))
	assert.Zero(t, j+c)
	assert.Empty(t, proposal(t, d, id).Verdict, "still waiting for the commit")

	now := judgeDecided.Add(31 * 24 * time.Hour)
	j, c = runJudge(t, d, now)
	assert.Zero(t, j+c, "too_little_data is not counted as judged")
	p := proposal(t, d, id)
	assert.Equal(t, "too_little_data", p.Verdict)
	assert.Nil(t, p.VerdictValue)
	assert.Equal(t, now, p.VerdictAt.UTC())

	runJudge(t, d, now.Add(7*24*time.Hour))
	assert.Equal(t, now, proposal(t, d, id).VerdictAt.UTC(), "final: not judged again")
	awaiting, err := d.ListRepoProposalsAwaitingCommit()
	require.NoError(t, err)
	assert.Empty(t, awaiting, "the commit check leaves it")
}

// A commit first seen after 30 days (committed late, or the daemon was off)
// does not reopen the window: too_little_data, as never committed.
func TestJudge_RepoCommittedAfter30Days(t *testing.T) {
	d, id := repoJudgeFixture(t, 5)
	late := judgeDecided.Add(31 * 24 * time.Hour)
	set, err := d.SetCoachMeasureFrom(id, late)
	require.NoError(t, err)
	require.True(t, set)
	j, c := runJudge(t, d, late.Add(time.Hour))
	assert.Zero(t, j+c)
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)
	runJudge(t, d, late.Add(15*24*time.Hour))
	assert.Equal(t, late.Add(time.Hour), proposal(t, d, id).VerdictAt.UTC(), "final: never measured")
}
