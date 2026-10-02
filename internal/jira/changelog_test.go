package jira

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// jiraWire renders t the way Jira's REST API does, in a +03:00 profile zone.
func jiraWire(t time.Time) string {
	return t.In(time.FixedZone("", 3*3600)).Format("2006-01-02T15:04:05.000-0700")
}

// historyFake serves one project's search (PROJ-1, linking to OTH-1 and
// OTH-9), the bulk issue fetch (OTH-1 returned, OTH-9 reported as an error)
// and a two-page bulk changelog fetch, counting changelog requests and
// recording what each asked for.
type historyFake struct {
	changelogCalls atomic.Int32
	issueCalls     atomic.Int32
	changelogFail  atomic.Int32 // a status code to answer the changelog with, 0 = serve it
	requested      [][]string
	created        time.Time
	moved          time.Time
}

func newHistoryFake(t *testing.T) (*historyFake, *httptest.Server) {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	f := &historyFake{created: now.Add(-72 * time.Hour), moved: now.Add(-24 * time.Hour)}
	board := makeIssue("PROJ-1")
	board.ID = "101"
	board.Fields.Created = jiraWire(f.created)
	board.Fields.Updated = jiraWire(f.moved)
	board.Fields.IssueLinks = []IssueLink{
		{ID: "l1", Type: IssueLinkType{Name: "Blocks"}, OutwardIssue: &IssueRef{Key: "OTH-1"}},
		{ID: "l2", Type: IssueLinkType{Name: "Relates"}, InwardIssue: &IssueRef{Key: "OTH-9"}},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		body, _ := json.Marshal(SearchResult{Issues: []Issue{board}, IsLast: true})
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[],"isLast":true}`))
	})
	mux.HandleFunc("/rest/api/3/project/PROJ/versions", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	})
	mux.HandleFunc("/rest/api/3/issue/bulkfetch", func(w http.ResponseWriter, _ *http.Request) {
		f.issueCalls.Add(1)
		linked := Issue{ID: "201", Key: "OTH-1", Fields: IssueFields{
			Summary: "linked", IssueType: IssueType{Name: "Task"},
			Status:   Status{Name: "Review", StatusCategory: StatusCategory{Key: "indeterminate"}},
			Assignee: &User{AccountID: "acc-b", DisplayName: "B"},
			Created:  jiraWire(f.created), Updated: jiraWire(f.moved),
		}}
		body, _ := json.Marshal(bulkIssuesResponse{
			Issues:      []Issue{linked},
			IssueErrors: []BulkIssueError{{ID: "OTH-9", ErrorMessage: "Issue does not exist"}},
		})
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/api/3/changelog/bulkfetch", func(w http.ResponseWriter, r *http.Request) {
		f.changelogCalls.Add(1)
		if code := int(f.changelogFail.Load()); code != 0 {
			http.Error(w, `{"errorMessages":["boom"]}`, code)
			return
		}
		var req struct {
			IssueIDsOrKeys []string `json:"issueIdsOrKeys"`
			FieldIDs       []string `json:"fieldIds"`
			NextPageToken  string   `json:"nextPageToken"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&req))
		assert.Equal(t, []string{"status", "assignee"}, req.FieldIDs)
		if req.NextPageToken == "" {
			f.requested = append(f.requested, req.IssueIDsOrKeys)
			_, _ = w.Write([]byte(`{"issueChangeLogs":[{"issueId":"101","changeHistories":[
				{"id":"5","author":{"accountId":"acc-a","displayName":"A"},"created":"` + jiraWire(f.moved) + `",
				 "items":[{"field":"status","fieldId":"status","from":"1","fromString":"To Do","to":"3","toString":"In Progress"},
				          {"field":"assignee","fieldId":"assignee","from":null,"to":"acc-a","toString":"A"},
				          {"field":"labels","fieldId":"labels","toString":"x"}]}]}],
				"nextPageToken":"p2"}`))
			return
		}
		assert.Equal(t, "p2", req.NextPageToken)
		_, _ = w.Write([]byte(`{"issueChangeLogs":[{"issueId":"201","changeHistories":[
			{"id":"7","author":{"accountId":"acc-b","displayName":"B"},"created":"` + jiraWire(f.moved) + `",
			 "items":[{"field":"status","fieldId":"status","fromString":"Open","toString":"Review"}]}]}]}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return f, srv
}

func TestSyncer_Sync_StoresHistoryOfBoardAndLinkedIssues(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	fake, srv := newHistoryFake(t)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	var linked []db.JiraLinkedIssue
	rows, err := database.Query(`SELECT key, status, status_category, assignee_display_name, fetch_error FROM jira_linked_issues ORDER BY key`)
	require.NoError(t, err)
	for rows.Next() {
		var l db.JiraLinkedIssue
		require.NoError(t, rows.Scan(&l.Key, &l.Status, &l.StatusCategory, &l.AssigneeDisplayName, &l.FetchError))
		linked = append(linked, l)
	}
	require.NoError(t, rows.Close())
	require.Len(t, linked, 2)
	assert.Equal(t, db.JiraLinkedIssue{Key: "OTH-1", Status: "Review", StatusCategory: "in_progress", AssigneeDisplayName: "B"}, linked[0])
	assert.Equal(t, "OTH-9", linked[1].Key)
	assert.Equal(t, "Issue does not exist", linked[1].FetchError)

	require.Len(t, fake.requested, 1)
	assert.ElementsMatch(t, []string{"101", "201"}, fake.requested[0], "one request names the board and the linked issue by id")

	got, err := database.ListJiraIssueChangelog(1, []string{"PROJ-1", "OTH-1"})
	require.NoError(t, err)
	require.Len(t, got["PROJ-1"], 2, "status and assignee kept, labels dropped")
	st := got["PROJ-1"][1]
	if st.Field != "status" {
		st = got["PROJ-1"][0]
	}
	assert.Equal(t, "In Progress", st.ToString)
	assert.Equal(t, "A", st.AuthorDisplayName)
	assert.Equal(t, db.FormatJiraTime(fake.moved), st.ChangedAt, "stored in UTC like every Jira timestamp")
	require.Len(t, got["OTH-1"], 1)

	// Nothing changed: the next pass asks for no history.
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	assert.EqualValues(t, 2, fake.changelogCalls.Load(), "the second pass found nothing due")
}

func TestSyncer_Sync_HistoryOffByDefault(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	fake, srv := newHistoryFake(t)
	s := quietSyncer(t, database, srv.URL)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	assert.Zero(t, fake.changelogCalls.Load())
	assert.Zero(t, fake.issueCalls.Load())
}

func TestSyncer_Sync_ChangelogFailureKeepsIssuesDue(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	fake, srv := newHistoryFake(t)
	fake.changelogFail.Store(http.StatusInternalServerError)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	_, err := s.Sync(context.Background())
	require.NoError(t, err, "an ordinary changelog failure is logged, not an account failure")

	due, err := database.ListJiraChangelogDue(1, 10)
	require.NoError(t, err)
	assert.Len(t, due, 2, "no cursor was stamped, so both issues stay due")

	state, err := database.GetJiraSyncState(1, "PROJ")
	require.NoError(t, err)
	require.NotNil(t, state)
	assert.NotEmpty(t, state.LastSyncedAt, "the issue watermark does not depend on the history step")
}

func TestSyncer_Sync_ChangelogLimitCapsThePass(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	fake, srv := newHistoryFake(t)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(1)

	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	require.NotEmpty(t, fake.requested)
	assert.Len(t, fake.requested[0], 1)
}

func TestSyncer_Sync_RevokedGrantDuringHistoryAbortsAccount(t *testing.T) {
	stubTokenEndpoint(t)
	database := syncerDBWithBoard(t, "PROJ")
	fake, srv := newHistoryFake(t)
	fake.changelogFail.Store(http.StatusUnauthorized)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	_, err := s.Sync(context.Background())
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrAuthRevoked), "got %v", err)
}

func TestBulkFetchChangelogs_PageGuardStoresNothing(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		_, _ = w.Write([]byte(`{"issueChangeLogs":[{"issueId":"1","changeHistories":[]}],"nextPageToken":"again"}`))
	}))
	t.Cleanup(srv.Close)

	got, err := makeTestClient(t, srv.URL).BulkFetchChangelogs(context.Background(), []string{"1"}, changelogFields)
	require.Error(t, err)
	assert.Nil(t, got, "a history cut short by the guard is never returned")
	assert.EqualValues(t, maxChangelogPages, calls.Load())
}

// seedBoardIssues writes n board issues PROJ-1..n with ids 1..n.
func seedBoardIssues(t *testing.T, database *db.DB, n int) {
	t.Helper()
	ts := db.FormatJiraTime(time.Now().UTC())
	issues := make([]db.JiraIssue, n)
	for i := range issues {
		issues[i] = db.JiraIssue{AccountID: 1, Key: "PROJ-" + strconv.Itoa(i+1), ID: strconv.Itoa(i + 1), ProjectKey: "PROJ",
			Summary: "S", Status: "Open", StatusCategory: "todo", Labels: `[]`, Components: `[]`,
			CreatedAt: ts, UpdatedAt: ts, SyncedAt: ts}
	}
	require.NoError(t, database.UpsertJiraIssueBatch(issues, nil))
}

func TestSyncChangelogs_BatchesAndSplitsARejectedRequest(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	seedBoardIssues(t, database, 101)
	var sizes []int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			IssueIDsOrKeys []string `json:"issueIdsOrKeys"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&req))
		sizes = append(sizes, len(req.IssueIDsOrKeys))
		for _, id := range req.IssueIDsOrKeys {
			if id == "7" { // the site refuses one issue
				http.Error(w, `{"errorMessages":["bad id 7"]}`, http.StatusBadRequest)
				return
			}
		}
		_, _ = w.Write([]byte(`{"issueChangeLogs":[]}`))
	}))
	t.Cleanup(srv.Close)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	err := s.syncChangelogs(context.Background())
	require.Error(t, err, "the refused issue is reported")
	assert.Equal(t, 100, sizes[0])
	assert.Equal(t, 1, sizes[len(sizes)-1], "the 101st issue is its own batch")

	due, err := database.ListJiraChangelogDue(1, 500)
	require.NoError(t, err)
	require.Len(t, due, 1, "only the refused issue stays due; its 99 batch mates are stored")
	assert.Equal(t, "PROJ-7", due[0].Key)
}

func TestSyncChangelogs_OutageIsNotSplit(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	seedBoardIssues(t, database, 10)
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		http.Error(w, `{"errorMessages":["down"]}`, http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	require.Error(t, s.syncChangelogs(context.Background()))
	assert.EqualValues(t, 1, calls.Load())
}

func TestSyncLinkedIssues_MovedAndUnreturnedKeys(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	seedBoardIssues(t, database, 1)
	ts := db.FormatJiraTime(time.Now().UTC())
	for i, target := range []string{"OTH-1", "OTH-2"} {
		require.NoError(t, database.UpsertJiraIssueLink(db.JiraIssueLink{AccountID: 1, ID: strconv.Itoa(i), SourceKey: "PROJ-1", TargetKey: target, LinkType: "Blocks", SyncedAt: ts}))
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// OTH-1 was moved: Jira answers with NEW-5. OTH-2 is neither returned nor reported.
		body, _ := json.Marshal(bulkIssuesResponse{Issues: []Issue{{ID: "501", Key: "NEW-5", Fields: IssueFields{Summary: "moved"}}}})
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	s := quietSyncer(t, database, srv.URL)

	require.NoError(t, s.syncLinkedIssues(context.Background()))
	rows, err := database.Query(`SELECT key, fetch_error FROM jira_linked_issues ORDER BY key`)
	require.NoError(t, err)
	defer rows.Close()
	got := map[string]string{}
	for rows.Next() {
		var k, e string
		require.NoError(t, rows.Scan(&k, &e))
		got[k] = e
	}
	assert.Len(t, got, 2, "NEW-5 is not stored: no link names it, so it would only churn")
	assert.Contains(t, got["OTH-1"], "moved")
	assert.NotEmpty(t, got["OTH-2"])
}

func TestSyncLinkedIssues_RevokedGrantAborts(t *testing.T) {
	stubTokenEndpoint(t)
	database := syncerDBWithBoard(t, "PROJ")
	seedBoardIssues(t, database, 1)
	require.NoError(t, database.UpsertJiraIssueLink(db.JiraIssueLink{AccountID: 1, ID: "l", SourceKey: "PROJ-1", TargetKey: "OTH-1", LinkType: "Blocks", SyncedAt: "now"}))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	err := s.syncHistory(context.Background())
	assert.True(t, errors.Is(err, ErrAuthRevoked), "got %v", err)
}

func TestSyncChangelogs_IssueAbsentFromResponseIsStoredWithoutChanges(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	seedBoardIssues(t, database, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"issueChangeLogs":[{"issueId":"1","changeHistories":[{"id":"3","created":"` +
			jiraWire(time.Now()) + `","items":[{"fieldId":"status","fromString":"Open","toString":"Done"}]}]}]}`))
	}))
	t.Cleanup(srv.Close)
	s := quietSyncer(t, database, srv.URL)
	s.SetChangelogLimit(500)

	require.NoError(t, s.syncChangelogs(context.Background()))
	due, err := database.ListJiraChangelogDue(1, 10)
	require.NoError(t, err)
	assert.Empty(t, due, "both cursors stamped")
	got, err := database.ListJiraIssueChangelog(1, []string{"PROJ-1", "PROJ-2"})
	require.NoError(t, err)
	assert.Len(t, got["PROJ-1"], 1)
	assert.Empty(t, got["PROJ-2"])
}
