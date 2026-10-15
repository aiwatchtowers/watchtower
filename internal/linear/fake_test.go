package linear

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fakeLinear is an httptest Linear: it serves canned GraphQL pages chosen by
// a substring of the query and a token endpoint at /oauth/token.
type fakeLinear struct {
	*httptest.Server

	mu       sync.Mutex
	requests []fakeRequest
	calls    map[string]int // per operation kind

	viewerTeams        []string
	teams              []map[string]any
	users              []map[string]any
	issuePages         [][]map[string]any
	commentPages       [][]map[string]any
	cycles             []map[string]any
	projects           []map[string]any
	failIssuePage      int  // 1-based issues call answered with RATELIMITED; 0 = never
	failComments       bool // every comments call answers a GraphQL error
	failPlanning       bool // every planning (team cycles/projects) call answers a GraphQL error
	alwaysUnauthorized bool
}

type fakeRequest struct {
	Kind string
	Vars map[string]any
}

func newFakeLinear(t *testing.T) *fakeLinear {
	t.Helper()
	f := &fakeLinear{calls: map[string]int{}}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f
}

func fakeKind(query string) string {
	for _, k := range []struct{ marker, kind string }{
		{"viewer {", "viewer"}, {"issues(", "issues"}, {"comments(", "comments"},
		{"users(", "users"}, {"team(id:", "planning"}, {"teams(", "teams"},
	} {
		if strings.Contains(query, k.marker) {
			return k.kind
		}
	}
	return "unknown"
}

func (f *fakeLinear) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.URL.Path == "/oauth/token" {
		if f.alwaysUnauthorized {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
		return
	}
	if f.alwaysUnauthorized {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var req struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	kind := fakeKind(req.Query)
	f.calls[kind]++
	f.requests = append(f.requests, fakeRequest{Kind: kind, Vars: req.Variables})

	var data map[string]any
	switch kind {
	case "viewer":
		nodes := []map[string]any{}
		for _, id := range f.viewerTeams {
			nodes = append(nodes, map[string]any{"id": id})
		}
		data = map[string]any{"viewer": map[string]any{
			"id": "user-1", "name": "Owner", "email": "owner@example.com",
			"organization": map[string]any{"id": "org-1", "name": "Acme", "urlKey": "acme"},
			"teams":        map[string]any{"nodes": nodes},
		}}
	case "teams":
		data = map[string]any{"teams": onePage(f.teams)}
	case "users":
		data = map[string]any{"users": onePage(f.users)}
	case "issues":
		if f.failIssuePage > 0 && f.calls[kind] == f.failIssuePage {
			_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{map[string]any{
				"message": "rate limited", "extensions": map[string]any{"code": "RATELIMITED"}}}})
			return
		}
		data = map[string]any{"issues": pageAt(f.issuePages, req.Variables["after"])}
	case "comments":
		if f.failComments {
			writeGraphQLError(w, "comments unavailable")
			return
		}
		data = map[string]any{"comments": pageAt(f.commentPages, req.Variables["after"])}
	case "planning":
		if f.failPlanning {
			writeGraphQLError(w, "planning unavailable")
			return
		}
		data = map[string]any{"team": map[string]any{
			"cycles":   map[string]any{"nodes": orEmpty(f.cycles)},
			"projects": map[string]any{"nodes": orEmpty(f.projects)},
		}}
	default:
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": data})
}

func writeGraphQLError(w http.ResponseWriter, msg string) {
	_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{map[string]any{
		"message": msg, "extensions": map[string]any{"code": "INTERNAL_SERVER_ERROR"}}}})
}

func orEmpty(v []map[string]any) []map[string]any {
	if v == nil {
		return []map[string]any{}
	}
	return v
}

func onePage(nodes []map[string]any) map[string]any {
	return map[string]any{"nodes": orEmpty(nodes), "pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}}
}

// pageAt serves page N for cursor "pN" (page 0 without a cursor).
func pageAt(pages [][]map[string]any, after any) map[string]any {
	idx := 0
	if s, ok := after.(string); ok && strings.HasPrefix(s, "p") {
		idx, _ = strconv.Atoi(s[1:])
	}
	if idx >= len(pages) {
		return onePage(nil)
	}
	return map[string]any{"nodes": orEmpty(pages[idx]), "pageInfo": map[string]any{
		"hasNextPage": idx < len(pages)-1, "endCursor": "p" + strconv.Itoa(idx+1)}}
}

// issueFiltersForTeam returns the issue filters sent for teamID, oldest first.
func (f *fakeLinear) issueFiltersForTeam(teamID string) []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []map[string]any
	for _, r := range f.requests {
		if r.Kind != "issues" {
			continue
		}
		filter, _ := r.Vars["filter"].(map[string]any)
		team, _ := filter["team"].(map[string]any)
		id, _ := team["id"].(map[string]any)
		if id["eq"] == teamID {
			out = append(out, filter)
		}
	}
	return out
}

func (f *fakeLinear) lastIssueFilterJSON(teamID string) string {
	filters := f.issueFiltersForTeam(teamID)
	if len(filters) == 0 {
		return ""
	}
	b, _ := json.Marshal(filters[len(filters)-1])
	return string(b)
}

// issueNode is a minimal issue of team t-1 with one status change at updatedAt.
func issueNode(id, key, stateType, updatedAt string) map[string]any {
	return map[string]any{
		"id": id, "identifier": key, "previousIdentifiers": []string{}, "title": "Issue " + key,
		"description": "body", "url": "https://linear.app/acme/issue/" + key, "priority": 2,
		"createdAt": "2026-09-01T00:00:00.000Z", "updatedAt": updatedAt, "trashed": false,
		"team":     map[string]any{"id": "t-1", "key": strings.SplitN(key, "-", 2)[0]},
		"state":    map[string]any{"name": "State " + stateType, "type": stateType},
		"assignee": nil, "creator": map[string]any{"id": "user-1", "name": "Owner", "email": "owner@example.com"},
		"labels":    map[string]any{"nodes": []any{}},
		"relations": map[string]any{"nodes": []any{}},
		"history": map[string]any{"nodes": []any{map[string]any{
			"id": "h-" + id, "createdAt": updatedAt, "actor": map[string]any{"id": "user-1", "name": "Owner"},
			"fromState": map[string]any{"id": "s-0", "name": "Todo"},
			"toState":   map[string]any{"id": "s-1", "name": "State " + stateType},
		}}},
	}
}

func commentNode(id, issueID, issueKey, bodyData, updatedAt string) map[string]any {
	return map[string]any{
		"id": id, "body": "hello", "bodyData": bodyData, "createdAt": updatedAt, "updatedAt": updatedAt,
		"user":  map[string]any{"id": "user-2", "name": "Colleague A"},
		"issue": map[string]any{"id": issueID, "identifier": issueKey},
	}
}

var testNow = time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)

func newTestSyncer(t *testing.T, f *fakeLinear) (*db.DB, *Syncer) {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	accountID, err := d.CreateLinearAccount("acme")
	require.NoError(t, err)
	store := NewTokenStore(t.TempDir(), accountID)
	require.NoError(t, store.Save(&Token{AccessToken: "a0", RefreshToken: "r0",
		Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	c := NewClient(OAuthConfig{ClientID: "cid"}, store)
	c.endpoint = f.URL
	c.tokenURL = f.URL + "/oauth/token"
	s := NewSyncer(c, d, accountID, 30)
	s.now = func() time.Time { return testNow }
	return d, s
}
