package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"watchtower/internal/atlassianpdr"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// orderReporter records its calls into a shared trace; err fails them.
type orderReporter struct {
	trace *[]string
	err   error
}

func (r orderReporter) Report(_ context.Context, _ []string, _ map[string]time.Time) (map[string]atlassianpdr.Status, error) {
	*r.trace = append(*r.trace, "pdr")
	return map[string]atlassianpdr.Status{}, r.err
}

func (r orderReporter) Profiles(context.Context, []string) ([]db.AtlassianProfile, error) {
	return nil, nil
}

// TestPhaseAtlassianPDR_FailureWaitsBeforeRetrying: a failing account (a
// grant without the scope fails until a re-login) is not called every cycle.
func TestPhaseAtlassianPDR_FailureWaitsBeforeRetrying(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: orderReporter{trace: &trace, err: errors.New("scope missing")}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }

	d.phaseAtlassianPDR(context.Background())
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, 1, "the next cycle waits")

	now = now.Add(pdrRetryAfter)
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, 2, "tried again after the wait")
}

// unknownReporter answers the ids in unknown as not found (an incomplete
// lookup) and every other id as fine.
type unknownReporter struct {
	trace   *[]string
	unknown map[string]bool
}

func (r unknownReporter) Report(_ context.Context, ids []string, _ map[string]time.Time) (map[string]atlassianpdr.Status, error) {
	*r.trace = append(*r.trace, "pdr")
	out := map[string]atlassianpdr.Status{}
	for _, id := range ids {
		if r.unknown[id] {
			out[id] = atlassianpdr.StatusUnknown
		}
	}
	return out, nil
}

func (unknownReporter) Profiles(context.Context, []string) ([]db.AtlassianProfile, error) {
	return nil, nil
}

// TestPhaseAtlassianPDR_IncompleteLookupRetriesThenStamps: a lookup that
// leaves an id unanswered stamps no last_pdr_at and is retried
// pdrRetryAfter later (not every cycle); an id the token never sees stops
// the retries after pdrIncompleteCap incomplete runs — the account is then
// stamped and back on the 7-day cadence, the id never treated as closed.
func TestPhaseAtlassianPDR_IncompleteLookupRetriesThenStamps(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: unknownReporter{trace: &trace, unknown: map[string]bool{"acme-1": true}}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }
	lastPDR := func() string {
		a, err := database.GetJiraAccount(1)
		require.NoError(t, err)
		return a.LastPDRAt
	}

	d.phaseAtlassianPDR(context.Background())
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, 1, "the next cycle waits")
	assert.Empty(t, lastPDR())

	for i := 2; i <= pdrIncompleteCap; i++ {
		now = now.Add(pdrRetryAfter)
		d.phaseAtlassianPDR(context.Background())
		assert.Len(t, trace, i, "tried again after the wait, not 7 days later")
	}
	assert.Equal(t, now.Format(time.RFC3339), lastPDR(), "the capped run stamps the report")
	assert.Equal(t, 1, pdrCount(t, database, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = 'acme-1'`), "an unanswered id is never closed")

	now = now.Add(pdrRetryAfter)
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, pdrIncompleteCap, "back on the 7-day cadence")
}

// TestPhaseAtlassianPDR_AnsweredOnRetryStampsNormally: an id answered on
// the second try ends the streak and stamps the report as usual.
func TestPhaseAtlassianPDR_AnsweredOnRetryStampsNormally(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	unknown := map[string]bool{"acme-1": true}
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: unknownReporter{trace: &trace, unknown: unknown}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }

	d.phaseAtlassianPDR(context.Background())
	delete(unknown, "acme-1")
	now = now.Add(pdrRetryAfter)
	d.phaseAtlassianPDR(context.Background())

	assert.Len(t, trace, 2)
	a, err := database.GetJiraAccount(1)
	require.NoError(t, err)
	assert.Equal(t, now.Format(time.RFC3339), a.LastPDRAt)
	assert.Zero(t, d.pdrIncomplete[1], "a complete run ends the streak")
}

// flakyReporter fails the calls whose 1-based index is in failOn and
// otherwise answers every id as not found.
type flakyReporter struct {
	calls  *int
	failOn map[int]bool
}

func (r flakyReporter) Report(_ context.Context, ids []string, _ map[string]time.Time) (map[string]atlassianpdr.Status, error) {
	*r.calls++
	if r.failOn[*r.calls] {
		return nil, errors.New("network")
	}
	out := map[string]atlassianpdr.Status{}
	for _, id := range ids {
		out[id] = atlassianpdr.StatusUnknown
	}
	return out, nil
}

func (flakyReporter) Profiles(context.Context, []string) ([]db.AtlassianProfile, error) {
	return nil, nil
}

// TestPhaseAtlassianPDR_ErrorResetsTheIncompleteStreak: incomplete,
// incomplete, error, incomplete is not pdrIncompleteCap incomplete runs in a
// row, so the report is not stamped yet; every try waits pdrRetryAfter.
func TestPhaseAtlassianPDR_ErrorResetsTheIncompleteStreak(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var calls int
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: flakyReporter{calls: &calls, failOn: map[int]bool{3: true}}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }

	for i := 1; i <= 4; i++ {
		d.phaseAtlassianPDR(context.Background())
		d.phaseAtlassianPDR(context.Background())
		assert.Equal(t, i, calls, "one try per wait")
		now = now.Add(pdrRetryAfter)
	}
	a, err := database.GetJiraAccount(1)
	require.NoError(t, err)
	assert.Empty(t, a.LastPDRAt, "the error broke the streak")
	assert.Equal(t, 1, d.pdrIncomplete[1])
}

// pdrCount runs a count query.
func pdrCount(t *testing.T, d *db.DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n))
	return n
}

// TestDaemon_PDRAfterExternalSync: the PDR phase runs in the same cycle,
// after the Confluence sync, so a profile a sync re-wrote is erased last.
func TestDaemon_PDRAfterExternalSync(t *testing.T) {
	d, database, fake := newExternalSyncTestDaemon(t)
	d.config.Knowledge.Connectors.Enabled = true
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	fake.onRun = func() { trace = append(trace, "external") }
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: orderReporter{trace: &trace}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }

	d.runSync(context.Background(), context.Background())

	assert.Equal(t, []string{"external", "pdr"}, trace)
	a, err := database.GetJiraAccount(1)
	require.NoError(t, err)
	assert.Equal(t, now.Format(time.RFC3339), a.LastPDRAt)
}

func TestPhaseAtlassianPDR_SkipsHeldAndForbidden(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: orderReporter{trace: &trace}}})

	d.purgeHold = map[purgeKey]bool{{"jira", 1}: true}
	d.phaseAtlassianPDR(context.Background())
	assert.Empty(t, trace, "an account whose purge holds it reports nothing")

	policytest.Set(t, map[string]any{"AllowedSources": []any{"linear"}})
	d.purgeHold = nil
	d.phaseAtlassianPDR(context.Background())
	assert.Empty(t, trace, "a source the policy forbids is not contacted")

	policytest.Set(t, map[string]any{})
	d.phaseAtlassianPDR(context.Background())
	assert.Equal(t, []string{"pdr"}, trace)
}
