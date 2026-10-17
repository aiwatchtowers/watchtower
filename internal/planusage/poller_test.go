package planusage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

type fakeCreds struct {
	c   Credentials
	err error
}

func (f fakeCreds) Load(context.Context) (Credentials, error) { return f.c, f.err }

type fakeFetch struct {
	body   []byte
	err    error
	calls  int
	tokens []string
}

func (f *fakeFetch) Fetch(_ context.Context, tok string) ([]byte, error) {
	f.calls++
	f.tokens = append(f.tokens, tok)
	return f.body, f.err
}

func newPoller(t *testing.T, creds fakeCreds, fetch *fakeFetch, now time.Time) (*Poller, *db.DB) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return &Poller{Store: d, Creds: creds, Client: fetch, Now: func() time.Time { return now }, Logger: log.New(io.Discard, "", 0)}, d
}

var validCreds = fakeCreds{c: Credentials{AccessToken: "tok-SECRET", ExpiresAt: at(23, 0), Plan: "max"}}

func TestPollOnce_OK(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	next, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	assert.Equal(t, pollInterval, next)
	st, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "ok", st.State)
	assert.Equal(t, "max", st.Plan)
	var limits []Limit
	require.NoError(t, json.Unmarshal([]byte(st.LimitsJSON), &limits))
	require.Len(t, limits, 3)
	assert.Equal(t, "collecting", limits[1].Projection.State)
	assert.Equal(t, "hit", limits[2].Projection.State)
	samples, err := d.PlanUsageSamplesSince("weekly_all", at(9, 0))
	require.NoError(t, err)
	assert.Len(t, samples, 1)
}

func TestPollOnce_BackoffKeepsLastNumbers(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	fetch.body, fetch.err = nil, &HTTPError{Status: 429}
	var delays []time.Duration
	for range 5 {
		next, err := p.PollOnce(context.Background())
		require.Error(t, err)
		delays = append(delays, next)
	}
	assert.Equal(t, []time.Duration{5 * time.Minute, 10 * time.Minute, 20 * time.Minute, 30 * time.Minute, 30 * time.Minute}, delays)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "error", st.State)
	assert.Equal(t, "http_429", st.Reason)
	assert.Contains(t, st.LimitsJSON, "weekly_all", "last good numbers kept")
	require.NotNil(t, st.FetchedAt)
}

func TestPollOnce_401IsStale(t *testing.T) {
	fetch := &fakeFetch{err: &HTTPError{Status: 401}}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	next, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.Equal(t, pollInterval, next)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "stale", st.State)
	assert.Equal(t, "token_expired", st.Reason)
}

// PLANUSAGE-01 guard: an expired token is never sent and never refreshed.
func TestPlanUsage01_ExpiredTokenMakesNoRequest(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	creds := fakeCreds{c: Credentials{AccessToken: "tok-SECRET", ExpiresAt: at(9, 0)}}
	p, d := newPoller(t, creds, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	assert.Zero(t, fetch.calls)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "stale", st.State)
	assert.Equal(t, "token_expired", st.Reason)
}

func TestPollOnce_NoCredentialsIsUnavailable(t *testing.T) {
	fetch := &fakeFetch{}
	p, d := newPoller(t, fakeCreds{err: ErrNoCredentials}, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	assert.Zero(t, fetch.calls)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "unavailable", st.State)
	assert.Equal(t, "no_credentials", st.Reason)
}

// PLANUSAGE-02 guard: the token never lands in the status row or an error.
func TestPlanUsage02_TokenNeverPersisted(t *testing.T) {
	fetch := &fakeFetch{err: fmt.Errorf("network: Bearer tok-SECRET refused")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "SECRET")
	st, _ := d.GetPlanUsageStatus()
	for _, s := range []string{st.LastError, st.Reason, st.LimitsJSON, st.BreakdownJSON, st.Plan} {
		assert.NotContains(t, s, "SECRET")
	}
}

func TestPollOnce_PrunesOldSamples(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	require.NoError(t, d.InsertPlanUsageSamples([]db.PlanUsageSample{{LimitKey: "session", TakenAt: at(10, 0).Add(-9 * 24 * time.Hour), Percent: 1}}))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	old, _ := d.PlanUsageSamplesSince("session", at(10, 0).Add(-10*24*time.Hour))
	assert.Len(t, old, 1, "only the new sample is left")
}

func TestMarkDisabled_KeepsNumbers(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	require.NoError(t, MarkDisabled(d, at(10, 5)))
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "disabled", st.State)
	assert.Contains(t, st.LimitsJSON, "weekly_all")
}

func TestClient_Fetch(t *testing.T) {
	var got *http.Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"limits":[]}`))
	}))
	defer srv.Close()
	c := NewClient("1.2.3")
	c.URL = srv.URL
	body, err := c.Fetch(context.Background(), "tok")
	require.NoError(t, err)
	assert.JSONEq(t, `{"limits":[]}`, string(body))
	assert.Equal(t, "oauth-2025-04-20", got.Header.Get("anthropic-beta"))
	assert.Equal(t, "watchtower/1.2.3", got.Header.Get("User-Agent"))
	assert.Equal(t, http.MethodGet, got.Method)
	_, err = c.Fetch(context.Background(), "bad")
	var he *HTTPError
	require.ErrorAs(t, err, &he)
	assert.Equal(t, 401, he.Status)
}

// A cancelled poll (daemon shutdown) writes nothing and counts no failure.
func TestPollOnce_CancelledWritesNothing(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	before, _ := d.GetPlanUsageStatus()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p.Creds = fakeCreds{err: ctx.Err()}
	_, err = p.PollOnce(ctx)
	require.ErrorIs(t, err, context.Canceled)
	p.Creds = validCreds
	fetch.body, fetch.err = nil, ctx.Err()
	_, err = p.PollOnce(ctx)
	require.ErrorIs(t, err, context.Canceled)

	after, _ := d.GetPlanUsageStatus()
	assert.Equal(t, before, after)
	assert.Zero(t, p.failures)
}

type failingStore struct {
	*db.DB
	err error
}

func (f failingStore) UpsertPlanUsageStatus(db.PlanUsageStatus) error { return f.err }

// A status-write failure in the no-credentials branch must not hide behind
// ErrNoCredentials, which Run does not log.
func TestPollOnce_NoCredentialsWriteFailureIsReported(t *testing.T) {
	p, d := newPoller(t, fakeCreds{err: ErrNoCredentials}, &fakeFetch{}, at(10, 0))
	p.Store = failingStore{DB: d, err: errors.New("disk full")}
	_, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrNoCredentials)
	assert.ErrorContains(t, err, "disk full")
}

func TestPollOnce_Reasons(t *testing.T) {
	cases := map[string]struct {
		fetch *fakeFetch
		want  string
	}{
		"5xx":     {&fakeFetch{err: &HTTPError{Status: 500}}, "http_500"},
		"network": {&fakeFetch{err: errors.New("dial tcp: refused")}, "network"},
		"garbage": {&fakeFetch{body: []byte("not json")}, "parse"},
		"nolimit": {&fakeFetch{body: []byte("{}")}, "parse"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			p, d := newPoller(t, validCreds, c.fetch, at(10, 0))
			_, err := p.PollOnce(context.Background())
			require.Error(t, err)
			st, _ := d.GetPlanUsageStatus()
			assert.Equal(t, "error", st.State)
			assert.Equal(t, c.want, st.Reason)
		})
	}
}
