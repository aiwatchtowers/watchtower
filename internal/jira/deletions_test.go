package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// deletionsServer fakes the two endpoints CheckDeletedIssues calls: the
// key-only search (listing `listed`) and the per-issue lookup (404 unless the
// key is in present, moved or failing).
type deletionsServer struct {
	mu         sync.Mutex
	listed     []string
	listStatus int  // non-zero: the search answers with this status
	incomplete bool // the search page says isLast=false with no token
	present    map[string]bool
	moved      map[string]string
	failing    map[string]bool
	failStatus int // status for a failing key; 500 when zero
	onSearch   func()

	searches []string // jql of each search request
	fields   []string // fields of each search request
	lookups  []string // keys looked up
}

func (s *deletionsServer) start(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.searches = append(s.searches, r.URL.Query().Get("jql"))
		s.fields = append(s.fields, r.URL.Query().Get("fields"))
		onSearch := s.onSearch
		s.mu.Unlock()
		if onSearch != nil {
			onSearch()
		}
		if s.listStatus != 0 {
			w.WriteHeader(s.listStatus)
			return
		}
		issues := make([]map[string]string, 0, len(s.listed))
		for _, k := range s.listed {
			issues = append(issues, map[string]string{"id": k, "key": k})
		}
		body, _ := json.Marshal(map[string]any{"issues": issues, "isLast": !s.incomplete})
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/api/3/issue/", func(w http.ResponseWriter, r *http.Request) {
		key := strings.TrimPrefix(r.URL.Path, "/rest/api/3/issue/")
		s.mu.Lock()
		s.lookups = append(s.lookups, key)
		s.mu.Unlock()
		switch {
		case s.failing[key]:
			status := s.failStatus
			if status == 0 {
				status = http.StatusInternalServerError
			}
			w.WriteHeader(status)
		case s.moved[key] != "":
			body, _ := json.Marshal(map[string]string{"id": "1", "key": s.moved[key]})
			_, _ = w.Write(body)
		case s.present[key]:
			body, _ := json.Marshal(map[string]string{"id": "1", "key": key})
			_, _ = w.Write(body)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func (s *deletionsServer) counts() (searches, lookups int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.searches), len(s.lookups)
}

// requests returns copies of the recorded search jql, search fields and lookups.
func (s *deletionsServer) requests() (searches, fields, lookups []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.searches), slices.Clone(s.fields), slices.Clone(s.lookups)
}

// projectKeys returns PROJ-1 … PROJ-n.
func projectKeys(n int) []string {
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("PROJ-%d", i+1)
	}
	return keys
}

// deletionsDB opens a DB with account 1, a selected board 1 on PROJ, the given
// stored PROJ issues and a completed sync watermark for PROJ.
func deletionsDB(t *testing.T, stored []string) *db.DB {
	t.Helper()
	database := syncerDBWithBoard(t, "PROJ")
	storeIssues(t, database, 1, "PROJ", stored...)
	require.NoError(t, database.UpdateJiraSyncState(1, "PROJ", "2026-10-01T00:00:00Z", len(stored)))
	return database
}

func storeIssues(t *testing.T, database *db.DB, accountID int64, project string, keys ...string) {
	t.Helper()
	issues := make([]db.JiraIssue, 0, len(keys))
	for _, k := range keys {
		issues = append(issues, db.JiraIssue{AccountID: accountID, Key: k, ID: k, ProjectKey: project, BoardID: 1,
			Summary: "issue " + k, Status: "Open", StatusCategory: "new",
			Labels: "[]", Components: "[]", FixVersions: "[]", RawJSON: "{}", CustomFieldsJSON: "{}"})
	}
	require.NoError(t, database.UpsertJiraIssueBatch(issues, nil))
}

func deletionsSyncer(t *testing.T, database *db.DB, srv *httptest.Server, accountID int64) *Syncer {
	t.Helper()
	c := makeTestClient(t, srv.URL)
	c.rateLimiter = &RateLimiter{tokens: 1000, maxTokens: 1000, refillRate: 1000, lastRefill: time.Now()}
	s := NewSyncer(c, database, nil, nil, accountID)
	s.SetLogger(log.New(io.Discard, "", 0))
	return s
}

func storedKeys(t *testing.T, database *db.DB, accountID int64) []string {
	t.Helper()
	keys, err := database.JiraProjectIssueKeys(accountID, "PROJ")
	require.NoError(t, err)
	return keys
}

var deletionsNow = time.Date(2026, 10, 21, 9, 0, 0, 0, time.UTC)

func TestCheckDeletedIssues_RemovesConfirmedGone(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(5)}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	searched, fields, lookups := fake.requests()
	assert.Equal(t, 1, removed)
	assert.NotContains(t, storedKeys(t, database, 1), "PROJ-6")
	assert.Len(t, storedKeys(t, database, 1), 5)
	require.Len(t, searched, 1)
	assert.True(t, strings.HasPrefix(searched[0], "project = PROJ "), searched[0])
	assert.Equal(t, "key", fields[0])
	assert.Equal(t, []string{"PROJ-6"}, lookups)

	var count int
	require.NoError(t, database.QueryRow(`SELECT issue_count FROM jira_boards WHERE account_id = 1 AND id = 1`).Scan(&count))
	assert.Equal(t, 5, count, "the board's issue count is recounted")
}

func TestCheckDeletedIssues_MovedIssueRemovesOldKey(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	storeIssues(t, database, 1, "OTHER", "OTHER-9")
	fake := &deletionsServer{listed: projectKeys(5), moved: map[string]string{"PROJ-6": "OTHER-9"}}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	assert.Equal(t, 1, removed)
	assert.NotContains(t, storedKeys(t, database, 1), "PROJ-6")
	other, err := database.JiraProjectIssueKeys(1, "OTHER")
	require.NoError(t, err)
	assert.Equal(t, []string{"OTHER-9"}, other, "the issue's row under its new key is untouched")
}

// SRCDEL-01 supporting: a listing that misses an issue Jira still returns
// under the same key (index lag, an archived issue) deletes nothing.
func TestCheckDeletedIssues_StillPresentIsKept(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(5), present: map[string]bool{"PROJ-6": true}}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, _, lookups := fake.requests()
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)
	assert.Equal(t, []string{"PROJ-6"}, lookups)
}

// SRCDEL-01 supporting: an empty listing over stored issues deletes nothing
// and sends no lookup.
func TestCheckDeletedIssues_EmptyListingDeletesNothing(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, _, lookups := fake.requests()
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)
	assert.Empty(t, lookups)

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(time.Hour))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 1, searches, "a refused diff still stamps the project for the day")
}

// SRCDEL-01 supporting: removing more than half of ten or more stored issues
// is refused before any lookup.
func TestCheckDeletedIssues_OverHalfDeletesNothing(t *testing.T) {
	database := deletionsDB(t, projectKeys(10))
	fake := &deletionsServer{listed: projectKeys(4)}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, _, lookups := fake.requests()
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 10)
	assert.Empty(t, lookups)
}

// SRCDEL-01 supporting: a listing that did not reach its last page deletes
// nothing and is retried on the next call.
func TestCheckDeletedIssues_IncompleteListingDeletesNothing(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(5), incomplete: true}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, _, lookups := fake.requests()
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)
	assert.Empty(t, lookups)

	assertRetriedAfterBackoff(t, s, fake)
}

// assertRetriedAfterBackoff checks that a failed check is not retried on the
// next 15-minute cycle but is once deletionRetryAfter has passed.
func assertRetriedAfterBackoff(t *testing.T, s *Syncer, fake *deletionsServer) {
	t.Helper()
	_, err := s.CheckDeletedIssues(context.Background(), deletionsNow.Add(15*time.Minute))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 1, searches, "the next cycle inside the backoff sends no request")

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(deletionRetryAfter))
	require.NoError(t, err)
	searches, _ = fake.counts()
	assert.Equal(t, 2, searches, "the project is retried once the backoff has passed")
}

func TestCheckDeletedIssues_ListErrorRetriesAfterBackoff(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listStatus: http.StatusInternalServerError}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err, "a per-project failure is logged, not returned")
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)

	assertRetriedAfterBackoff(t, s, fake)
}

func TestCheckDeletedIssues_ConfirmErrorKeepsRest(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(4), failing: map[string]bool{"PROJ-6": true}}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	assert.Equal(t, 1, removed)
	keys := storedKeys(t, database, 1)
	assert.NotContains(t, keys, "PROJ-5", "the key confirmed before the failure is removed")
	assert.Contains(t, keys, "PROJ-6", "the key whose lookup failed is kept")

	assertRetriedAfterBackoff(t, s, fake)
}

// A 403 on the per-key lookup is not a 404: nothing is deleted.
func TestCheckDeletedIssues_ForbiddenLookupDeletesNothing(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(5), failing: map[string]bool{"PROJ-6": true}, failStatus: http.StatusForbidden}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)
	assertRetriedAfterBackoff(t, s, fake)
}

// Keys Jira still returns under the same key do not starve a real deletion
// behind the per-check cap: they are looked up after the unchecked ones.
func TestCheckDeletedIssues_KeptKeysDoNotStarveDeletions(t *testing.T) {
	all := projectKeys(400)
	database := deletionsDB(t, all)
	// PROJ-1 … PROJ-150 are missing from the listing but still exist; they
	// sort before PROJ-999, the one issue really deleted.
	storeIssues(t, database, 1, "PROJ", "PROJ-999")
	present := map[string]bool{}
	for _, k := range all[:150] {
		present[k] = true
	}
	fake := &deletionsServer{listed: all[150:], present: present}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	day := deletionsNow
	for range 3 {
		_, err := s.CheckDeletedIssues(context.Background(), day)
		require.NoError(t, err)
		if !slices.Contains(storedKeys(t, database, 1), "PROJ-999") {
			break
		}
		day = day.Add(deletionCheckEvery)
	}
	keys := storedKeys(t, database, 1)
	assert.NotContains(t, keys, "PROJ-999", "the deletion lands within two daily checks")
	assert.Len(t, keys, 400, "every kept key stays")
	assert.LessOrEqual(t, day.Sub(deletionsNow), deletionCheckEvery)

	// The remembered kept keys still get rechecked when the cap leaves room.
	_, _, before := fake.requests()
	_, err := s.CheckDeletedIssues(context.Background(), day.Add(deletionCheckEvery))
	require.NoError(t, err)
	_, _, after := fake.requests()
	assert.Len(t, after[len(before):], maxIssueConfirms)
}

func TestCheckDeletedIssues_ConfirmCap(t *testing.T) {
	all := projectKeys(400)
	database := deletionsDB(t, all)
	fake := &deletionsServer{listed: all[:250]}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	assert.Equal(t, maxIssueConfirms, removed)
	_, lookups := fake.counts()
	assert.Equal(t, maxIssueConfirms, lookups)
	assert.Len(t, storedKeys(t, database, 1), 300)
}

func TestCheckDeletedIssues_RunsOncePerDay(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(6)}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	_, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(time.Hour))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 1, searches, "a second call within the day sends no request")

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(25*time.Hour))
	require.NoError(t, err)
	searches, _ = fake.counts()
	assert.Equal(t, 2, searches)
}

// An issue synced while the listing is in flight is not in the stored set the
// diff judges, so it is never looked up or removed.
func TestCheckDeletedIssues_ReadsStoredSetBeforeListing(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listed: projectKeys(6)}
	fake.onSearch = func() { storeIssues(t, database, 1, "PROJ", "PROJ-99") }
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	_, _, lookups := fake.requests()
	assert.Equal(t, 0, removed)
	assert.Contains(t, storedKeys(t, database, 1), "PROJ-99")
	assert.Empty(t, lookups)
}

func TestCheckDeletedIssues_ScopedToAccountAndProject(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	a2 := db.SeedTestJiraAccount(t, database)
	storeIssues(t, database, a2, "PROJ", "PROJ-6")
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 2, Name: "NEW", ProjectKey: "NEW", IsSelected: true, SyncedAt: "now",
	}))
	fake := &deletionsServer{listed: projectKeys(5)}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	searched, _, _ := fake.requests()
	assert.Equal(t, 1, removed)
	assert.Contains(t, storedKeys(t, database, a2), "PROJ-6", "another account's same key is untouched")
	require.Len(t, searched, 1, "a project with no completed sync is not listed")
	assert.True(t, strings.HasPrefix(searched[0], "project = PROJ "))
}

func TestCheckDeletedIssues_AuthRevokedAborts(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)
	s := deletionsSyncer(t, database, srv, 1)

	_, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked), "got %v", err)
	assert.Len(t, storedKeys(t, database, 1), 6)
}
