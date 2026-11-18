package atlassianpdr

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// Sample ids (made up).
const (
	closedID = "acme-closed-1"
	liveID   = "acme-live-2"
)

var t0 = time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)

// fakeReporter answers each call from statuses, or fails the failOn-th call
// (1-based) with err.
type fakeReporter struct {
	statuses map[string]Status
	err      error
	failOn   int
	calls    [][]string
	at       []map[string]time.Time
	// profiles answers Profiles; profilesErr fails it.
	profiles    map[string]db.AtlassianProfile
	profilesErr error
	asked       []string
}

func (f *fakeReporter) Profiles(_ context.Context, ids []string) ([]db.AtlassianProfile, error) {
	f.asked = append(f.asked, ids...)
	if f.profilesErr != nil {
		return nil, f.profilesErr
	}
	var out []db.AtlassianProfile
	for _, id := range ids {
		if p, ok := f.profiles[id]; ok {
			out = append(out, p)
		}
	}
	return out, nil
}

func (f *fakeReporter) Report(_ context.Context, ids []string, at map[string]time.Time) (map[string]Status, error) {
	f.calls = append(f.calls, append([]string(nil), ids...))
	f.at = append(f.at, at)
	if f.err != nil && (f.failOn == 0 || f.failOn == len(f.calls)) {
		return nil, f.err
	}
	out := map[string]Status{}
	for _, id := range ids {
		if s, ok := f.statuses[id]; ok {
			out[id] = s
		}
	}
	return out, nil
}

func newAccount(t *testing.T, d *db.DB, companySlug string) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme", CompanySlug: companySlug})
	require.NoError(t, err)
	return id
}

// seedPeople stores closedID and liveID as assignees of one issue each, in
// jira_user_map and in ext_users.
func seedPeople(t *testing.T, d *db.DB, acct int64) {
	t.Helper()
	for i, id := range []string{closedID, liveID} {
		_, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at,
			assignee_account_id, assignee_email, assignee_display_name, assignee_slack_id)
			VALUES (?, ?, 'ACME', 's', 'Open', 'todo', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z', ?, 'p@example.com', 'Person', '1:U0000001')`,
			acct, fmt.Sprintf("ACME-%d", i+1), id)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT OR IGNORE INTO jira_user_map (jira_account_id, email, slack_user_id, display_name) VALUES (?, 'p@example.com', '1:U0000001', 'Person')`, id)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT OR IGNORE INTO ext_users (provider, ext_user_id, display_name, email, fetched_at) VALUES ('confluence', ?, 'Person', 'p@example.com', '2026-11-03T00:00:00Z')`, id)
		require.NoError(t, err)
	}
}

func count(t *testing.T, d *db.DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n))
	return n
}

// erased reports whether closedID's data is gone from account acct.
func erased(t *testing.T, d *db.DB, acct int64) bool {
	t.Helper()
	return count(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND assignee_account_id = ? AND assignee_display_name != ''`, acct, closedID) == 0 &&
		count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, closedID) == 0 &&
		count(t, d, `SELECT count(*) FROM ext_users WHERE ext_user_id = ?`, closedID) == 0
}

func lastPDR(t *testing.T, d *db.DB, acct int64) string {
	t.Helper()
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	return a.LastPDRAt
}

func TestPDR_ChunksOf90(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	for i := range 181 {
		_, err := d.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES (?)`, fmt.Sprintf("acme-%03d", i))
		require.NoError(t, err)
	}
	r := &fakeReporter{}
	res, err := Run(context.Background(), d, acct, r, t0)
	require.NoError(t, err)
	require.Len(t, r.calls, 3)
	assert.Len(t, r.calls[0], 90)
	assert.Len(t, r.calls[1], 90)
	assert.Len(t, r.calls[2], 1)
	assert.Equal(t, 181, res.Reported)
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	created, ok := parseTime(a.CreatedAt)
	require.True(t, ok, a.CreatedAt)
	for _, at := range r.at[0] {
		assert.Equal(t, created, at, "an id with no fetch time on record is dated by the account's creation, never by now")
	}

	// The next report dates them by the last one.
	r = &fakeReporter{}
	_, err = Run(context.Background(), d, acct, r, t0.Add(Every))
	require.NoError(t, err)
	assert.Equal(t, t0, r.at[0]["acme-000"])
}

func TestPDR_RunsEvery7Days(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	ctx := context.Background()

	r := &fakeReporter{err: errors.New("network down")}
	_, err := Run(ctx, d, acct, r, t0)
	require.Error(t, err)
	assert.Empty(t, lastPDR(t, d, acct), "a failed report stamps nothing")

	r = &fakeReporter{}
	_, err = Run(ctx, d, acct, r, t0)
	require.NoError(t, err)
	assert.Len(t, r.calls, 1)
	assert.Equal(t, t0.Format(time.RFC3339), lastPDR(t, d, acct))

	res, err := Run(ctx, d, acct, r, t0.Add(Every-time.Second))
	require.NoError(t, err)
	assert.True(t, res.NotDue)
	assert.Len(t, r.calls, 1, "not due before 7 days")

	_, err = Run(ctx, d, acct, r, t0.Add(Every))
	require.NoError(t, err)
	assert.Len(t, r.calls, 2, "due again after 7 days")
	assert.Equal(t, t0.Add(Every).Format(time.RFC3339), lastPDR(t, d, acct))
}

func TestPDR_ClosedErasesEveryTable(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	r := &fakeReporter{statuses: map[string]Status{closedID: StatusClosed}}

	res, err := Run(context.Background(), d, acct, r, t0)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Closed)
	assert.True(t, erased(t, d, acct))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_issues WHERE assignee_account_id = ? AND assignee_display_name = 'Person'`, liveID))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, liveID))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM kb_dirty WHERE source = 'jira' AND key = ?`, fmt.Sprintf("jira:%d:ACME-1", acct)),
		"the issue's knowledge document is re-rendered on the next KB pass")
}

func TestPDR_UpdatedRefetchesNextSync(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	r := &fakeReporter{statuses: map[string]Status{liveID: StatusUpdated},
		profiles: map[string]db.AtlassianProfile{liveID: {ID: liveID, DisplayName: "Renamed", Email: "renamed@example.com"}}}

	res, err := Run(context.Background(), d, acct, r, t0)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Updated)
	assert.Equal(t, []string{liveID}, r.asked, "only the updated profile is refetched")
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ? AND display_name = 'Renamed' AND email = 'renamed@example.com'`, liveID))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM ext_users WHERE ext_user_id = ? AND display_name = 'Renamed' AND fetched_at = ?`, liveID, t0.Format(time.RFC3339)))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ? AND display_name = 'Person'`, closedID), "an ok person is untouched")
}

func TestPDR_ProfileRefetchErrorWritesNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	r := &fakeReporter{statuses: map[string]Status{closedID: StatusClosed, liveID: StatusUpdated}, profilesErr: errors.New("network down")}

	_, err := Run(context.Background(), d, acct, r, t0)
	require.Error(t, err)
	assert.False(t, erased(t, d, acct), "every network call comes before any write")
	assert.Empty(t, lastPDR(t, d, acct))
}

// A grant whose sign-in already asked for the scope and did not get it: a
// Re-login cannot help, so the hint is not shown (no endless Re-login loop).
func TestPDR_ScopeAskedButNotGrantedLeavesNoHint(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	_, err := Run(context.Background(), d, acct, &fakeReporter{err: fmt.Errorf("%w: status 403", jira.ErrReportScopeNotGranted)}, t0)
	require.Error(t, err)
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Empty(t, a.Error)
	assert.False(t, erased(t, d, acct))
}

func TestPDR_ScopeMissingOnTheSharedAppLeavesNoHint(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "") // a re-login through the shared app cannot request the scope
	seedPeople(t, d, acct)
	_, err := Run(context.Background(), d, acct, &fakeReporter{err: fmt.Errorf("%w: status 403", jira.ErrReportScopeMissing)}, t0)
	require.Error(t, err)
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Empty(t, a.Error)
}

func TestPDR_ErrorErasesNothing(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{
		{"network", errors.New("dial tcp: connection refused")},
		{"401", fmt.Errorf("reporting accounts: %w", jira.ErrAuthRevoked)},
		{"403", fmt.Errorf("%w: status 403", jira.ErrReportScopeMissing)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := db.OpenTestDB(t)
			acct := newAccount(t, d, "acme")
			seedPeople(t, d, acct)
			for i := range 100 { // a second chunk, which fails after the first answered "closed"
				_, err := d.Exec(`INSERT INTO jira_user_map (jira_account_id) VALUES (?)`, fmt.Sprintf("acme-z%03d", i))
				require.NoError(t, err)
			}
			r := &fakeReporter{statuses: map[string]Status{closedID: StatusClosed}, err: tc.err, failOn: 2}

			_, err := Run(context.Background(), d, acct, r, t0)
			require.Error(t, err)
			assert.Len(t, r.calls, 2)
			assert.False(t, erased(t, d, acct), "an error erases nothing")
			assert.Empty(t, lastPDR(t, d, acct))
			assert.Zero(t, count(t, d, `SELECT count(*) FROM kb_dirty`))
		})
	}
}

func TestPDR_ScopeMissingHint(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	ctx := context.Background()

	_, err := Run(ctx, d, acct, &fakeReporter{err: fmt.Errorf("%w: status 403", jira.ErrReportScopeMissing)}, t0)
	require.ErrorIs(t, err, jira.ErrReportScopeMissing)
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status, "the account keeps syncing")
	assert.Equal(t, db.PDRScopeMissingCode, a.Error)

	_, err = Run(ctx, d, acct, &fakeReporter{}, t0)
	require.NoError(t, err)
	a, err = d.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Empty(t, a.Error, "a later successful report clears the hint")
}

func TestPDR_KillMidEraseAllOrNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	ctx := context.Background()
	r := &fakeReporter{statuses: map[string]Status{closedID: StatusClosed}}

	// The knowledge marks are the transaction's last writes: failing them
	// fails it after every other erase statement ran.
	_, err := d.Exec(`CREATE TRIGGER pdr_test_fail BEFORE INSERT ON kb_dirty BEGIN SELECT RAISE(ABORT, 'killed mid-erase'); END`)
	require.NoError(t, err)
	_, err = Run(ctx, d, acct, r, t0)
	require.Error(t, err)
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_issues WHERE assignee_account_id = ? AND assignee_display_name = 'Person'`, closedID), "nothing changed")
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, closedID))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM ext_users WHERE ext_user_id = ?`, closedID))
	assert.Empty(t, lastPDR(t, d, acct))

	_, err = d.Exec(`DROP TRIGGER pdr_test_fail`)
	require.NoError(t, err)
	_, err = Run(ctx, d, acct, r, t0)
	require.NoError(t, err)
	assert.True(t, erased(t, d, acct), "the next run completes")

	require.NoError(t, d.SetJiraLastPDR(acct, ""))
	_, err = Run(ctx, d, acct, r, t0.Add(time.Hour))
	require.NoError(t, err, "a repeat over erased data is a no-op")
	assert.True(t, erased(t, d, acct))
}

func TestPDR_SharedAppAccountsRunToo(t *testing.T) {
	d := db.OpenTestDB(t)
	shared := newAccount(t, d, "") // signed in through the retired shared app
	company := newAccount(t, d, "acme")
	seedPeople(t, d, shared)
	for _, acct := range []int64{shared, company} {
		r := &fakeReporter{statuses: map[string]Status{closedID: StatusClosed}}
		_, err := Run(context.Background(), d, acct, r, t0)
		require.NoError(t, err)
		assert.Len(t, r.calls, 1, "account %d reports", acct)
		assert.NotEmpty(t, lastPDR(t, d, acct))
	}
	assert.True(t, erased(t, d, shared))
}

func TestPDR_APITokenAccountsSkipped(t *testing.T) {
	d := db.OpenTestDB(t)
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", AuthKind: "api_token"})
	require.NoError(t, err)
	seedPeople(t, d, acct)
	r := &fakeReporter{}
	res, err := Run(context.Background(), d, acct, r, t0)
	require.NoError(t, err)
	assert.True(t, res.Skipped)
	assert.Empty(t, r.calls)
}

// TestPDR_MemoryUntouched: memory people are keyed by Slack ids; the erase
// never writes memory (P6, ask #1518).
func TestPDR_MemoryUntouched(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newAccount(t, d, "acme")
	seedPeople(t, d, acct)
	_, err := d.Exec(`INSERT INTO memory_nodes (id, type, tier, title, path, content_hash, indexed_at) VALUES ('ent_person', 'entity', 'long', 'Person', 'people/person.md', 'h', '2026-11-01T00:00:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO memory_aliases (alias, node_id) VALUES ('1:U0000001', 'ent_person'), (?, 'ent_person')`, "jira:"+closedID)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO memory_provenance (node_id, channel_id, ts_raw, ts_unix) VALUES ('ent_person', 'jira:ACME-1', '1', 1)`)
	require.NoError(t, err)
	snapshot := func() []int {
		return []int{
			count(t, d, `SELECT count(*) FROM memory_nodes`),
			count(t, d, `SELECT count(*) FROM memory_aliases`),
			count(t, d, `SELECT count(*) FROM memory_provenance`),
		}
	}
	before := snapshot()

	_, err = Run(context.Background(), d, acct, &fakeReporter{statuses: map[string]Status{closedID: StatusClosed}}, t0)
	require.NoError(t, err)
	assert.True(t, erased(t, d, acct))
	assert.Equal(t, before, snapshot())
}
