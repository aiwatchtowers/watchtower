package jira

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// commentsMux builds a mux serving one project's incremental search plus a
// comment endpoint per issue key, tracking which issue keys had their
// comment endpoint hit.
func commentsMux(t *testing.T, issues []Issue, commentsByKey map[string]string) (*httptest.Server, *[]string) {
	t.Helper()
	hit := []string{}
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		resp := SearchResult{Issues: issues, IsLast: true}
		body, _ := json.Marshal(resp)
		_, _ = w.Write(body)
	})
	for key, commentBody := range commentsByKey {
		key := key
		commentBody := commentBody
		mux.HandleFunc("/rest/api/3/issue/"+key+"/comment", func(w http.ResponseWriter, _ *http.Request) {
			hit = append(hit, key)
			_, _ = w.Write([]byte(`{"startAt":0,"maxResults":50,"total":1,"comments":[
				{"id":"c-` + key + `","author":{"displayName":"Bob","accountId":"acc-bob"},
				 "body":"` + commentBody + `","created":"2026-01-01T00:00:00.000Z","updated":"2026-01-01T00:00:00.000Z"}
			]}`))
		})
	}
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &hit
}

func makeIssue(key string) Issue {
	return Issue{
		ID:  key,
		Key: key,
		Fields: IssueFields{
			Summary:   "test issue",
			IssueType: IssueType{Name: "Task"},
			Status:    Status{Name: "Open"},
			Created:   "2026-01-01T00:00:00.000+0000",
			Updated:   "2026-01-01T00:00:00.000+0000",
		},
	}
}

func syncerDBWithBoard(t *testing.T, projectKey string) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 1, Name: projectKey, ProjectKey: projectKey, IsSelected: true, SyncedAt: "now",
	}))
	return database
}

// TestSyncer_Sync_FetchesCommentsForChangedIssues pins the end-to-end wiring:
// Sync must fetch and store comments for every issue it just upserted, when
// a positive comment-sync limit is set.
func TestSyncer_Sync_FetchesCommentsForChangedIssues(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	srv, hit := commentsMux(t, []Issue{makeIssue("PROJ-1")}, map[string]string{
		"PROJ-1": "hello",
	})

	s := quietSyncer(t, database, srv.URL)
	s.SetCommentSyncLimit(10)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	assert.ElementsMatch(t, []string{"PROJ-1"}, *hit)

	got, err := database.ListJiraCommentsSince(1, []string{"PROJ-1"}, "2020-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "Bob", got[0].Author)
	assert.Equal(t, "acc-bob", got[0].AuthorAccountID)
	assert.Equal(t, "hello", got[0].BodyText)
}

// TestSyncer_Sync_CommentSyncDisabledByDefault verifies the 0-limit default:
// without an explicit SetCommentSyncLimit call, no comment endpoint is ever
// hit — comment sync stays off until Ideas registry wiring turns it on.
func TestSyncer_Sync_CommentSyncDisabledByDefault(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	srv, hit := commentsMux(t, []Issue{makeIssue("PROJ-1")}, map[string]string{
		"PROJ-1": "hello",
	})

	s := quietSyncer(t, database, srv.URL)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	assert.Empty(t, *hit, "comment endpoint must not be hit when the limit is unset (0 = disabled)")
}

// TestSyncer_Sync_CommentSyncCapsToNewestIssues pins the cap + tail-selection
// contract: with limit 1 and 2 changed issues (oldest-first per the
// `ORDER BY updated ASC` sync JQL), only the newest issue's comments are
// fetched.
func TestSyncer_Sync_CommentSyncCapsToNewestIssues(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	older := makeIssue("PROJ-1")
	newer := makeIssue("PROJ-2")
	srv, hit := commentsMux(t, []Issue{older, newer}, map[string]string{
		"PROJ-1": "old comment",
		"PROJ-2": "new comment",
	})

	s := quietSyncer(t, database, srv.URL)
	s.SetCommentSyncLimit(1)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	assert.Equal(t, []string{"PROJ-2"}, *hit, "only the newest (tail) changed issue's comments should be fetched")
}

// TestSyncer_Sync_CommentFetchErrorLogsAndContinues verifies a per-issue
// comment-fetch failure (a non-auth error) is logged and does not fail the
// whole Sync — the same swallow-and-continue contract as sprint/release sync.
func TestSyncer_Sync_CommentFetchErrorLogsAndContinues(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		resp := SearchResult{Issues: []Issue{makeIssue("PROJ-1")}, IsLast: true}
		body, _ := json.Marshal(resp)
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/api/3/issue/PROJ-1/comment", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	s := quietSyncer(t, database, srv.URL)
	s.SetCommentSyncLimit(10)

	n, err := s.Sync(context.Background())
	require.NoError(t, err, "a per-issue comment fetch error must not fail Sync")
	assert.Equal(t, 1, n)
}

// TestSyncer_Sync_CommentFetchAuthRevokedAborts pins the ErrAuthRevoked
// exception to the log-and-continue rule: a revoked grant during comment
// sync must abort Sync and propagate, the same as the issue/sprint/release
// paths.
func TestSyncer_Sync_CommentFetchAuthRevokedAborts(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		resp := SearchResult{Issues: []Issue{makeIssue("PROJ-1")}, IsLast: true}
		body, _ := json.Marshal(resp)
		_, _ = w.Write(body)
	})
	var calls atomic.Int32
	mux.HandleFunc("/rest/api/3/issue/PROJ-1/comment", func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)

	s := quietSyncer(t, database, srv.URL)
	s.SetCommentSyncLimit(10)

	_, err := s.Sync(context.Background())
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked))
}
