package jira

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
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

// TestLogin_PDRScopeIsOptIn: the report scope is requested only when asked
// (a company's app enables it; another app would refuse the whole grant).
func TestLogin_PDRScopeIsOptIn(t *testing.T) {
	for _, tc := range []struct {
		opts LoginOptions
		want bool
	}{{LoginOptions{}, false}, {LoginOptions{WithConfluence: true}, false}, {LoginOptions{WithPersonalDataReporting: true}, true}} {
		authorizeURL, _ := runLoginCapture(t, tc.opts)
		parsed, err := url.Parse(authorizeURL)
		require.NoError(t, err)
		assert.Equal(t, tc.want, slices.Contains(strings.Fields(parsed.Query().Get("scope")), PDRScope), "%+v", tc.opts)
	}
}

func TestUsersBulk_AsksForEveryID(t *testing.T) {
	var got url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/rest/api/3/user/bulk", r.URL.Path)
		got = r.URL.Query()
		_, _ = w.Write([]byte(`{"isLast":true,"values":[{"accountId":"a1","displayName":"New","emailAddress":"n@example.com"}]}`))
	}))
	defer srv.Close()
	users, err := makeTestClient(t, srv.URL).UsersBulk(context.Background(), []string{"a1", "a2"})
	require.NoError(t, err)
	assert.Equal(t, []string{"a1", "a2"}, got["accountId"])
	assert.Equal(t, "2", got.Get("maxResults"))
	require.Len(t, users, 1)
	assert.Equal(t, User{AccountID: "a1", DisplayName: "New", EmailAddress: "n@example.com"}, users[0])
}

// TestReportAccounts_ScopeAskedButNotGrantedIsNoRelogin: Atlassian is known
// to leave report:personal-data out of a grant that asked for it; a refusal
// on such a grant is ErrReportScopeNotGranted, so no Re-login hint loops.
func TestReportAccounts_ScopeAskedButNotGrantedIsNoRelogin(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, srv.URL+"/token", "at-1")
	tok, err := c.tokenStore.Load()
	require.NoError(t, err)
	tok.RequestedScope = OAuthScopes + " " + PDRScope
	require.NoError(t, c.tokenStore.Save(tok))

	_, err = c.ReportAccounts(context.Background(), []ReportedAccount{{AccountID: "a1"}})
	require.ErrorIs(t, err, ErrReportScopeNotGranted)
	assert.NotErrorIs(t, err, ErrReportScopeMissing)
}

func TestCarryOverUnreturnedFields_KeepsRequestedScope(t *testing.T) {
	fresh := &OAuthToken{AccessToken: "new"}
	carryOverUnreturnedFields(fresh, &OAuthToken{RefreshToken: "rt", Scope: "s", RequestedScope: "s " + PDRScope})
	assert.Equal(t, "s "+PDRScope, fresh.RequestedScope)
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
