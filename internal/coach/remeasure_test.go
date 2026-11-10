package coach

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// remeasureFixture: one workbench whose task has a Claude session with 2
// interrupts and a Codex one with 4 (all agents: 6) at t0, and Claude
// proposals accepted at applyNow (t0 + 1h) with the mixed baseline 6.
func remeasureFixture(t *testing.T) dbs {
	t.Helper()
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.sessionOf(t, "claude", wb, "sc", ids, 2, 1.0)
	d.sessionOf(t, "codex", wb, "sx", ids, 4, 1.0)
	return d
}

func acceptedAt(t *testing.T, d dbs, dest, after string, baseline *float64, at time.Time) int64 {
	t.Helper()
	id := propose(t, d, db.CoachProposal{Destination: dest, AfterText: after})
	require.NoError(t, d.MarkCoachAccepted(id, after, baseline, 1, at))
	return id
}

func TestRemeasureMixedBaselines(t *testing.T) {
	d := remeasureFixture(t)
	mixed := acceptedAt(t, d, DestClaudeMDUser, "Keep diffs small.", fl(6), applyNow)
	judged := acceptedAt(t, d, DestClaudeMDUser, "Run the tests.", fl(6), applyNow)
	require.NoError(t, d.SetCoachVerdict(judged, "works", fl(1), applyNow.Add(15*24*time.Hour)))
	// Accepted before the sessions: no Claude session in its window.
	empty := acceptedAt(t, d, DestClaudeMDUser, "Be brief.", fl(6), t0.Add(-time.Minute))
	codex := acceptedAt(t, d, "codex_skill_user", "Plan first.", fl(6), applyNow)
	// A NULL baseline is re-taken as well.
	null := acceptedAt(t, d, DestClaudeMDUser, "Read the plan.", nil, applyNow)
	// too_little_data is retried by the judge: its baseline is re-taken too.
	retry := acceptedAt(t, d, DestClaudeMDUser, "Name the test.", fl(6), applyNow)
	require.NoError(t, d.SetCoachVerdict(retry, "too_little_data", nil, applyNow.Add(15*24*time.Hour)))

	n, err := RemeasureMixedBaselines(d.DB, d.al)
	require.NoError(t, err)
	assert.Equal(t, 5, n)

	p := proposal(t, d, mixed)
	require.NotNil(t, p.Baseline)
	assert.InDelta(t, 2.0, *p.Baseline, 1e-9, "Claude rows only")
	assert.Equal(t, 1, p.BaselineN)
	assert.InDelta(t, 6.0, *proposal(t, d, judged).Baseline, 1e-9, "a judged proposal is untouched")
	pe := proposal(t, d, empty)
	assert.Nil(t, pe.Baseline, "nothing measurable in the window")
	assert.Zero(t, pe.BaselineN)
	assert.InDelta(t, 4.0, *proposal(t, d, codex).Baseline, 1e-9, "Codex rows only")
	assert.InDelta(t, 2.0, *proposal(t, d, retry).Baseline, 1e-9, "a retryable verdict is re-measured")
	assert.InDelta(t, 2.0, *proposal(t, d, null).Baseline, 1e-9, "baseline IS NULL matches")

	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.True(t, done)

	// Once only: a second call rewrites nothing.
	require.NoError(t, d.MarkCoachAccepted(propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, AfterText: "x"}),
		"x", fl(6), 1, applyNow))
	n, err = RemeasureMixedBaselines(d.DB, d.al)
	require.NoError(t, err)
	assert.Zero(t, n)
}

func TestRemeasureMixedBaselines_VerdictBetweenListAndCASWins(t *testing.T) {
	d := remeasureFixture(t)
	id := acceptedAt(t, d, DestClaudeMDUser, "Keep diffs small.", fl(6), applyNow)
	n, err := remeasure(d.DB, d.al, func(p db.CoachProposal) {
		require.NoError(t, d.SetCoachVerdict(p.ID, "no_effect", fl(6), applyNow.Add(15*24*time.Hour)))
	})
	require.NoError(t, err)
	assert.Zero(t, n)
	p := proposal(t, d, id)
	assert.InDelta(t, 6.0, *p.Baseline, 1e-9)
	assert.Equal(t, "no_effect", p.Verdict)
	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.True(t, done, "a row another writer took is done")
}

func TestRemeasureMixedBaselines_NoAgentLogWritesTheKey(t *testing.T) {
	d := openDBs(t)
	id := acceptedAt(t, d, DestClaudeMDUser, "Keep diffs small.", fl(6), applyNow)
	n, err := RemeasureMixedBaselines(d.DB, nil)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.InDelta(t, 6.0, *proposal(t, d, id).Baseline, 1e-9)
	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.True(t, done)
}

func TestRemeasureMixedBaselines_WaitsForTheMove(t *testing.T) {
	d := openDBs(t)
	unmoved, err := agentlogdb.Open(filepath.Join(t.TempDir(), "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = unmoved.Close() })
	id := acceptedAt(t, d, DestClaudeMDUser, "Keep diffs small.", fl(6), applyNow)
	n, err := RemeasureMixedBaselines(d.DB, unmoved)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.InDelta(t, 6.0, *proposal(t, d, id).Baseline, 1e-9)
	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.False(t, done, "the next start runs it again")
}

func TestJudge_WaitsForTheRemeasure(t *testing.T) {
	d := openDBs(t)
	unmoved, err := agentlogdb.Open(filepath.Join(t.TempDir(), "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = unmoved.Close() })
	id := acceptedAt(t, d, DestClaudeMDUser, "Keep diffs small.", fl(6), judgeDecided)
	_, _, err = Judge(d.DB, unmoved, judgeDecided.Add(15*24*time.Hour))
	require.ErrorIs(t, err, errBaselinesPending)
	assert.Empty(t, proposal(t, d, id).Verdict, "nothing judged on a mixed baseline")

	// Moved: Judge re-measures first (no Claude session in the window: nil
	// baseline), then judges on it.
	_, _, err = Judge(d.DB, d.al, judgeDecided.Add(15*24*time.Hour))
	require.NoError(t, err)
	p := proposal(t, d, id)
	assert.Nil(t, p.Baseline)
	assert.Equal(t, "too_little_data", p.Verdict)
	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.True(t, done)
}
