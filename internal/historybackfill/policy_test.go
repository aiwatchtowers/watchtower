package historybackfill

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// TestPolicyBackfill_SkipKeepsRowState pins POLICY-03 for the backfill: a
// row of a source the organization forbids is skipped without any state
// change (never off, never paused, its hold and wait kept), and runs again
// once the source is allowed.
func TestPolicyBackfill_SkipKeepsRowState(t *testing.T) {
	row := running(1, "gmail", 7, 30*day, 0)
	row.Waiting = waitingPlanLimit
	st := &fakeStore{rows: []db.HistoryBackfill{row, running(2, "slack", 1, 30*day, 0)}}
	gmail, slack := &fakeSource{kind: "gmail", id: 7}, &fakeSource{kind: "slack", id: 1}
	r := newRunner(st, gmail, slack)
	r.Account = func(string, int64) AccountState { return AccountGone } // would turn the row off if it ran

	policytest.Set(t, map[string]any{"AllowedSources": []any{"slack"}})
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, row, st.rows[0], "the forbidden source's row is untouched")
	assert.Empty(t, gmail.calls)

	r.Account = func(string, int64) AccountState { return AccountOK }
	policytest.Set(t, nil)
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 1, gmail.count("process"), "allowed again: the chunk runs")
	assert.Equal(t, 28*day, st.rows[0].ReachedTS)
}

func TestPolicyBackfill_SourceKindMapping(t *testing.T) {
	for kind, src := range map[string]string{"slack": "slack", "gmail": "google", "imap": "imap", "jira": "jira", "linear": "linear"} {
		assert.Equal(t, src, policySource(kind), kind)
	}
}
