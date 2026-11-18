package jira

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestReportAccounts_PostsAndReadsStatuses(t *testing.T) {
	var got reportAccountsBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.Equal(t, ReportAccountsPath, r.URL.Path)
		assert.Equal(t, "Bearer at-1", r.Header.Get("Authorization"))
		b, _ := io.ReadAll(r.Body)
		require.NoError(t, json.Unmarshal(b, &got))
		_, _ = w.Write([]byte(`{"accounts":[{"accountId":"a1","status":"closed"},{"accountId":"a2","status":"updated"}]}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, srv.URL+"/token", "at-1")

	at := time.Date(2026, 11, 1, 9, 30, 0, 0, time.UTC)
	st, err := c.ReportAccounts(context.Background(), []ReportedAccount{{AccountID: "a1", UpdatedAt: at}, {AccountID: "a2"}, {AccountID: "a3", UpdatedAt: at}})
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"a1": "closed", "a2": "updated"}, st)
	require.Len(t, got.Accounts, 3)
	assert.Equal(t, "2026-11-01T09:30:00.000Z", got.Accounts[0].UpdatedAt)
	assert.Empty(t, got.Accounts[1].UpdatedAt)
}

func TestReportAccounts_NoContentIsNoAction(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, srv.URL+"/token", "at-1")
	st, err := c.ReportAccounts(context.Background(), []ReportedAccount{{AccountID: "a1"}})
	require.NoError(t, err)
	assert.Empty(t, st)
}

func TestReportAccounts_ScopeRefusedIsScopeMissing(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"403", http.StatusForbidden, `{"message":"forbidden"}`},
		{"401 scope", http.StatusUnauthorized, `{"code":401,"message":"Unauthorized; scope does not match"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			c := newTestClient(t, srv.URL, srv.URL+"/token", "at-1")
			_, err := c.ReportAccounts(context.Background(), []ReportedAccount{{AccountID: "a1"}})
			require.Error(t, err)
			assert.ErrorIs(t, err, ErrReportScopeMissing)
		})
	}
}

func TestReportAccounts_ServerErrorIsAnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, srv.URL+"/token", "at-1")
	_, err := c.ReportAccounts(context.Background(), []ReportedAccount{{AccountID: "a1"}})
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrReportScopeMissing))
}

// TestEnsureUserMap_RefreshesAChangedProfile: an "updated" report is acted
// on by the next sync that meets the person — the stored name and email
// follow the issue payload, the Slack mapping stays.
func TestEnsureUserMap_RefreshesAChangedProfile(t *testing.T) {
	database := openTestDB(t)
	s := NewSyncer(nil, database, nil, nil, 1)
	require.NoError(t, database.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acme-1", Email: "old@example.com", DisplayName: "Old Name", SlackUserID: "1:U0000001", MatchMethod: "email"}))

	s.ensureUserMap(&User{AccountID: "acme-1", DisplayName: "New Name"})
	m, err := database.GetJiraUserMapByAccountID("acme-1")
	require.NoError(t, err)
	assert.Equal(t, "New Name", m.DisplayName)
	assert.Equal(t, "old@example.com", m.Email, "an email Atlassian no longer shows is kept")
	assert.Equal(t, "1:U0000001", m.SlackUserID)

	s.ensureUserMap(&User{AccountID: "acme-1", DisplayName: "New Name", EmailAddress: "new@example.com"})
	m, err = database.GetJiraUserMapByAccountID("acme-1")
	require.NoError(t, err)
	assert.Equal(t, "new@example.com", m.Email)
	assert.Equal(t, "email", m.MatchMethod)
}
