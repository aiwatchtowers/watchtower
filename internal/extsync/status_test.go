package extsync

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func sourceStatus(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	var s string
	require.NoError(t, d.QueryRow(`SELECT status FROM ext_sources WHERE id = ?`, id).Scan(&s))
	return s
}

func sourceError(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	var s string
	require.NoError(t, d.QueryRow(`SELECT error FROM ext_sources WHERE id = ?`, id).Scan(&s))
	return s
}

// addSource adds a second source "OPS" on the same account.
func addSource(t *testing.T, d *db.DB, acct int64, key string) int64 {
	t.Helper()
	id, err := d.CreateExtSource("confluence", acct, key, key+"-id", key)
	require.NoError(t, err)
	return id
}

// testHints stands in for the provider's wired Options.Hints (cmd wires the
// Confluence texts; TestExtSyncOptions_WiresTheConfluenceHints pins them).
func testHints(id int64) (revoked, consent string) {
	return fmt.Sprintf("revoked hint for %d", id), fmt.Sprintf("consent hint for %d", id)
}

func TestStatusTransitions(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		want     string
		wantText string // "" = err.Error() of the run
		runFails bool
	}{
		{"revoked", fmt.Errorf("wrap: %w", ErrAuthRevoked), "revoked", "revoked hint for %d", false},
		{"scope", fmt.Errorf("403 scope does not match: %w", ErrNeedsConsent), "needs_consent", "consent hint for %d", false},
		{"other", errors.New("boom"), "error", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, src := newSourceDB(t)
			f := newFake()
			f.failWith(tc.err)
			e := New(d, Options{Hints: testHints})
			e.SetFetcher(src.JiraAccountID, f)
			_, err := e.Run(context.Background())
			assert.Equal(t, tc.runFails, err != nil, "only a real failure is returned from Run: %v", err)
			assert.Equal(t, tc.want, sourceStatus(t, d, src.ID))
			if tc.wantText != "" {
				assert.Equal(t, fmt.Sprintf(tc.wantText, src.JiraAccountID), sourceError(t, d, src.ID))
			} else {
				assert.Contains(t, sourceError(t, d, src.ID), "boom")
			}
			// a clean pass writes ok back
			_, err = e.Run(context.Background())
			require.NoError(t, err)
			assert.Equal(t, "ok", sourceStatus(t, d, src.ID))
			assert.Empty(t, sourceError(t, d, src.ID))
		})
	}
}

// RunSource (the CLI path) records like Run but surfaces the expected
// states' hints as its error.
func TestRunSourceReturnsHint(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.failWith(ErrAuthRevoked)
	e := New(d, Options{Hints: testHints})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.RunSource(context.Background(), src)
	require.ErrorIs(t, err, ErrAuthRevoked)
	assert.Contains(t, err.Error(), fmt.Sprintf("revoked hint for %d", src.JiraAccountID))
	assert.Equal(t, "revoked", sourceStatus(t, d, src.ID))
}

// Without wired hints the engine records a provider-neutral text: it names
// no provider and no provider-specific command.
func TestDefaultHintsAreProviderNeutral(t *testing.T) {
	d, src := newSourceDB(t)
	e := New(d, Options{ScopesOK: func(int64) bool { return false }})
	e.SetFetcher(src.JiraAccountID, newFake())
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	text := sourceError(t, d, src.ID)
	assert.NotEmpty(t, text)
	assert.NotContains(t, strings.ToLower(text), "confluence")
	assert.NotContains(t, text, "--with-")
}

// A revoked account stops all its sources for the run, without calling the
// fetcher for the siblings.
func TestRevokedStopsTheAccountsOtherSources(t *testing.T) {
	d, src := newSourceDB(t)
	ops := addSource(t, d, src.JiraAccountID, "OPS")
	f := newFake()
	f.failWith(ErrAuthRevoked)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "revoked", sourceStatus(t, d, src.ID))
	assert.Equal(t, "revoked", sourceStatus(t, d, ops))
	assert.Equal(t, 1, f.netCalls, "the sibling source made no call")
}

// An ordinary error fails only its own source; the next one still runs.
func TestErrorContinuesWithNextSource(t *testing.T) {
	d, src := newSourceDB(t)
	ops := addSource(t, d, src.JiraAccountID, "OPS")
	f := newFake()
	f.addPage("p1", 1, time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC))
	f.failWith(errors.New("boom"))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.Error(t, err)
	assert.Equal(t, "error", sourceStatus(t, d, src.ID))
	assert.Equal(t, "ok", sourceStatus(t, d, ops))
	assert.Equal(t, 1, countDocs(t, d, ops))
}

func TestMissingScopesMeansNoNetwork(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	e := New(d, Options{ScopesOK: func(int64) bool { return false }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "needs_consent", sourceStatus(t, d, src.ID))
	assert.Zero(t, f.netCalls, "no fetcher call when scopes are missing")
	var jiraStatus string
	require.NoError(t, d.QueryRow(`SELECT status FROM jira_accounts WHERE id = ?`, src.JiraAccountID).Scan(&jiraStatus))
	assert.Equal(t, "ok", jiraStatus, "Confluence never touches the Jira account status")
}

func TestCancelledContextRecordsNothing(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f.failWith(context.Canceled)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(ctx)
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, "ok", sourceStatus(t, d, src.ID))
	assert.Empty(t, loadSource(t, d).LastSyncedAt)
}

func TestCleanRunStampsLastSynced(t *testing.T) {
	d, src := newSourceDB(t)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, newFake())
	_, err := e.RunSource(context.Background(), src)
	require.NoError(t, err)
	assert.Equal(t, "2026-09-26T12:00:00Z", loadSource(t, d).LastSyncedAt)
}

// R8: a Changed call that carried a stored token and failed drops the token,
// so the next cycle starts fresh from the cursor instead of wedging on it.
func TestFailedResumedTokenIsDropped(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	_, err := d.Exec(`UPDATE ext_sources SET page_cursor = '2026-09-01T09:00:00Z', page_token = '|expired' WHERE id = ?`, src.ID)
	require.NoError(t, err)
	f.failWith(errors.New("400: invalid cursor"))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err = e.Run(context.Background())
	require.Error(t, err)
	stored := loadSource(t, d)
	assert.Empty(t, stored.PageToken, "the rejected token is dropped")
	assert.Equal(t, "2026-09-01T09:00:00Z", stored.PageCursor, "the cursor is kept")

	f.resetCalls()
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	calls := f.changedCalls()
	require.NotEmpty(t, calls)
	assert.Equal(t, changedCall{since: time.Date(2026, 9, 1, 8, 59, 0, 0, time.UTC)}, calls[0], "a fresh pass from the cursor")
	assert.Equal(t, 1, f.fetches["p1"])
}

// A failed fresh pass (no token) and a cancelled ctx leave the stream state
// alone.
func TestFailedFreshPassKeepsState(t *testing.T) {
	d, src := newSourceDB(t)
	_, err := d.Exec(`UPDATE ext_sources SET page_cursor = '2026-09-01T09:00:00Z' WHERE id = ?`, src.ID)
	require.NoError(t, err)
	f := newFake()
	f.failWith(errors.New("boom"))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, err = e.Run(context.Background())
	require.Error(t, err)
	assert.Equal(t, "2026-09-01T09:00:00Z", loadSource(t, d).PageCursor)
}

// A malformed cursor fails before any network call, on the resumed path too.
func TestMalformedCursorFailsBeforeNetwork(t *testing.T) {
	for _, token := range []string{"", "|2"} {
		d, src := newSourceDB(t)
		_, err := d.Exec(`UPDATE ext_sources SET page_cursor = 'garbage', page_token = ? WHERE id = ?`, token, src.ID)
		require.NoError(t, err)
		f := newFake()
		e := New(d, Options{})
		e.SetFetcher(src.JiraAccountID, f)
		_, err = e.Run(context.Background())
		require.Error(t, err, "token %q", token)
		assert.Zero(t, f.netCalls, "token %q", token)
		assert.Equal(t, token, loadSource(t, d).PageToken, "the stream state is untouched")
	}
}

// Two sources and a budget that fits one batch: the second source is not
// starved by the first one's long backfill.
func TestRunRotatesAfterBudgetCut(t *testing.T) {
	d, src := newSourceDB(t)
	ops := addSource(t, d, src.JiraAccountID, "OPS")
	f := newFake()
	base := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 7; i++ {
		f.addPage(fmt.Sprintf("p%d", i), 1, base.Add(time.Duration(i)*time.Hour))
	}
	clock := &stepClock{t: base, step: time.Minute}
	e := New(d, Options{Budget: 90 * time.Second, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	require.True(t, st.Incomplete)
	first := countDocs(t, d, src.ID)
	require.Positive(t, first)
	require.Zero(t, countDocs(t, d, ops))

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Positive(t, countDocs(t, d, ops), "the second source progresses on the next run")

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Greater(t, countDocs(t, d, src.ID), first, "and the first one resumes after it")
}
