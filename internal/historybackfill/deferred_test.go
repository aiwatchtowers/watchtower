package historybackfill

import (
	"context"
	"testing"
	"time"
	"watchtower/internal/db"

	"github.com/stretchr/testify/require"
)

type providerWait struct{}

func (providerWait) Error() string          { return "quota wait" }
func (providerWait) ProviderDeferred() bool { return true }
func TestRunner_ProviderDeferredNeverAgesIntoStrike(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 1, 30*day, 0), running(2, "jira", 2, 30*day, 0)}}
	old := time.Unix(1, 0)
	st.rows[0].HeldSince = &old
	st.rows[0].ChunkFailures = 2
	src := &fakeSource{kind: "gmail", id: 1, processErr: providerWait{}}
	other := &fakeSource{kind: "jira", id: 2}
	r := newRunner(st, src, other)
	for range 5 {
		require.NoError(t, r.Step(context.Background()))
	}
	require.Equal(t, 30*day, st.rows[0].ReachedTS)
	require.Equal(t, 2, st.rows[0].ChunkFailures)
	require.Zero(t, st.failures)
	require.Equal(t, 5, src.count("fetch"))
	require.Equal(t, 5, other.count("process"))
	require.True(t, st.rows[0].HeldSince.Equal(old))
	src.processErr = nil
	require.NoError(t, r.Step(context.Background()))
	require.Equal(t, 28*day, st.rows[0].ReachedTS)
	require.Nil(t, st.rows[0].HeldSince)
}
