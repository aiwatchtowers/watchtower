package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
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
		out, _ := json.Marshal(map[string]any{"choice": choice, "rationale": "because", "precedent_ids": []int64{},
			"confidence": conf, "category": in.Category, "importance": "low"})
		return string(out), u, "", nil
	}
	return "", u, "", fmt.Errorf("unexpected source %q", src)
}

type btJudge struct {
	same       func(owner, twin string) bool
	err        func(call int) error // nil = never fails
	calls      int
	situations []string
}

func (j *btJudge) Same(_ context.Context, situation, owner, twin string) (bool, *digest.Usage, error) {
	j.calls++
	j.situations = append(j.situations, situation)
	cost := 0.001
	u := &digest.Usage{Tokens: llmusage.Tokens{ReportedCostUSD: &cost}}
	if j.err != nil {
		if err := j.err(j.calls); err != nil {
			return false, u, err
		}
	}
	if j.same == nil {
		return true, u, nil
	}
	return j.same(owner, twin), u, nil
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
	_, err = Backtest(context.Background(), d, gen, judge, nil, wb, btT0.Add(1000*time.Hour))
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
	_, err = Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(1000*time.Hour))
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
	id, err := Backtest(context.Background(), d, gen, judge, nil, wb, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Empty(t, gen.sources, "no model call")
	require.Zero(t, judge.calls)
	b, rows := btRows(t, d, wb)
	require.Equal(t, id, b.ID)
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
		total, agree, wrongHigh int
		want                    string
	}{
		{30, 24, 1, BacktestStrong}, // exactly 80 %
		{30, 23, 0, BacktestWeak},
		{30, 30, 0, BacktestStrong},
		{30, 25, 2, BacktestWeak},   // 6.7 % wrong-while-high
		{40, 32, 2, BacktestStrong}, // exactly 5 %
		{40, 32, 3, BacktestWeak},
		{29, 29, 0, BacktestNotMeasured},
	} {
		got := rowStatus(db.WatchmanBacktestRow{Total: tc.total, Agree: tc.agree, WrongHigh: tc.wrongHigh})
		assert.Equal(t, tc.want, got, "%+v", tc)
	}

	// End to end: 6 of 30 permissions wrong, one of them with high confidence.
	d, wb := btDB(t)
	ps := btAdd(t, d, wb, SourcePermission, CategoryPermission, 40, btT0, "allow")
	wrong := map[string]string{}
	for i, p := range ps[34:] { // six of the hidden ones
		wrong[p.Situation] = map[bool]string{true: "high", false: "low"}[i == 0]
	}
	gen := &btGen{decide: func(in decideInput) (string, string, error) {
		require.Equal(t, []string{"allow", "deny"}, in.Options)
		if conf, ok := wrong[in.Situation]; ok {
			return "deny", conf, nil
		}
		return "allow", "high", nil
	}}
	judge := &btJudge{}
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, btT0.Add(1000*time.Hour))
	require.NoError(t, err)
	require.Zero(t, judge.calls, "options are an exact match, no judge")
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Total)
	require.Equal(t, 24, r.Agree)
	require.Equal(t, 1, r.WrongHigh)
	require.Equal(t, BacktestStrong, r.Status)
	require.InDelta(t, 0.31, r.CostUSD, 1e-9) // one profile call + 30 decide calls at 0.01
}

func TestVerdict_GoStop(t *testing.T) {
	row := func(c, s string) db.WatchmanBacktestRow { return db.WatchmanBacktestRow{Category: c, Status: s} }
	for name, tc := range map[string]struct {
		rows []db.WatchmanBacktestRow
		want string
	}{
		"none": {nil, VerdictStop},
		"three strong with permission": {[]db.WatchmanBacktestRow{row("design", BacktestStrong), row("tests", BacktestStrong),
			row("permission", BacktestStrong)}, VerdictGo},
		"three strong with review_code": {[]db.WatchmanBacktestRow{row("design", BacktestStrong), row("tests", BacktestStrong),
			row("review_code", BacktestStrong), row("permission", BacktestWeak)}, VerdictGo},
		"three strong without permission or review_code": {[]db.WatchmanBacktestRow{row("design", BacktestStrong),
			row("tests", BacktestStrong), row("scope", BacktestStrong), row("permission", BacktestWeak)}, VerdictStop},
		"two strong incl. permission": {[]db.WatchmanBacktestRow{row("permission", BacktestStrong),
			row("review_code", BacktestStrong), row("tests", BacktestNotMeasured)}, VerdictStop},
	} {
		assert.Equal(t, tc.want, Verdict(tc.rows), name)
	}
}

func TestBacktest_WritesProgress(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{d: d, wb: wb}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(100*time.Hour))
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
	id, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, btT0.Add(time.Hour))
	require.NoError(t, err)
	require.NotEqual(t, old, id)
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
	id, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(100*time.Hour))
	require.ErrorContains(t, err, "provider down")
	b, rows := btRows(t, d, wb)
	require.Equal(t, id, b.ID)
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

// TestBacktest_BadTwinReplyIsDisagreement: a reply the twin cannot get
// right is scored, not skipped and not fatal.
func TestBacktest_BadTwinReplyIsDisagreement(t *testing.T) {
	d, wb := btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen := &btGen{decide: func(in decideInput) (string, string, error) { return "maybe", "high", nil }}
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	_, rows := btRows(t, d, wb)
	r := rows[CategoryPermission]
	require.Equal(t, 30, r.Total)
	require.Zero(t, r.Agree)
	require.Zero(t, r.WrongHigh, "no usable confidence")
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
	opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceAsk, SourceKey: fmt.Sprint(c)})
	require.NoError(t, err)
	require.Nil(t, opts)
	opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceAsk, SourceKey: "999999"})
	require.NoError(t, err)
	require.Nil(t, opts, "a deleted ask is a free answer")
	for key, want := range map[string][]string{"lesson:2": {"accepted", "dismissed"}, "comment:1": nil} {
		opts, err = backtestOptions(d, db.WatchmanPrecedent{WorkbenchID: wb, Source: SourceReview, SourceKey: key})
		require.NoError(t, err)
		require.Equal(t, want, opts, key)
	}
	require.Equal(t, "Choice: comment\nOwner's words: add a nil check",
		ownerAnswer(db.WatchmanPrecedent{Choice: "comment", OwnerWords: "add a nil check"}))
	require.Equal(t, "Choice: approve", twinAnswer(Decision{Choice: "approve"}))
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
	_, err = Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, btT0)
	require.ErrorIs(t, err, ErrBusy)
	b, _, err := d.LatestWatchmanBacktest(wb)
	require.NoError(t, err)
	require.Nil(t, b, "a busy run writes nothing")
	unlock()
	_, err = Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, btT0)
	require.NoError(t, err)
}

func TestLLMJudge_ParsesReply(t *testing.T) {
	gen := &decideGen{out: "```json\n{\"same\": false}\n```"}
	same, usage, err := NewLLMJudge(gen, nil).Same(context.Background(), "Which cache?", "Choice: a", "Choice: b")
	require.NoError(t, err)
	require.False(t, same)
	require.NotNil(t, usage)
	require.Equal(t, prompts.WatchmanJudge, gen.source)
	require.Equal(t, prompts.Defaults[prompts.WatchmanJudge], gen.system)
	require.Contains(t, gen.user, "=== DATA ===\n<data>\n")
	require.Contains(t, gen.user, `"situation":"Which cache?"`)
	gen.out = `{"same": true}`
	same, _, err = NewLLMJudge(gen, nil).Same(context.Background(), "s", "a", "a")
	require.NoError(t, err)
	require.True(t, same)
	for _, bad := range []string{"same", `{"verdict": "same"}`} {
		gen.out = bad
		_, usage, err = NewLLMJudge(gen, nil).Same(context.Background(), "s", "a", "b")
		require.Error(t, err, bad)
		require.NotNil(t, usage)
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
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, btT0.Add(1000*time.Hour))
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
	_, err := Backtest(context.Background(), d, gen, judge, nil, wb, btT0.Add(1000*time.Hour))
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
	_, err := Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Len(t, gen.decideIn, 31)
	_, rows := btRows(t, d, wb)
	require.Equal(t, 30, rows[CategoryPermission].Agree)

	// A decide call that fails twice fails the run.
	d, wb = btDB(t)
	btAdd(t, d, wb, SourcePermission, CategoryPermission, 30, btT0, "allow")
	gen = &btGen{decide: func(decideInput) (string, string, error) { return "", "", errors.New("provider down") }}
	_, err = Backtest(context.Background(), d, gen, &btJudge{}, nil, wb, btT0.Add(100*time.Hour))
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
	_, err = Backtest(context.Background(), d, &btGen{}, judge, nil, wb, btT0.Add(100*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 31, judge.calls)
	require.Equal(t, judge.situations[0], judge.situations[1], "the judge sees the hidden item's situation")
	require.Contains(t, judge.situations[0], "importer cache case tests")

	d, wb = btDB(t)
	btAdd(t, d, wb, "turn", CategoryTests, 30, btT0, "add a test")
	judge = &btJudge{err: func(int) error { return errors.New("watchman judge: the reply has no \"same\"") }}
	_, err = Backtest(context.Background(), d, &btGen{}, judge, nil, wb, btT0.Add(100*time.Hour))
	require.ErrorContains(t, err, "no \"same\"")
	require.Equal(t, 2, judge.calls)
	b, _ := btRows(t, d, wb)
	require.Equal(t, "failed", b.Status)
}

func TestBacktest_FinishedAtFromClock(t *testing.T) {
	end := btT0.Add(3 * time.Hour)
	prev := backtestClock
	backtestClock = func() time.Time { return end }
	t.Cleanup(func() { backtestClock = prev })
	d, wb := btDB(t)
	_, err := Backtest(context.Background(), d, &btGen{}, &btJudge{}, nil, wb, btT0)
	require.NoError(t, err)
	b, _ := btRows(t, d, wb)
	require.Equal(t, btT0, b.StartedAt)
	require.NotNil(t, b.FinishedAt)
	require.Equal(t, end, *b.FinishedAt)
}
