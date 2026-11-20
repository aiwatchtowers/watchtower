package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/prompts"
)

var btT0 = time.Date(2026, 9, 1, 9, 0, 0, 0, time.UTC)

// btGen is a fake generator for the backtest: it answers watchman.profile
// with one rule and watchman.decide through decide, and records every input
// it is shown. Each call reports a cost of 0.01.
type btGen struct {
	d          *db.DB
	wb         int64
	decide     func(in decideInput) (choice, confidence string, err error)
	handoff    func(in decideInput) string // nil: no "handoff" in the reply
	rationale  func(in decideInput) string // nil: "because"
	decideIn   []decideInput
	profileIn  []profileInput
	progress   []string
	sources    []string
	profileErr error
}

func (g *btGen) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	src, _ := digest.SourceFromContext(ctx)
	g.sources = append(g.sources, src)
	cost := 0.01
	u := &digest.Usage{Tokens: llmusage.Tokens{Input: 10, Output: 5, ReportedCostUSD: &cost}}
	open, end := strings.Index(user, "<data>\n"), strings.LastIndex(user, "\n</data>")
	if open < 0 || end < open {
		return "", u, "", errors.New("no data fence")
	}
	body := user[open+len("<data>\n") : end]
	switch src {
	case prompts.WatchmanProfile:
		var in profileInput
		if err := json.Unmarshal([]byte(body), &in); err != nil {
			return "", u, "", err
		}
		g.profileIn = append(g.profileIn, in)
		if g.profileErr != nil {
			return "", u, "", g.profileErr
		}
		return `{"rules":["profile built by the backtest"]}`, u, "", nil
	case prompts.WatchmanDecide:
		var in decideInput
		if err := json.Unmarshal([]byte(body), &in); err != nil {
			return "", u, "", err
		}
		g.decideIn = append(g.decideIn, in)
		if g.d != nil {
			if b, _, err := g.d.LatestWatchmanBacktest(g.wb); err == nil && b != nil {
				g.progress = append(g.progress, b.Progress)
			}
		}
		choice, conf := "allow", "low"
		if g.decide != nil {
			var err error
			if choice, conf, err = g.decide(in); err != nil {
				return "", u, "", err
			}
		}
		why := "because"
		if g.rationale != nil {
			why = g.rationale(in)
		}
		r := map[string]any{"choice": choice, "rationale": why, "precedent_ids": []int64{},
			"confidence": conf, "category": in.Category, "importance": "low"}
		if g.handoff != nil {
			r["handoff"] = g.handoff(in)
		}
		out, _ := json.Marshal(r)
		return string(out), u, "", nil
	}
	return "", u, "", fmt.Errorf("unexpected source %q", src)
}

// btJudge grades through grade (nil: "same" for every question) and rules
// on a handoff through handoff (nil: justified), and records every input.
// Each call reports a cost of 0.001.
type btJudge struct {
	grade   func(in JudgeInput) []string
	why     func(in JudgeInput) []string
	handoff func(in JudgeInput) string
	err     func(call int) error // nil = never fails
	calls   int
	inputs  []JudgeInput
}

func (j *btJudge) Grade(_ context.Context, in JudgeInput) (JudgeResult, *digest.Usage, error) {
	j.calls++
	j.inputs = append(j.inputs, in)
	cost := 0.001
	u := &digest.Usage{Tokens: llmusage.Tokens{ReportedCostUSD: &cost}}
	if j.err != nil {
		if err := j.err(j.calls); err != nil {
			return JudgeResult{}, u, err
		}
	}
	if in.Handoff {
		v := HandoffJustified
		if j.handoff != nil {
			v = j.handoff(in)
		}
		return JudgeResult{Handoff: v, HandoffWhy: "handoff reason " + v}, u, nil
	}
	var res JudgeResult
	if j.grade == nil {
		res.Grades = slices.Repeat([]string{GradeSame}, max(1, len(in.Questions)))
	} else {
		res.Grades = j.grade(in)
	}
	if j.why != nil {
		res.Why = j.why(in)
	}
	return res, u, nil
}

// gradeAll is a judge grade func giving g to every question.
func gradeAll(g string) func(JudgeInput) []string {
	return func(in JudgeInput) []string { return slices.Repeat([]string{g}, max(1, len(in.Questions))) }
}

func btDB(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	return d, wb
}

// btAdd stores n precedents of a category from one source, one hour apart
// from start, and returns them oldest first with their ids.
func btAdd(t *testing.T, d *db.DB, wb int64, source, category string, n int, start time.Time, choice string) []db.WatchmanPrecedent {
	t.Helper()
	return btAddTagged(t, d, wb, source, category, "", n, start, choice)
}

// btAddTagged is btAdd with tag in every situation and key, so a group of
// precedents ranks above the rest for each other in retrieval.
func btAddTagged(t *testing.T, d *db.DB, wb int64, source, category, tag string, n int, start time.Time, choice string) []db.WatchmanPrecedent {
	t.Helper()
	ps := make([]db.WatchmanPrecedent, n)
	for i := range ps {
		ps[i] = db.WatchmanPrecedent{WorkbenchID: wb, Source: source, SourceKey: fmt.Sprintf("%s-%s-%s%d", source, category, tag, i),
			Category: category, Situation: fmt.Sprintf("%simporter cache case %s %d", tag, category, i), Choice: choice,
			OwnerWords: "words " + category, DecidedAt: start.Add(time.Duration(i) * time.Hour), Weight: 1}
	}
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
	for i := range ps {
		require.NoError(t, d.QueryRow(`SELECT id FROM watchman_precedents WHERE source = ? AND source_key = ?`,
			ps[i].Source, ps[i].SourceKey).Scan(&ps[i].ID))
	}
	return ps
}

func btRows(t *testing.T, d *db.DB, wb int64) (*db.WatchmanBacktest, map[string]db.WatchmanBacktestRow) {
	t.Helper()
	b, rows, err := d.LatestWatchmanBacktest(wb)
	require.NoError(t, err)
	require.NotNil(t, b)
	out := map[string]db.WatchmanBacktestRow{}
	for _, r := range rows {
		out[r.Category] = r
	}
	return b, out
}

// TestBacktest_NoFutureLeak: nothing the twin or the profile is shown is a
// hidden decision, decided at or after the item (or the cutoff), or an
// instruction updated after the cutoff.
func TestBacktest_NoFutureLeak(t *testing.T) {
	d, wb := btDB(t)
	// The hidden 30 share words the older 70 lack, so without the exclusion
	// retrieval would rank them first.
	ps := btAdd(t, d, wb, "turn", CategoryDesign, 70, btT0, "keep sqlite")
	hidden := btAddTagged(t, d, wb, "turn", CategoryDesign, "late batch ", 30, btT0.Add(70*time.Hour), "keep sqlite")
	ps = append(ps, hidden...)
	cutoff := hidden[0].DecidedAt
	_, err := d.Exec(`INSERT INTO owner_instructions (scope, body, updated_at) VALUES
		('session', 'old rule from before', ?), ('procedure', 'new rule from after', ?)`,
		cutoff.Add(-time.Hour).Format(time.RFC3339), cutoff.Add(time.Hour).Format(time.RFC3339))
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionSession, "workbench text with no edit time"))

	byID, bySituation, isHidden := map[int64]db.WatchmanPrecedent{}, map[string]db.WatchmanPrecedent{}, map[int64]bool{}
	for _, p := range ps {
		byID[p.ID], bySituation[p.Situation] = p, p
	}
	for _, p := range hidden {
		isHidden[p.ID] = true
	}
	gen, judge := &btGen{}, &btJudge{}
	_, err = Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)

	require.Len(t, gen.profileIn, 1)
	require.Len(t, gen.profileIn[0].Precedents, 60)
	for _, pp := range gen.profileIn[0].Precedents {
		p, ok := bySituation[pp.Situation]
		require.True(t, ok)
		assert.False(t, isHidden[p.ID], "profile shown hidden %d", p.ID)
		assert.True(t, p.DecidedAt.Before(cutoff), "profile shown %d decided after the cutoff", p.ID)
	}
	require.Len(t, gen.decideIn, 30)
	shown := 0
	for _, in := range gen.decideIn {
		item := bySituation[in.Situation]
		require.True(t, isHidden[item.ID])
		for _, sp := range in.Precedents {
			shown++
			p := byID[sp.ID]
			assert.False(t, isHidden[p.ID], "item %d was shown hidden %d", item.ID, p.ID)
			assert.True(t, p.DecidedAt.Before(item.DecidedAt), "item %d was shown later %d", item.ID, p.ID)
		}
		assert.Contains(t, in.Instructions, "old rule from before")
		assert.NotContains(t, in.Instructions, "new rule from after")
		assert.NotContains(t, in.Instructions, "workbench text with no edit time")
	}
	require.Positive(t, shown, "retrieval must have shown something for the check to mean anything")
	require.Equal(t, 30, judge.calls) // turns have no options
}

func TestBacktest_IgnoresStoredAndPinnedProfile(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 40, btT0, "allow")
	require.NoError(t, d.PinWatchmanProfile(wb, CategoryPermission, "pinned text written later", btT0.Add(500*time.Hour)))
	_, err := d.SaveLearnedWatchmanProfile(wb, CategoryDesign, "stored design text", btT0)
	require.NoError(t, err)
	gen := &btGen{}
	_, err = Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Len(t, gen.profileIn, 1)
	require.Len(t, gen.decideIn, 30)
	for _, in := range gen.decideIn {
		require.Equal(t, "profile built by the backtest", in.Profile)
	}
	ps, err := d.WatchmanProfiles(wb)
	require.NoError(t, err)
	for _, p := range ps {
		assert.NotEqual(t, "profile built by the backtest", p.Text, "the backtest profile is never stored")
	}
}

func TestBacktest_EmptyCategoryNotMeasured(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, "turn", CategoryTests, 29, btT0, "add a test")
	gen, judge := &btGen{}, &btJudge{}
	res, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Empty(t, gen.sources, "no model call")
	require.Zero(t, judge.calls)
	b, rows := btRows(t, d, wb)
	require.Equal(t, res.ID, b.ID)
	require.Equal(t, "done", b.Status)
	require.Equal(t, VerdictStop, b.Verdict)
	require.Len(t, rows, len(Categories))
	for _, c := range Categories {
		assert.Equal(t, BacktestNotMeasured, rows[c].Status, c)
		assert.Zero(t, rows[c].Agree, c)
	}
	require.Equal(t, 29, rows[CategoryTests].Total)
}

func TestBacktest_StrongWeakBars(t *testing.T) {
	for _, tc := range []struct {
		total, bad, wrongHigh int
		want                  string
	}{
		{30, 0, 0, BacktestStrong},
		{30, 1, 0, BacktestStrong}, // 3.3 % bad
		{40, 2, 0, BacktestStrong}, // exactly 5 %
		{40, 3, 0, BacktestWeak},
		{30, 2, 0, BacktestWeak},        // 6.7 % bad
		{40, 1, 1, BacktestWeak},        // one bad while sure
		{29, 0, 0, BacktestStrong},      // measured from MinScored scored decisions
		{20, 1, 0, BacktestStrong},      // exactly 5 %
		{19, 0, 0, BacktestNotMeasured}, // below MinScored
	} {
		got := rowStatus(db.WatchmanBacktestRow{Total: tc.total, Bad: tc.bad, WrongHigh: tc.wrongHigh})
		assert.Equal(t, tc.want, got, "%+v", tc)
	}
	// Agreement and the base rates no longer gate: a twin that never
	// matches the owner but is never bad is strong.
	assert.Equal(t, BacktestStrong, rowStatus(db.WatchmanBacktestRow{Total: 30, Acceptable: 30, Baseline: 1, RecBaseline: 1}))

	// End to end: the owner allowed half and denied half; 6 of 30 are
	// decided differently, which the judge grades (the high-confidence one
	// acceptable, one bad).
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, SourcePermission, CategoryPermission, 40, btT0, "allow")
	owner := map[string]string{}
	for i, p := range ps {
		owner[p.Situation] = "allow"
		if i%2 == 1 {
			owner[p.Situation] = "deny"
			_, err := d.Exec(`UPDATE watchman_precedents SET choice = 'deny' WHERE id = ?`, p.ID)
			require.NoError(t, err)
		}
	}
	wrong := map[string]string{}
	for i, p := range ps[34:] { // six of the hidden ones
		wrong[p.Situation] = map[bool]string{true: "high", false: "low"}[i == 0]
	}
	badOne := ps[35].Situation
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		require.Equal(t, []string{"allow", "deny"}, in.Options)
		other := map[string]string{"allow": "deny", "deny": "allow"}
		if conf, ok := wrong[in.Situation]; ok {
			return other[owner[in.Situation]], conf, nil
		}
		return owner[in.Situation], "high", nil
	}}
	judge := &btJudge{grade: func(in JudgeInput) []string {
		if in.Situation == badOne {
			return []string{GradeBad}
		}
		return []string{GradeAcceptable}
	}}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 6, judge.calls, "an exact match needs no judge; a different option goes to it")
	for _, in := range judge.inputs {
		require.Empty(t, in.Questions)
		require.Contains(t, in.Twin, "Confidence: ")
	}
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Total)
	require.Equal(t, 24, r.Agree)
	require.Equal(t, 5, r.Acceptable)
	require.Equal(t, 1, r.Bad)
	require.Zero(t, r.WrongHigh, "the bad one was not sure")
	require.InDelta(t, 0.5, r.Baseline, 1e-9)
	require.Zero(t, r.RecBaseline, "a permission has no recommended option")
	require.Equal(t, BacktestStrong, r.Status)
	require.InDelta(t, 0.316, r.CostUSD, 1e-9) // one profile call + 30 decide calls at 0.01 + 6 judge calls at 0.001
}

// TestBacktest_FixedOptionMismatchAcceptable: a different option the judge
// finds reasonable counts acceptable, not agree.
func TestBacktest_FixedOptionMismatchAcceptable(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "deny", "high", nil }}
	judge := &btJudge{grade: gradeAll(GradeAcceptable)}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 30, judge.calls)
	require.Equal(t, "Choice: allow\nOwner's words: words permission", judge.inputs[0].Owner)
	require.Equal(t, "Choice: deny\nReasoning: because\nConfidence: high", judge.inputs[0].Twin)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Acceptable)
	require.Zero(t, r.Agree)
	require.Zero(t, r.Bad)
	require.Zero(t, r.WrongHigh)
	require.Equal(t, BacktestStrong, r.Status)
}

// TestBacktest_BaseRateKeptNotGating: an owner who always allowed, matched
// by a twin that always allows, is strong now (ask #1423); the base rate is
// still stored.
func TestBacktest_BaseRateKeptNotGating(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "allow", "high", nil }}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Agree)
	require.InDelta(t, 1.0, r.Baseline, 1e-9)
	require.Equal(t, BacktestStrong, r.Status)
}

func TestVerdict_GoStop(t *testing.T) {
	row := func(c, s string) db.WatchmanBacktestRow { return db.WatchmanBacktestRow{Category: c, Status: s} }
	for name, tc := range map[string]struct {
		rows []db.WatchmanBacktestRow
		want string
	}{
		"none": {nil, VerdictStop},
		"three strong with permission": {[]db.WatchmanBacktestRow{row("ux_text", BacktestStrong), row("tests", BacktestStrong),
			row("permission", BacktestStrong)}, VerdictGo},
		"three strong with design": {[]db.WatchmanBacktestRow{row("design", BacktestStrong), row("tests", BacktestStrong),
			row("review_code", BacktestStrong), row("permission", BacktestWeak)}, VerdictGo},
		"three strong with scope": {[]db.WatchmanBacktestRow{row("scope", BacktestStrong), row("tests", BacktestStrong),
			row("finish", BacktestStrong)}, VerdictGo},
		"three strong without permission, design or scope": {[]db.WatchmanBacktestRow{row("ux_text", BacktestStrong),
			row("tests", BacktestStrong), row("review_code", BacktestStrong), row("permission", BacktestWeak),
			row("design", BacktestNotMeasured)}, VerdictStop},
		"two strong incl. permission": {[]db.WatchmanBacktestRow{row("permission", BacktestStrong),
			row("design", BacktestStrong), row("tests", BacktestNotMeasured)}, VerdictStop},
	} {
		assert.Equal(t, tc.want, Verdict(tc.rows), name)
	}
}

func TestBacktest_WritesProgress(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{d: d, wb: wb}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Len(t, gen.progress, 30)
	require.Equal(t, "", gen.progress[0])
	require.Equal(t, "permission, 1 of 30 · 6 of 8 categories done", gen.progress[1])
	require.Equal(t, "permission, 29 of 30 · 6 of 8 categories done", gen.progress[29])
	b, _ := btRows(t, d, wb)
	require.Equal(t, "permission, 30 of 30 · 6 of 8 categories done", b.Progress)
}

func TestBacktest_ClosesInterruptedRunningRow(t *testing.T) {
	d, wb := btDB(t)
	old, err := d.InsertWatchmanBacktest(db.WatchmanBacktest{WorkbenchID: wb, StartedAt: btT0, Status: "running"})
	require.NoError(t, err)
	res, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, "", btT0.Add(time.Hour))
	require.NoError(t, err)
	require.NotEqual(t, old, res.ID)
	var status, msg string
	require.NoError(t, d.QueryRow(`SELECT status, error FROM watchman_backtests WHERE id = ?`, old).Scan(&status, &msg))
	require.Equal(t, "failed", status)
	require.Equal(t, "interrupted", msg)
	b, _ := btRows(t, d, wb)
	require.Equal(t, "done", b.Status)
}

func TestBacktest_FailureKeepsPartialRows(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryDesign, 30, btT0, "allow")
	btAdd(t, d, wb, SourcePermission, CategoryScope, 30, btT0, "allow")
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		if in.Category == CategoryScope {
			return "", "", errors.New("provider down")
		}
		return "allow", "low", nil
	}}
	res, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(100*time.Hour))
	require.ErrorContains(t, err, "provider down")
	b, rows := btRows(t, d, wb)
	require.Equal(t, res.ID, b.ID)
	require.Equal(t, "failed", b.Status)
	require.Contains(t, b.Error, "provider down")
	require.Empty(t, b.Verdict)
	require.NotNil(t, b.FinishedAt)
	require.Len(t, rows, 1)
	require.Equal(t, 30, rows[CategoryDesign].Agree)
	require.InDelta(t, 0.32, b.CostUSD, 1e-9, "the design calls and both failed scope attempts are counted")
	done, _, err := d.LatestDoneWatchmanBacktest(wb)
	require.NoError(t, err)
	require.Nil(t, done)
}

// TestBacktest_BadTwinReplyIsBad: a reply the twin cannot get right is
// scored bad (not skipped, not fatal, not "bad while sure": it has no
// usable confidence), with no judge call.
func TestBacktest_BadTwinReplyIsBad(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(in decideInput) (string, string, error) { return "maybe", "high", nil }}
	judge := &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Zero(t, judge.calls)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Total)
	require.Equal(t, 30, r.Bad)
	require.Zero(t, r.Agree)
	require.Zero(t, r.WrongHigh, "no usable confidence")
	require.Equal(t, BacktestWeak, r.Status)
}

// btAddAsks seeds n answered question asks (payload, answer(i)) one hour
// apart from start and stores them as precedents of category through the
// real ask source mapping.
func btAddAsks(t *testing.T, d *db.DB, wb int64, category string, n int, start time.Time, payload string, answer func(i int) string) {
	t.Helper()
	for i := range n {
		seedAsk(t, d, askSeed{wb: wb, payload: payload, answer: answer(i), answeredAt: start.Add(time.Duration(i) * time.Hour)})
	}
	rows, err := d.AnsweredOwnerAsks(wb, nil, false, n+1)
	require.NoError(t, err)
	require.Len(t, rows, n)
	ps := make([]db.WatchmanPrecedent, 0, n)
	for _, r := range rows {
		p, ok, err := askPrecedent(wb, r)
		require.NoError(t, err)
		require.True(t, ok)
		p.Category = category
		ps = append(ps, p)
	}
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
}

const twoQuestionPayload = `{"focus":[],"questions":[` +
	`{"id":"q1","question":"Which cache should the importer use?","options":[{"label":"sqlite","recommended":true},{"label":"redis"}]},` +
	`{"id":"q2","question":"Ship it today?","options":[{"label":"yes","recommended":true},{"label":"no"}]}],"checklist":[]}`

func twoQuestionAnswer(int) string {
	return `{"answers":[{"id":"q1","labels":["sqlite"],"other":""},{"id":"q2","labels":["no"],"other":""}],` +
		`"checklist":[],"comments":[],"note":"","verdict":""}`
}

// TestBacktest_MultiQuestionGradedPerQuestion: an ask with two questions is
// two scored decisions; a grade the judge leaves out is bad, an extra one
// is ignored; the recommended pick is counted per question.
func TestBacktest_MultiQuestionGradedPerQuestion(t *testing.T) {
	for name, tc := range map[string]struct {
		grades             []string
		agree, accept, bad int
		wrongHigh          int
	}{
		"missing grade is bad, not bad while sure": {[]string{GradeSame}, 30, 0, 30, 0},
		"given bad while sure":                     {[]string{GradeSame, GradeBad}, 30, 0, 30, 30},
		"extra grade ignored":                      {[]string{GradeSame, GradeAcceptable, GradeBad}, 30, 30, 0, 0},
	} {
		t.Run(name, func(t *testing.T) {
			d, wb := btDB(t)
			btAddAsks(t, d, wb, CategoryDesign, 30, btT0, twoQuestionPayload, twoQuestionAnswer)
			gen := &btGen{decide: func(in decideInput) (string, string, error) {
				require.Empty(t, in.Options, "several questions are a free answer")
				return "sqlite, and ship it", "high", nil
			}}
			judge := &btJudge{grade: func(JudgeInput) []string { return tc.grades }}
			_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
			require.NoError(t, err)
			require.Equal(t, 30, judge.calls)
			require.Equal(t, []string{"Which cache should the importer use?", "Ship it today?"}, judge.inputs[0].Questions)
			_, rows := btRows(t, d, wb)
			r := rows[CategoryDesign]
			require.Equal(t, 60, r.Total)
			require.Equal(t, tc.agree, r.Agree)
			require.Equal(t, tc.accept, r.Acceptable)
			require.Equal(t, tc.bad, r.Bad)
			require.Equal(t, tc.wrongHigh, r.WrongHigh)
			require.InDelta(t, 0.5, r.RecBaseline, 1e-9, "the owner took the recommended option on q1, not on q2")
		})
	}
}

// TestBacktest_RecommendedPickSingleQuestion: rec_baseline over single
// question asks; the exact matches skip the judge.
func TestBacktest_RecommendedPickSingleQuestion(t *testing.T) {
	d, wb := btDB(t)
	btAddAsks(t, d, wb, CategoryScope, 30, btT0, questionPayload, func(i int) string {
		if i%3 == 0 {
			return questionAnswer("redis", "")
		}
		return questionAnswer("sqlite", "")
	})
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		require.Equal(t, []string{"sqlite", "redis"}, in.Options)
		return "sqlite", "medium", nil
	}}
	judge := &btJudge{grade: gradeAll(GradeBad)}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 10, judge.calls)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryScope]
	require.Equal(t, 30, r.Total)
	require.Equal(t, 20, r.Agree)
	require.Equal(t, 10, r.Bad)
	require.Zero(t, r.WrongHigh)
	require.InDelta(t, 20.0/30, r.RecBaseline, 1e-9)
	require.Equal(t, BacktestWeak, r.Status)
}

// TestBacktest_AskOptions: a single-choice ask question is an exact match on
// its labels; a check ask goes to the judge, with the owner's words.
func TestBacktest_AskOptions(t *testing.T) {
	d, wb := btDB(t)
	q := seedAsk(t, d, askSeed{wb: wb, answeredAt: btT0})
	c := seedAsk(t, d, askSeed{wb: wb, kind: "check", payload: `{"checklist":[{"id":"c1","text":"run it"}]}`,
		answer: `{"answers":[],"checklist":[{"id":"c1","state":"ok"}],"comments":[],"note":"","verdict":""}`, answeredAt: btT0})
	// The stored choice of the real source is one of the derived options.
	rows, err := d.AnsweredOwnerAsks(wb, nil, false, 10)
	require.NoError(t, err)
	var qp db.WatchmanPrecedent
	for _, r := range rows {
		if r.ID == q {
			p, ok, err := askPrecedent(wb, r)
			require.NoError(t, err)
			require.True(t, ok)
			qp = p
		}
	}
	require.Equal(t, "sqlite", qp.Choice)
	opts, err := backtestOptions(d, qp)
	require.NoError(t, err)
	require.Equal(t, []string{"sqlite", "redis"}, opts)
	// Answered with "Other": the choice is none of the options, so an exact
	// match could never agree; the judge scores it.
	other := qp
	other.Choice = "postgres, as discussed"
	opts, err = backtestOptions(d, other)
	require.NoError(t, err)
	require.Nil(t, opts)
	opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceAsk, SourceKey: fmt.Sprint(c)})
	require.NoError(t, err)
	require.Nil(t, opts)
	opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceAsk, SourceKey: "999999"})
	require.NoError(t, err)
	require.Nil(t, opts, "a deleted ask is a free answer")
	for key, want := range map[string][]string{"lesson:2": {"accepted", "dismissed"}, "comment:1": nil} {
		opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceReview, SourceKey: key, Choice: "accepted"})
		require.NoError(t, err)
		require.Equal(t, want, opts, key)
	}
	require.Equal(t, "Choice: comment\nOwner's words: add a nil check",
		ownerAnswer(db.WatchmanPrecedent{Choice: "comment", OwnerWords: "add a nil check"}))
	require.Equal(t, "Choice: approve", twinAnswer(Decision{Choice: "approve"}, false))
	require.Equal(t, "Choice: approve\nConfidence: high", twinAnswer(Decision{Choice: "approve", Confidence: "high"}, false))
	require.Equal(t, "Owner's words: add a nil check", ownerAnswer(db.WatchmanPrecedent{OwnerWords: "add a nil check"}),
		"an empty choice leaves its line out")
	require.Equal(t, "Reasoning: r", twinAnswer(Decision{Rationale: "r"}, false))
}

func TestBacktest_BusyLock(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	unlock, ok, err := fsutil.TryLockFile(LockPath(dir))
	require.NoError(t, err)
	require.True(t, ok)
	_, err = Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, "", btT0)
	require.ErrorIs(t, err, ErrBusy)
	b, _, err := d.LatestWatchmanBacktest(wb)
	require.NoError(t, err)
	require.Nil(t, b, "a busy run writes nothing")
	unlock()
	_, err = Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, "", btT0)
	require.NoError(t, err)
}

func TestLLMJudge_ParsesReply(t *testing.T) {
	gen := &decideGen{out: "```json\n{\"grades\":[{\"q\":\"\",\"grade\":\"acceptable\",\"why\":\"also fine\"}]}\n```"}
	in := JudgeInput{Situation: "Which cache?", Owner: "Choice: a", Twin: "Choice: b\nConfidence: high"}
	res, usage, err := NewLLMJudge(gen, nil).Grade(context.Background(), in)
	require.NoError(t, err)
	require.Equal(t, JudgeResult{Grades: []string{GradeAcceptable}, Why: []string{"also fine"}}, res)
	require.NotNil(t, usage)
	require.Equal(t, prompts.WatchmanJudge, gen.source)
	require.Equal(t, prompts.Defaults[prompts.WatchmanJudge], gen.system)
	require.Contains(t, gen.user, "=== DATA ===\n<data>\n")
	require.Contains(t, gen.user, `"situation":"Which cache?"`)
	require.Contains(t, gen.user, `"questions":[]`)
	require.Contains(t, gen.user, `"handoff":"none"`)

	gen.out = `{"grades":[{"q":"A?","grade":"same","why":"x"},{"q":"B?","grade":"bad","why":"y"}]}`
	in.Questions = []string{"A?", "B?"}
	res, _, err = NewLLMJudge(gen, nil).Grade(context.Background(), in)
	require.NoError(t, err)
	require.Equal(t, []string{GradeSame, GradeBad}, res.Grades)
	require.Equal(t, []string{"x", "y"}, res.Why)
	require.Contains(t, gen.user, `"questions":["A?","B?"]`)

	// A short list is returned as it is: the backtest counts the missing
	// grades bad.
	gen.out = `{"grades":[{"q":"A?","grade":"same","why":"x"}]}`
	res, _, err = NewLLMJudge(gen, nil).Grade(context.Background(), in)
	require.NoError(t, err)
	require.Equal(t, []string{GradeSame}, res.Grades)

	for _, bad := range []string{"same", `{"same": true}`, `{"grades":[]}`, `{"grades":[{"q":"","grade":"close","why":""}]}`,
		`{"handoff":"justified","why":"x"}`} {
		gen.out = bad
		_, usage, err = NewLLMJudge(gen, nil).Grade(context.Background(), in)
		require.Error(t, err, bad)
		require.NotNil(t, usage)
		for _, modelText := range []string{"close", "'s'", "same\""} {
			require.NotContains(t, err.Error(), modelText, "no model text in a judge error")
		}
	}
}

func TestJudge_HandoffVerdict(t *testing.T) {
	gen := &decideGen{out: `{"handoff":"justified","why":" only he can revoke the token "}`}
	in := JudgeInput{Situation: "Revoke the old deploy token?", Owner: "Choice: done", Twin: "Choice: yes", Handoff: true,
		Questions: []string{"A?", "B?"}}
	res, usage, err := NewLLMJudge(gen, nil).Grade(context.Background(), in)
	require.NoError(t, err)
	require.NotNil(t, usage)
	require.Equal(t, JudgeResult{Handoff: HandoffJustified, HandoffWhy: "only he can revoke the token"}, res)
	require.Contains(t, gen.user, `"handoff":"owner_only"`)

	gen.out = `{"handoff":"unjustified","why":"he meant the second option"}`
	res, _, err = NewLLMJudge(gen, nil).Grade(context.Background(), in)
	require.NoError(t, err)
	require.Equal(t, HandoffUnjustified, res.Handoff)
}

func TestJudge_HandoffReplyWithoutVerdictIsError(t *testing.T) {
	in := JudgeInput{Situation: "Sign in to the registry?", Owner: "Choice: done", Twin: "Choice: yes", Handoff: true}
	for _, bad := range []string{`{"grades":[{"q":"","grade":"same","why":"x"}]}`, `{"handoff":"maybe","why":"x"}`, `{"why":"x"}`} {
		gen := &decideGen{out: bad}
		_, usage, err := NewLLMJudge(gen, nil).Grade(context.Background(), in)
		require.ErrorContains(t, err, "no known handoff verdict", bad)
		require.NotContains(t, err.Error(), "maybe", "the raw model value is never echoed")
		require.NotNil(t, usage)
	}
}

func TestJudge_GradeHandedIsUnknown(t *testing.T) {
	gen := &decideGen{out: `{"grades":[{"grade":"handed"}]}`}
	_, _, err := NewLLMJudge(gen, nil).Grade(context.Background(), JudgeInput{Situation: "s", Owner: "o", Twin: "t"})
	require.ErrorContains(t, err, "unknown grade")
	require.NotContains(t, err.Error(), "handed", "the raw model value is never echoed")
}

// A customised pre-handoff decide or judge template refuses the run before
// any call, row or report: its replies would fail every handed item.
func TestBacktest_RefusesPreHandoffTemplates(t *testing.T) {
	for _, c := range []struct{ id, tmpl string }{
		{prompts.WatchmanJudge, "Grade the twin's decision as same, acceptable or bad. Return {\"grades\":[...]}."},
		{prompts.WatchmanDecide, "Decide the item the way the owner would. Return JSON with choice and confidence."},
	} {
		t.Run(c.id, func(t *testing.T) {
			d, wb := btDB(t)
			require.NoError(t, d.UpsertPrompt(db.Prompt{ID: c.id, Template: c.tmpl, Version: 2}))
			btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
			gen, judge := &btGen{d: d, wb: wb}, &btJudge{}
			res, err := Backtest(context.Background(), d, gen, judge, prompts.New(d, nil), wb, t.TempDir(), btT0.Add(100*time.Hour))
			require.ErrorContains(t, err, "Settings → Prompts")
			require.ErrorContains(t, err, c.id)
			require.Zero(t, res.ID, "no run row")
			require.Empty(t, gen.progress, "no model call")
			var runs int
			require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_backtests`).Scan(&runs))
			require.Zero(t, runs)
		})
	}
}

// btAddReview stores review_code precedents of the review source with the
// given key kind ("comment", "round", "revert"), one hour apart from start.
func btAddReview(t *testing.T, d *db.DB, wb int64, kind string, n int, start time.Time, choice string) []db.WatchmanPrecedent {
	t.Helper()
	ps := make([]db.WatchmanPrecedent, n)
	for i := range ps {
		ps[i] = db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceReview, SourceKey: fmt.Sprintf("%s:%d", kind, i+1),
			Category: CategoryReviewCode, Situation: fmt.Sprintf("review %s importer cache %d", kind, i), Choice: choice,
			DecidedAt: start.Add(time.Duration(i) * time.Hour), Weight: 1}
	}
	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
	return ps
}

// TestBacktest_SkipsRoundOutcomesAndReverts: review_code is measured on its
// comments; the newer round outcomes and undone hunks are not hidden.
func TestBacktest_SkipsRoundOutcomesAndReverts(t *testing.T) {
	d, wb := btDB(t)
	btAddReview(t, d, wb, db.WatchmanReviewComment, 30, btT0, "comment")
	later := btT0.Add(100 * time.Hour)
	btAddReview(t, d, wb, db.WatchmanReviewRound, 10, later, "approve")
	btAddReview(t, d, wb, db.WatchmanReviewRevert, 5, later, "undid hunk")
	gen, judge := &btGen{}, &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Len(t, gen.decideIn, 30)
	for _, in := range gen.decideIn {
		require.Contains(t, in.Situation, "review comment", "only comments are hidden")
		require.Empty(t, in.Options)
	}
	require.Equal(t, 30, judge.calls)
	_, rows := btRows(t, d, wb)
	require.Equal(t, 30, rows[CategoryReviewCode].Total)
	require.Equal(t, BacktestStrong, rows[CategoryReviewCode].Status)
}

// TestBacktest_RoundSituationNeverHidden: with only round outcomes and
// undone hunks the category is not measured, with no model call.
func TestBacktest_RoundSituationNeverHidden(t *testing.T) {
	d, wb := btDB(t)
	btAddReview(t, d, wb, db.WatchmanReviewRound, 40, btT0, "changes")
	btAddReview(t, d, wb, db.WatchmanReviewRevert, 10, btT0, "undid hunk")
	gen, judge := &btGen{}, &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Empty(t, gen.sources)
	require.Zero(t, judge.calls)
	_, rows := btRows(t, d, wb)
	require.Equal(t, BacktestNotMeasured, rows[CategoryReviewCode].Status)
	require.Zero(t, rows[CategoryReviewCode].Total)
}

func TestBacktest_RetriesOnceThenFails(t *testing.T) {
	// A decide call that fails once is retried and the run finishes.
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	fails := 1
	gen := &btGen{decide: func(decideInput) (string, string, error) {
		if fails > 0 {
			fails--
			return "", "", errors.New("provider hiccup")
		}
		return "allow", "low", nil
	}}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Len(t, gen.decideIn, 31)
	_, rows := btRows(t, d, wb)
	require.Equal(t, 30, rows[CategoryPermission].Agree)

	// A decide call that fails twice fails the run.
	d, wb = btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen = &btGen{decide: func(decideInput) (string, string, error) { return "", "", errors.New("provider down") }}
	_, err = Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(100*time.Hour))
	require.ErrorContains(t, err, "provider down")
	require.Len(t, gen.decideIn, 2)

	// A judge reply that cannot be read is retried once, then fails the run.
	d, wb = btDB(t)
	btAdd(t, d, wb, "turn", CategoryTests, 30, btT0, "add a test")
	judge := &btJudge{err: func(call int) error {
		if call == 1 {
			return errors.New("watchman judge: the reply is not a JSON object")
		}
		return nil
	}}
	_, err = Backtest(context.Background(), d, &btGen{}, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 31, judge.calls)
	require.Equal(t, judge.inputs[0], judge.inputs[1], "the retry asks the same")
	require.Contains(t, judge.inputs[0].Situation, "importer cache case tests", "the judge sees the hidden item's situation")

	d, wb = btDB(t)
	btAdd(t, d, wb, "turn", CategoryTests, 30, btT0, "add a test")
	judge = &btJudge{err: func(int) error { return errors.New("watchman judge: the reply is not a JSON object") }}
	_, err = Backtest(context.Background(), d, &btGen{}, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.ErrorContains(t, err, "not a JSON object")
	require.Equal(t, 2, judge.calls)
	b, rows := btRows(t, d, wb)
	require.Equal(t, "failed", b.Status)
	require.NotContains(t, rows, CategoryTests, "the category's row is not written")
}

func TestBacktest_FinishedAtFromClock(t *testing.T) {
	end := btT0.Add(3 * time.Hour)
	prev := backtestClock
	backtestClock = func() time.Time { return end }
	t.Cleanup(func() { backtestClock = prev })
	d, wb := btDB(t)
	_, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, "", btT0)
	require.NoError(t, err)
	b, _ := btRows(t, d, wb)
	require.Equal(t, btT0, b.StartedAt)
	require.NotNil(t, b.FinishedAt)
	require.Equal(t, end, *b.FinishedAt)
}

const threeQuestionPayload = `{"focus":[],"questions":[` +
	`{"id":"q1","question":"Which cache should the importer use?","options":[{"label":"sqlite"},{"label":"redis"}]},` +
	`{"id":"q2","question":"Ship it today?","options":[{"label":"yes"},{"label":"no"}]},` +
	`{"id":"q3","question":"Who reviews it?","options":[{"label":"me"},{"label":"the agent"}]}],"checklist":[]}`

func threeQuestionAnswer(int) string {
	return `{"answers":[{"id":"q1","labels":["sqlite"],"other":""},{"id":"q2","labels":["no"],"other":""},` +
		`{"id":"q3","labels":["me"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
}

// firstN is a btGen handoff func handing the first n decided items to the
// owner and none after.
func firstN(n int) func(decideInput) string {
	calls := 0
	return func(decideInput) string {
		calls++
		if calls <= n {
			return HandoffOwnerOnly
		}
		return HandoffNone
	}
}

// TestBacktest_JustifiedHandoffIsHanded: a justified handoff of a
// three-question ask is one handed item; none of its questions is scored.
func TestBacktest_JustifiedHandoffIsHanded(t *testing.T) {
	d, wb := btDB(t)
	btAddAsks(t, d, wb, CategoryDesign, 30, btT0, threeQuestionPayload, threeQuestionAnswer)
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "sqlite; no; me", "high", nil }, handoff: firstN(10)}
	judge := &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 30, judge.calls)
	for i, in := range judge.inputs {
		require.Equal(t, i < 10, in.Handoff, i)
	}
	_, rows := btRows(t, d, wb)
	r := rows[CategoryDesign]
	require.Equal(t, 10, r.Handed, "one per handed item, however many questions")
	require.Equal(t, 60, r.Total, "only the 20 judged items are scored")
	require.Equal(t, 60, r.Agree)
	require.Equal(t, BacktestStrong, r.Status)
}

// TestBacktest_UnjustifiedHandoffIsOneBad: an unjustified handoff of a
// three-question ask is one bad decision, never bad while sure.
func TestBacktest_UnjustifiedHandoffIsOneBad(t *testing.T) {
	d, wb := btDB(t)
	btAddAsks(t, d, wb, CategoryDesign, 30, btT0, threeQuestionPayload, threeQuestionAnswer)
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "sqlite; no; me", "high", nil }, handoff: firstN(10)}
	judge := &btJudge{handoff: func(JudgeInput) string { return HandoffUnjustified }}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryDesign]
	require.Zero(t, r.Handed)
	require.Equal(t, 70, r.Total, "10 handoffs × 1 + 20 items × 3")
	require.Equal(t, 10, r.Bad)
	require.Equal(t, 60, r.Agree)
	require.Zero(t, r.WrongHigh, "a wrong handoff is not bad while sure, even at high confidence")
	require.Equal(t, BacktestWeak, r.Status)
}

// TestBacktest_HandoffWithExactChoiceStillJudged: a handed item goes to the
// judge even when its choice is the owner's option exactly.
func TestBacktest_HandoffWithExactChoiceStillJudged(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "allow", "high", nil }, handoff: firstN(1)}
	judge := &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 1, judge.calls)
	require.True(t, judge.inputs[0].Handoff)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 1, r.Handed)
	require.Equal(t, 29, r.Total)
	require.Equal(t, 29, r.Agree)
}

// TestBacktest_TooFewScoredIsNotMeasured: handing back cannot make a
// category strong — 12 of 30 handed leaves 18 scored, below MinScored.
func TestBacktest_TooFewScoredIsNotMeasured(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "allow", "high", nil }, handoff: firstN(12)}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	b, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, BacktestNotMeasured, r.Status)
	require.Equal(t, 12, r.Handed)
	require.Equal(t, 18, r.Total)
	require.Equal(t, VerdictStop, b.Verdict)
	require.Equal(t, VerdictStop, Verdict([]db.WatchmanBacktestRow{r,
		{Category: CategoryDesign, Status: BacktestStrong}, {Category: CategoryScope, Status: BacktestStrong}}))
}

// TestBacktest_StrongComputedOnScored: 25 scored with one bad (4 %) and 5
// handed is strong: the bar is over scored decisions.
func TestBacktest_StrongComputedOnScored(t *testing.T) {
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	wrong := ps[0].Situation // the oldest hidden: decided last
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		if in.Situation == wrong {
			return "deny", "low", nil
		}
		return "allow", "high", nil
	}, handoff: firstN(5)}
	judge := &btJudge{grade: gradeAll(GradeBad)}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 5, r.Handed)
	require.Equal(t, 25, r.Total)
	require.Equal(t, 1, r.Bad)
	require.Equal(t, BacktestStrong, r.Status)
}

// TestBacktest_D37ClaimGradedBad: the judge's bad for a twin that states an
// owner-only action as done counts bad (the prompt pins the rule itself).
func TestBacktest_D37ClaimGradedBad(t *testing.T) {
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, "turn", CategoryTests, 30, btT0, "rotate the token")
	claim := ps[10].Situation
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "rotate the token", "high", nil },
		rationale: func(in decideInput) string {
			if in.Situation == claim {
				return "old token deleted"
			}
			return "because"
		}}
	judge := &btJudge{grade: func(in JudgeInput) []string {
		if strings.Contains(in.Twin, "old token deleted") {
			return []string{GradeBad}
		}
		return []string{GradeSame}
	}}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(100*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryTests]
	require.Equal(t, 30, r.Total)
	require.Equal(t, 1, r.Bad)
	require.Equal(t, 29, r.Agree)
	require.Equal(t, BacktestWeak, r.Status, "bad while sure")
}

// TestBacktest_ReportWriteFailureKeepsRun: a report that cannot be written
// never fails or discards the run.
func TestBacktest_ReportWriteFailureKeepsRun(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	ws := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(ws, "watchman"), []byte("not a folder"), 0o600))
	res, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, ws, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Positive(t, res.ID)
	require.Empty(t, res.ReportPath)
	require.Contains(t, res.ReportError, "writing the backtest report")
	b, rows := btRows(t, d, wb)
	require.Equal(t, "done", b.Status)
	require.Equal(t, VerdictStop, b.Verdict)
	require.Len(t, rows, len(Categories))
	require.Equal(t, 30, rows[CategoryPermission].Agree)
}

// TestBacktest_WritesReportWithJudgeReasons: the report holds one line per
// hidden item in item order with the judge's reasons and handoff verdict,
// and no situation text.
func TestBacktest_WritesReportWithJudgeReasons(t *testing.T) {
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, "turn", CategoryTests, 30, btT0, "add a test")
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "add a test", "medium", nil }, handoff: firstN(1)}
	n := 0
	judge := &btJudge{why: func(JudgeInput) []string { n++; return []string{fmt.Sprintf("reason %d", n)} }}
	ws := t.TempDir()
	res, err := Backtest(context.Background(), d, gen, judge, nil, wb, ws, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Empty(t, res.ReportError)
	start := btT0.Add(100 * time.Hour)
	require.Equal(t, BacktestReportPath(ws, res.ID, start), res.ReportPath)
	require.Equal(t, filepath.Join(ws, "watchman", fmt.Sprintf("backtest-%d-%d.jsonl", res.ID, start.Unix())), res.ReportPath)
	raw, err := os.ReadFile(res.ReportPath)
	require.NoError(t, err)
	require.NotContains(t, string(raw), "importer cache case", "no situation text")
	require.NotContains(t, string(raw), "add a test", "no answer text")
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	require.Len(t, lines, 30)
	for k, l := range lines {
		var m map[string]json.RawMessage
		require.NoError(t, json.Unmarshal([]byte(l), &m))
		require.ElementsMatch(t, []string{"category", "source", "source_key", "handoff", "grades", "handoff_verdict", "why", "confidence"},
			slices.Collect(maps.Keys(m)))
		var line backtestReportLine
		require.NoError(t, json.Unmarshal([]byte(l), &line))
		want := backtestReportLine{Category: CategoryTests, Source: "turn", SourceKey: ps[29-k].SourceKey, Handoff: HandoffNone,
			Grades: []string{GradeSame}, Why: []string{fmt.Sprintf("reason %d", k)}, Confidence: "medium"}
		if k == 0 { // the newest, decided first, was handed
			want.Handoff, want.Grades, want.HandoffVerdict = HandoffOwnerOnly, []string{gradeHanded}, HandoffJustified
			want.Why = []string{"handoff reason justified"}
		}
		require.Equal(t, want, line, k)
	}
}

// TestBacktest_ReportReasonsRedactedClippedAndAligned: a judge reason is
// redacted and clipped to 200 runes; an exact match gets "" so the reasons
// line up with the grades.
func TestBacktest_ReportReasonsRedactedClippedAndAligned(t *testing.T) {
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	other := ps[29].Situation // the newest: the report's first line
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		if in.Situation == other {
			return "deny", "low", nil
		}
		return "allow", "low", nil
	}}
	secret := "ghp_" + strings.Repeat("A1", 15)
	long := "the twin pasted " + secret + " " + strings.Repeat("x", 500)
	judge := &btJudge{grade: gradeAll(GradeAcceptable), why: func(JudgeInput) []string { return []string{long} }}
	ws := t.TempDir()
	res, err := Backtest(context.Background(), d, gen, judge, nil, wb, ws, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	raw, err := os.ReadFile(res.ReportPath)
	require.NoError(t, err)
	require.NotContains(t, string(raw), secret)
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	require.Len(t, lines, 30)
	var first, second backtestReportLine
	require.NoError(t, json.Unmarshal([]byte(lines[0]), &first))
	require.NoError(t, json.Unmarshal([]byte(lines[1]), &second))
	require.Len(t, first.Why, 1)
	require.Contains(t, first.Why[0], "[secret]")
	require.LessOrEqual(t, len([]rune(first.Why[0])), 200)
	require.Equal(t, []string{GradeSame}, second.Grades)
	require.Equal(t, []string{""}, second.Why, "an exact match has no reason, padded to the grades")
}

// TestBacktest_ReportNeverRemovesWhatItDidNotCreate: something already at
// the report path is neither overwritten nor removed; the run is kept.
func TestBacktest_ReportNeverRemovesWhatItDidNotCreate(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	ws := t.TempDir()
	// The run's id is the first backtest id: 1.
	occupied := BacktestReportPath(ws, 1, btT0.Add(100*time.Hour))
	require.NoError(t, os.MkdirAll(occupied, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(occupied, "keep"), []byte("x"), 0o600))
	res, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, ws, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Equal(t, int64(1), res.ID)
	require.Empty(t, res.ReportPath)
	require.Contains(t, res.ReportError, "creating it")
	require.FileExists(t, filepath.Join(occupied, "keep"))
	b, _ := btRows(t, d, wb)
	require.Equal(t, "done", b.Status)
}

// TestBacktest_ReportNameSurvivesReusedID: a stale report left under the
// same id (an old-style name, or another run's start) does not block the
// new run's report.
func TestBacktest_ReportNameSurvivesReusedID(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	ws := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(ws, "watchman"), 0o700))
	stale := []string{filepath.Join(ws, "watchman", "backtest-1.jsonl"), BacktestReportPath(ws, 1, btT0)}
	for _, p := range stale {
		require.NoError(t, os.WriteFile(p, []byte("stale\n"), 0o600))
	}
	start := btT0.Add(100 * time.Hour)
	res, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, ws, start)
	require.NoError(t, err)
	require.Equal(t, int64(1), res.ID)
	require.Empty(t, res.ReportError)
	require.Equal(t, BacktestReportPath(ws, 1, start), res.ReportPath)
	for _, p := range stale {
		b, err := os.ReadFile(p)
		require.NoError(t, err)
		require.Equal(t, "stale\n", string(b), "a stale report is left alone")
	}
}

const signInPayload = `{"focus":[],"questions":[` +
	`{"id":"q1","question":"Sign in to the registry?","options":[{"label":"Signed in"},{"label":"Could not sign in"}]}],"checklist":[]}`

func signInAnswer(int) string {
	return `{"answers":[{"id":"q1","labels":["Signed in"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
}

// TestBacktest_HandoffSendsNoOptionLabel: a handed item reaches the judge as
// "Handed to the owner: <why>", never with the option the twin picked.
func TestBacktest_HandoffSendsNoOptionLabel(t *testing.T) {
	d, wb := btDB(t)
	btAddAsks(t, d, wb, CategoryDesign, 30, btT0, signInPayload, signInAnswer)
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "Signed in", "high", nil }, handoff: firstN(1)}
	judge := &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.NotEmpty(t, judge.inputs)
	in := judge.inputs[0]
	require.True(t, in.Handoff)
	require.NotContains(t, in.Twin, "Signed in")
	require.Contains(t, in.Twin, "Handed to the owner:")
	require.Contains(t, in.Twin, "Confidence: high")
}

// TestBacktest_ConfirmationHandoffJustifiedIsHanded: options that confirm the
// owner's own action, handed and ruled justified, count as handed, not bad.
func TestBacktest_ConfirmationHandoffJustifiedIsHanded(t *testing.T) {
	d, wb := btDB(t)
	payload := `{"focus":[],"questions":[{"id":"q1","question":"Connect the service?","options":[{"label":"Connected it"},{"label":"Skip"}]}],"checklist":[]}`
	answer := func(int) string {
		return `{"answers":[{"id":"q1","labels":["Connected it"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
	}
	btAddAsks(t, d, wb, CategoryDesign, 30, btT0, payload, answer)
	gen := &btGen{decide: func(decideInput) (string, string, error) { return "Connected it", "high", nil }, handoff: firstN(5)}
	judge := &btJudge{handoff: func(JudgeInput) string { return HandoffJustified }}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, "", btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryDesign]
	require.Equal(t, 5, r.Handed)
	require.Zero(t, r.Bad)
}
