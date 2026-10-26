package coach

import (
	"fmt"
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
	require.NoError(t, d.MarkCoachAccepted(id, "Run the tests.\nKeep diffs small.", baseline, n, judgeDecided))
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
	require.NoError(t, d.MarkCoachAccepted(id, "Other rule.\nKeep it short.", fl(5), 3, judgeDecided))
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
	require.NoError(t, d.MarkCoachAccepted(id, "Bash(ls:*)", fl(5), 3, judgeDecided))
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
	require.NoError(t, d.MarkCoachAccepted(id, "Be concise and quick.", fl(5), 3, judgeDecided))
	now := judgeDecided.Add(15 * 24 * time.Hour)
	_, c := runJudge(t, d, now)
	require.Equal(t, 1, c)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "Be long.", open[0].AfterText)

	ap := newApplier(t, d)
	require.NoError(t, ap.Accept(open[0].ID, ""))
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
	require.NoError(t, d.MarkCoachAccepted(id, "Short.", fl(5), 3, judgeDecided))
	// Restoring would fit exactly; a longer current text pushes it over.
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Short. And more text after it."))
	_, c := runJudge(t, d, judgeDecided.Add(15*24*time.Hour))
	assert.Zero(t, c)
}
