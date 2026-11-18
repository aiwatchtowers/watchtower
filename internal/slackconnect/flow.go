package slackconnect

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/slackmanifest"
)

const slackAuthorizeURL = "https://slack.com/oauth/v2/authorize"

// exchangeTimeout bounds one code exchange; the real exchanger's HTTP client
// has its own timeout as well.
const exchangeTimeout = 30 * time.Second

var (
	// ErrFlowRunning: Begin was called while another flow is live.
	ErrFlowRunning = errors.New("a Slack connect flow is already running")
	// ErrNoFlow: no live, confirmed flow matches (none running, an unknown
	// id, or a callback for a flow not yet confirmed).
	ErrNoFlow = errors.New("no Slack connect flow is waiting")
	// ErrNotConfirmed: the flow came from a link and waits for the owner's
	// Connect; its authorize URL is not handed out before that.
	ErrNotConfirmed = errors.New("the Slack connect flow waits for confirmation")
	// ErrStateMismatch: a callback's state is not the live flow's. The flow
	// goes on waiting.
	ErrStateMismatch = errors.New("callback state does not match the Slack connect flow")
)

// FlowID names one flow in the events and commands between the listener
// child and the Desktop.
type FlowID string

// Clock is the registry's time source ("waiting since"); tests inject one.
type Clock interface{ Now() time.Time }

// SystemClock is the wall clock.
type SystemClock struct{}

// Now returns time.Now().
func (SystemClock) Now() time.Time { return time.Now() }

// Outcome is how a callback ended a flow. The values are the reason strings
// of the listener child's events.
type Outcome string

const (
	OutcomeConnected    Outcome = "connected"
	OutcomeDenied       Outcome = "denied"
	OutcomeTeamMismatch Outcome = "team_mismatch"
	OutcomeExchange     Outcome = "exchange"
	OutcomeCancelled    Outcome = "cancelled"
	OutcomeOther        Outcome = "other"
)

// Result is a finished flow. Grant is set only for OutcomeConnected; Message
// is a short, page-safe sentence for every other outcome.
type Result struct {
	Flow    FlowID
	Target  Target
	Outcome Outcome
	Grant   Grant
	Message string
}

// Registry holds the one connect flow in progress. A flow lives in memory
// only and has no deadline (plan B A22): it ends at its callback, at Cancel,
// or when the process exits.
type Registry struct {
	clock    Clock
	exchange Exchanger

	mu   sync.Mutex
	flow *flow
}

type flow struct {
	id        FlowID
	target    Target
	pkce      auth.PKCEPair
	state     string
	confirmed bool
	// waitingSince is when the browser step began: Begin for a flow that
	// skips the confirm, Confirm for a link flow.
	waitingSince time.Time
	// exchanging is set once a callback took the flow; it still holds the
	// slot (Begin is refused) but no other callback can finish it.
	exchanging bool
	cancelled  bool
}

// NewRegistry returns an empty registry exchanging codes with exchange.
func NewRegistry(clock Clock, exchange Exchanger) *Registry {
	return &Registry{clock: clock, exchange: exchange}
}

// Begin starts a flow for t. needsConfirm is true for a link the listener
// received (nothing reaches Slack before Confirm) and false for a paste, an
// MDM row, Reconnect or the setup's admin connect, whose authorize URL
// BrowserURL hands out at once. While another flow is live it returns that
// flow's id with ErrFlowRunning.
func (r *Registry) Begin(t Target, needsConfirm bool) (FlowID, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.flow != nil {
		return r.flow.id, ErrFlowRunning
	}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return "", err
	}
	state, err := auth.RandomState()
	if err != nil {
		return "", fmt.Errorf("generating state: %w", err)
	}
	id, err := newFlowID()
	if err != nil {
		return "", err
	}
	f := &flow{id: id, target: t, pkce: pkce, state: state, confirmed: !needsConfirm}
	if f.confirmed {
		f.waitingSince = r.clock.Now()
	}
	r.flow = f
	return id, nil
}

// Confirm is the owner's Connect on a link flow: it opens the flow to its
// callback and returns the authorize URL to open in the browser. Confirming
// a flow again (or one that skipped the confirm) returns the same URL.
func (r *Registry) Confirm(id FlowID) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := r.live(id)
	if f == nil {
		return "", ErrNoFlow
	}
	if !f.confirmed {
		f.confirmed = true
		f.waitingSince = r.clock.Now()
	}
	return AuthorizeURL(f.target, f.pkce, f.state), nil
}

// BrowserURL returns a confirmed flow's authorize URL; a link flow before
// Confirm gets ErrNotConfirmed.
func (r *Registry) BrowserURL(id FlowID) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := r.live(id)
	if f == nil {
		return "", ErrNoFlow
	}
	if !f.confirmed {
		return "", ErrNotConfirmed
	}
	return AuthorizeURL(f.target, f.pkce, f.state), nil
}

// WaitingSince reports when a live flow's browser step began, for the
// "Waiting for Slack since …" line. ok is false for no live flow with id and
// for a link flow not yet confirmed.
func (r *Registry) WaitingSince(id FlowID) (since time.Time, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := r.live(id)
	if f == nil || !f.confirmed {
		return time.Time{}, false
	}
	return f.waitingSince, true
}

// Cancel ends the flow id, also while its code is being exchanged (the
// exchange's grant is then dropped). It reports whether a live flow ended.
func (r *Registry) Cancel(id FlowID) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.flow == nil || r.flow.id != id {
		return false
	}
	r.flow.cancelled = true
	r.flow = nil
	return true
}

// Callback finishes the live flow with Slack's redirect. A callback with no
// confirmed flow waiting is ErrNoFlow and one whose state is not the flow's is
// ErrStateMismatch; neither ends anything. Otherwise the flow ends and the
// Result says how: a Slack error (access_denied → denied), a failed exchange,
// a grant for another team than the target's (team_mismatch, no grant handed
// out), Cancel during the exchange, or connected with the grant.
func (r *Registry) Callback(state, code, slackErr string) (Result, error) {
	f, err := r.take(state)
	if err != nil {
		return Result{}, err
	}
	res := Result{Flow: f.id, Target: f.target}
	if slackErr != "" || code == "" {
		r.finish(f)
		o, detail := slackErrorOutcome(slackErr)
		return withOutcome(res, o, detail), nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), exchangeTimeout)
	defer cancel()
	g, exErr := r.exchange(ctx, f.target.ClientID, code, f.pkce.Verifier, RedirectURL)

	if !r.finish(f) {
		return withOutcome(res, OutcomeCancelled, ""), nil
	}
	switch {
	case exErr != nil:
		return withOutcome(res, OutcomeExchange, exErr.Error()), nil
	case g.TeamID != f.target.TeamID:
		return withOutcome(res, OutcomeTeamMismatch, ""), nil
	}
	res.Outcome, res.Grant = OutcomeConnected, g
	return res, nil
}

// take claims the live, confirmed flow for a callback with state.
func (r *Registry) take(state string) (*flow, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := r.flow
	if f == nil || !f.confirmed || f.exchanging {
		return nil, ErrNoFlow
	}
	if !auth.StateMatches(state, f.state) {
		return nil, ErrStateMismatch
	}
	f.exchanging = true
	return f, nil
}

// finish frees the slot f holds and reports false when Cancel got there first.
func (r *Registry) finish(f *flow) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if f.cancelled {
		return false
	}
	if r.flow == f {
		r.flow = nil
	}
	return true
}

// live returns the flow id when it is the live one and not yet taken by a callback.
func (r *Registry) live(id FlowID) *flow {
	if r.flow == nil || r.flow.id != id || r.flow.exchanging {
		return nil
	}
	return r.flow
}

func slackErrorOutcome(slackErr string) (Outcome, string) {
	switch slackErr {
	case "access_denied":
		return OutcomeDenied, ""
	case "":
		return OutcomeOther, "Slack sent no authorization code."
	default:
		return OutcomeOther, "Slack reported: " + slackErr
	}
}

func withOutcome(res Result, o Outcome, detail string) Result {
	res.Outcome = o
	res.Message = outcomeMessage(o, detail)
	return res
}

func outcomeMessage(o Outcome, detail string) string {
	switch o {
	case OutcomeDenied:
		return "Slack access was not granted. Nothing was connected."
	case OutcomeTeamMismatch:
		return "You signed in to a different Slack workspace than the one this connection is for. Nothing was connected."
	case OutcomeExchange:
		return "Slack did not finish the sign-in (" + detail + "). Try again from Watchtower."
	case OutcomeCancelled:
		return "This connection was cancelled in Watchtower."
	case OutcomeConnected:
		return ""
	case OutcomeOther:
		return detail
	}
	return detail
}

// AuthorizeURL is Slack's authorize URL for one flow: the manifest's user
// scopes, the loopback redirect, the PKCE S256 challenge, the app's client
// id, the flow's state and team=<team id> (Slack's workspace hint). It never
// carries the verifier or a secret.
func AuthorizeURL(t Target, pkce auth.PKCEPair, state string) string {
	q := url.Values{
		"client_id":             {t.ClientID},
		"user_scope":            {strings.Join(slackmanifest.UserScopes(), ",")},
		"redirect_uri":          {RedirectURL},
		"state":                 {state},
		"code_challenge":        {pkce.Challenge},
		"code_challenge_method": {"S256"},
		"team":                  {t.TeamID},
	}
	return slackAuthorizeURL + "?" + q.Encode()
}

func newFlowID() (FlowID, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating flow id: %w", err)
	}
	return FlowID(hex.EncodeToString(b)), nil
}
