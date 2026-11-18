package slackconnect

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/auth"
)

// fakeClock is a fixed clock whose timers never fire.
type fakeClock struct{ now time.Time }

func (c *fakeClock) Now() time.Time { return c.now }

func (c *fakeClock) After(time.Duration) <-chan time.Time { return make(chan time.Time) }

// fakeExchange records its calls and answers with a grant for team.
type fakeExchange struct {
	mu    sync.Mutex
	calls []exchangeCall
	team  string
	err   error
}

type exchangeCall struct{ clientID, code, verifier, redirectURI string }

func (f *fakeExchange) exchange(_ context.Context, clientID, code, verifier, redirectURI string) (Grant, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, exchangeCall{clientID, code, verifier, redirectURI})
	if f.err != nil {
		return Grant{}, f.err
	}
	return Grant{
		AccessToken: "xoxp-test", RefreshToken: "xoxe-test", ExpiresIn: 43200,
		ClientID: clientID, AppID: "A0ACME01", TeamID: f.team, TeamName: "Acme", UserID: "U0ACME01",
	}, nil
}

func (f *fakeExchange) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

var testTarget = Target{TeamID: "T0ACME01", ClientID: "1111.2222"}

func newTestRegistry(t *testing.T) (*Registry, *fakeClock, *fakeExchange) {
	t.Helper()
	clk := &fakeClock{now: time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)}
	ex := &fakeExchange{team: testTarget.TeamID}
	return NewRegistry(clk, ex.exchange), clk, ex
}

// stateOf reads the state a flow's authorize URL carries.
func stateOf(t *testing.T, authorizeURL string) string {
	t.Helper()
	u, err := url.Parse(authorizeURL)
	if err != nil {
		t.Fatalf("parse authorize URL: %v", err)
	}
	s := u.Query().Get("state")
	if s == "" {
		t.Fatalf("authorize URL has no state: %s", authorizeURL)
	}
	return s
}

func TestAuthorizeURL_CarriesPKCEAndTeam(t *testing.T) {
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		t.Fatal(err)
	}
	raw := AuthorizeURL(testTarget, pkce, "state-1")
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "https" || u.Host != "slack.com" || u.Path != "/oauth/v2/authorize" {
		t.Fatalf("authorize URL base = %s", raw)
	}
	q := u.Query()
	want := map[string]string{
		"client_id":             testTarget.ClientID,
		"redirect_uri":          RedirectURL,
		"state":                 "state-1",
		"code_challenge":        pkce.Challenge,
		"code_challenge_method": "S256",
		"team":                  testTarget.TeamID,
	}
	for k, v := range want {
		if got := q.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	if q.Get("user_scope") == "" || strings.Contains(q.Get("user_scope"), " ") {
		t.Errorf("user_scope = %q, want a comma-separated list", q.Get("user_scope"))
	}
	if q.Has("scope") || q.Has("client_secret") || strings.Contains(raw, pkce.Verifier) {
		t.Errorf("authorize URL carries a bot scope, a secret or the verifier: %s", raw)
	}
}

func TestRegistry_OneFlowAtATime(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	first, err := reg.Begin(testTarget, true)
	if err != nil {
		t.Fatal(err)
	}
	running, err := reg.Begin(Target{TeamID: "T0OTHER1", ClientID: "3333.4444"}, false)
	if !errors.Is(err, ErrFlowRunning) {
		t.Fatalf("second Begin err = %v, want ErrFlowRunning", err)
	}
	if running != first {
		t.Fatalf("second Begin returned %q, want the running flow %q", running, first)
	}
	reg.Cancel(first)
	if _, err := reg.Begin(testTarget, false); err != nil {
		t.Fatalf("Begin after Cancel: %v", err)
	}
}

func TestRegistry_ConfirmRequiredForLink(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	id, err := reg.Begin(testTarget, true)
	if err != nil {
		t.Fatal(err)
	}
	if u, err := reg.BrowserURL(id); !errors.Is(err, ErrNotConfirmed) || u != "" {
		t.Fatalf("BrowserURL before Confirm = %q, %v; want ErrNotConfirmed", u, err)
	}
	// A callback cannot finish an unconfirmed flow, whatever it carries.
	if _, err := reg.Callback("guess", "code", ""); !errors.Is(err, ErrNoFlow) {
		t.Fatalf("Callback before Confirm err = %v, want ErrNoFlow", err)
	}
	if ex.count() != 0 {
		t.Fatalf("exchange called %d times before Confirm", ex.count())
	}
	authURL, err := reg.Confirm(id)
	if err != nil {
		t.Fatalf("Confirm: %v", err)
	}
	if again, err := reg.BrowserURL(id); err != nil || again != authURL {
		t.Fatalf("BrowserURL after Confirm = %q, %v; want %q", again, err, authURL)
	}
	if _, err := reg.Confirm("no-such-flow"); !errors.Is(err, ErrNoFlow) {
		t.Fatalf("Confirm of an unknown flow err = %v, want ErrNoFlow", err)
	}
}

func TestRegistry_PasteSkipsConfirm(t *testing.T) {
	reg, clk, ex := newTestRegistry(t)
	start := clk.Now()
	id, err := reg.Begin(Target{TeamID: testTarget.TeamID, ClientID: testTarget.ClientID, AccountID: 7}, false)
	if err != nil {
		t.Fatal(err)
	}
	authURL, err := reg.BrowserURL(id)
	if err != nil {
		t.Fatalf("BrowserURL of a paste flow: %v", err)
	}
	if since, ok := reg.WaitingSince(id); !ok || !since.Equal(start) {
		t.Fatalf("WaitingSince = %v, %v; want %v", since, ok, start)
	}
	res, err := reg.Callback(stateOf(t, authURL), "code-1", "")
	if err != nil {
		t.Fatalf("Callback: %v", err)
	}
	if res.Outcome != OutcomeConnected || res.Flow != id || res.Target.AccountID != 7 || res.Grant.AccessToken == "" {
		t.Fatalf("Callback result = %+v", res)
	}
	if ex.count() != 1 {
		t.Fatalf("exchange calls = %d, want 1", ex.count())
	}
	call := ex.calls[0]
	if call.clientID != testTarget.ClientID || call.code != "code-1" || call.redirectURI != RedirectURL || call.verifier == "" {
		t.Fatalf("exchange call = %+v", call)
	}
	if _, ok := reg.WaitingSince(id); ok {
		t.Fatal("flow still live after its callback")
	}
}

func TestRegistry_FlowWaitsUntilCancel(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ex := &fakeExchange{team: testTarget.TeamID}
		reg := NewRegistry(SystemClock{}, ex.exchange)
		id, err := reg.Begin(testTarget, true)
		if err != nil {
			t.Fatal(err)
		}
		time.Sleep(3 * time.Minute) // bubble time: the owner reads the confirm sheet
		confirmedAt := time.Now()
		authURL, err := reg.Confirm(id)
		if err != nil {
			t.Fatal(err)
		}
		time.Sleep(24 * time.Hour) // bubble time: no deadline (A22)

		since, ok := reg.WaitingSince(id)
		if !ok {
			t.Fatal("flow ended on its own after 24 h")
		}
		if !since.Equal(confirmedAt) {
			t.Fatalf("WaitingSince = %v, want the confirm time %v", since, confirmedAt)
		}
		if _, err := reg.Begin(testTarget, false); !errors.Is(err, ErrFlowRunning) {
			t.Fatalf("Begin while waiting err = %v, want ErrFlowRunning", err)
		}
		if !reg.Cancel(id) {
			t.Fatal("Cancel of the live flow returned false")
		}
		if reg.Cancel(id) {
			t.Fatal("second Cancel returned true")
		}
		if _, err := reg.Callback(stateOf(t, authURL), "code", ""); !errors.Is(err, ErrNoFlow) {
			t.Fatalf("Callback after Cancel err = %v, want ErrNoFlow", err)
		}
		if ex.count() != 0 {
			t.Fatalf("exchange called %d times for a cancelled flow", ex.count())
		}
		if _, err := reg.Begin(testTarget, false); err != nil {
			t.Fatalf("Begin after Cancel: %v", err)
		}
	})
}

func TestRegistry_CallbackStateMismatchIgnored(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)

	for _, bad := range []string{"", "wrong-state", stateOf(t, authURL) + "x"} {
		if _, err := reg.Callback(bad, "code", ""); !errors.Is(err, ErrStateMismatch) {
			t.Fatalf("Callback(state=%q) err = %v, want ErrStateMismatch", bad, err)
		}
	}
	// A stray error callback with the wrong state does not end the flow either.
	if _, err := reg.Callback("wrong-state", "", "access_denied"); !errors.Is(err, ErrStateMismatch) {
		t.Fatalf("error callback with wrong state err = %v", err)
	}
	if _, ok := reg.WaitingSince(id); !ok {
		t.Fatal("a wrong-state callback ended the flow")
	}
	if ex.count() != 0 {
		t.Fatalf("exchange called %d times on wrong state", ex.count())
	}
	res, err := reg.Callback(stateOf(t, authURL), "code", "")
	if err != nil || res.Outcome != OutcomeConnected {
		t.Fatalf("right-state callback = %+v, %v", res, err)
	}
}

func TestRegistry_DeniedCallback(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	res, err := reg.Callback(stateOf(t, authURL), "", "access_denied")
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeDenied || res.Grant != (Grant{}) {
		t.Fatalf("denied result = %+v", res)
	}
	if ex.count() != 0 {
		t.Fatal("exchange called for a denied callback")
	}
	if _, ok := reg.WaitingSince(id); ok {
		t.Fatal("flow still live after a denied callback")
	}

	// Any other Slack error ends the flow as "other", carrying the code.
	id, _ = reg.Begin(testTarget, false)
	authURL, _ = reg.BrowserURL(id)
	res, err = reg.Callback(stateOf(t, authURL), "", "invalid_team_for_non_distributed_app")
	if err != nil || res.Outcome != OutcomeOther || !strings.Contains(res.Message, "invalid_team_for_non_distributed_app") {
		t.Fatalf("other error result = %+v, %v", res, err)
	}
}

func TestRegistry_TeamMismatch(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	ex.team = "T0OTHER1"
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	res, err := reg.Callback(stateOf(t, authURL), "code", "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeTeamMismatch {
		t.Fatalf("outcome = %q, want team_mismatch", res.Outcome)
	}
	if res.Grant != (Grant{}) {
		t.Fatalf("a mismatched grant was handed out: %+v", res.Grant)
	}
	if _, ok := reg.WaitingSince(id); ok {
		t.Fatal("flow still live after a team mismatch")
	}
}

func TestRegistry_ExchangeFailure(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	ex.err = errors.New("slack oauth.v2.access: invalid_code")
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	res, err := reg.Callback(stateOf(t, authURL), "code", "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeExchange || !strings.Contains(res.Message, "invalid_code") || res.Grant != (Grant{}) {
		t.Fatalf("exchange failure result = %+v", res)
	}
}

func TestRegistry_CancelDuringExchange(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	entered := make(chan struct{})
	exchangeErr := make(chan error, 1)
	reg.exchange = func(ctx context.Context, _, _, _, _ string) (Grant, error) {
		close(entered)
		<-ctx.Done() // Cancel aborts the request
		exchangeErr <- ctx.Err()
		// A token Slack issued anyway must still be dropped.
		return Grant{AccessToken: "xoxp-test", TeamID: testTarget.TeamID}, nil
	}
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	done := make(chan Result, 1)
	go func() {
		res, _ := reg.Callback(stateOf(t, authURL), "code", "")
		done <- res
	}()
	<-entered
	// While the exchange runs the flow still holds the slot, and a replayed
	// callback finds nothing to finish.
	if _, err := reg.Begin(testTarget, false); !errors.Is(err, ErrFlowRunning) {
		t.Fatalf("Begin during exchange err = %v", err)
	}
	if _, err := reg.Callback(stateOf(t, authURL), "code", ""); !errors.Is(err, ErrNoFlow) {
		t.Fatalf("replayed callback err = %v, want ErrNoFlow", err)
	}
	if _, ok := reg.WaitingSince(id); ok {
		t.Fatal("a flow being exchanged still reports waiting")
	}
	if !reg.Cancel(id) {
		t.Fatal("Cancel during exchange returned false")
	}
	if err := <-exchangeErr; !errors.Is(err, context.Canceled) {
		t.Fatalf("exchange ctx err = %v, want context.Canceled", err)
	}
	res := <-done
	if res.Outcome != OutcomeCancelled || res.Grant != (Grant{}) {
		t.Fatalf("result after Cancel during exchange = %+v", res)
	}
}
