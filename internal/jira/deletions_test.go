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
			w.WriteHeader(http.StatusInternalServerError)
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
	fake := &deletionsServer{listed: projectKeys(5), moved: map[string]string{"PROJ-6": "OTHER-9"}}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err)
	assert.Equal(t, 1, removed)
	assert.NotContains(t, storedKeys(t, database, 1), "PROJ-6")
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

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(time.Minute))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 2, searches, "an incomplete listing leaves the project unstamped")
}

func TestCheckDeletedIssues_ListErrorRetriesNextCycle(t *testing.T) {
	database := deletionsDB(t, projectKeys(6))
	fake := &deletionsServer{listStatus: http.StatusInternalServerError}
	s := deletionsSyncer(t, database, fake.start(t), 1)

	removed, err := s.CheckDeletedIssues(context.Background(), deletionsNow)
	require.NoError(t, err, "a per-project failure is logged, not returned")
	assert.Equal(t, 0, removed)
	assert.Len(t, storedKeys(t, database, 1), 6)

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(time.Minute))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 2, searches)
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

	_, err = s.CheckDeletedIssues(context.Background(), deletionsNow.Add(time.Minute))
	require.NoError(t, err)
	searches, _ := fake.counts()
	assert.Equal(t, 2, searches, "a failed lookup leaves the project unstamped")
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
