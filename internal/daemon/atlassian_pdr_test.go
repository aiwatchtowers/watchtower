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

// unknownReporter answers every id as not found (an incomplete lookup).
type unknownReporter struct{ trace *[]string }

func (r unknownReporter) Report(_ context.Context, ids []string, _ map[string]time.Time) (map[string]atlassianpdr.Status, error) {
	*r.trace = append(*r.trace, "pdr")
	out := map[string]atlassianpdr.Status{}
	for _, id := range ids {
		out[id] = atlassianpdr.StatusUnknown
	}
	return out, nil
}

func (unknownReporter) Profiles(context.Context, []string) ([]db.AtlassianProfile, error) {
	return nil, nil
}

// TestPhaseAtlassianPDR_IncompleteLookupRetriesAfterTheWait: a lookup that
// left ids unanswered stamps no last_pdr_at, so the account is due again —
// but the next cycle waits pdrRetryAfter instead of asking every cycle.
func TestPhaseAtlassianPDR_IncompleteLookupRetriesAfterTheWait(t *testing.T) {
	d, database, _ := newExternalSyncTestDaemon(t)
	seedConfluenceSource(t, database)
	_, err := database.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES ('acme-1')`)
	require.NoError(t, err)
	var trace []string
	d.SetAtlassianPDR([]PDRAccount{{ID: 1, Reporter: unknownReporter{trace: &trace}}})
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	d.pdrNow = func() time.Time { return now }

	d.phaseAtlassianPDR(context.Background())
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, 1, "the next cycle waits")
	a, err := database.GetJiraAccount(1)
	require.NoError(t, err)
	assert.Empty(t, a.LastPDRAt)

	now = now.Add(pdrRetryAfter)
	d.phaseAtlassianPDR(context.Background())
	assert.Len(t, trace, 2, "tried again after the wait, not 7 days later")
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
