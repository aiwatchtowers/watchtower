// Package providerrouting bounds quota-only routing. It never replays a tool
// turn, edits preferences, records usage rows, or waits for quota to reset.
package providerrouting

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

type Mode string

const (
	PreferredReserve Mode = "preferred_reserve"
	Pinned           Mode = "pinned"
)

type RetryClass string

const (
	Isolated    RetryClass = "isolated"
	BeforeChild RetryClass = "before_child"
	Never       RetryClass = "never"
)

// Request describes an operation, not a physical CLI session. Deadline is a
// total deadline and can only shorten the context's existing deadline.
type Request struct {
	Preferred, Reserve    string
	Mode                  Mode
	Tier                  digest.Tier
	Profile               providers.InvocationProfile
	Retry                 RetryClass
	OperationID, Revision string
	Deadline              time.Time
	Model                 func(provider string, tier digest.Tier) string
	Identity              func(provider string) string // Reliable account metadata only; empty = installation.
	Capable               func(provider string, profile providers.InvocationProfile) bool
	// CheckCapability distinguishes unsupported capabilities from operational failures.
	CheckCapability func(provider string, profile providers.InvocationProfile) (bool, error)
	InputBytes      int // Actual serialized input submitted by an isolated text leaf.
	Hook            AttemptHook
}
type Attempt struct {
	OperationID               string
	Number                    int
	InputBytes                int
	Provider, Model, Revision string
}
type Result struct {
	Text      string
	Usage     *digest.Usage
	SessionID string
}

// Outcome contains the leaf's own ledger facts, including estimated usage.
// An absent Call means usage is unknown, never free. Text is available for
// the SDK's existing partial-output estimate; no text is persisted by routing.
type Outcome struct {
	Result Result
	Err    error
	Calls  []llmusage.Call
}

// AttemptHook admits each physical attempt, then debits it before any reserve
// admission. After must account for failed/unknown usage too; its error stops
// routing. The hook is not a second usage writer.
type AttemptHook interface {
	Before(context.Context, Attempt) error
	After(context.Context, Attempt, Outcome) error
}
type Router struct {
	Health     *providerhealth.Store
	Allowed    func(string) error
	Diagnostic func(error)
	Now        func() time.Time
}

var ErrDeferred = errors.New("AI provider quota deferred")

type Deferred struct {
	Provider    string
	NextProbeAt time.Time
	Attempts    int
	Cause       error
}

// ProviderDeferred identifies this router-owned wait without importing the router in pipelines.
func (d *Deferred) ProviderDeferred() bool { return true }

func (d *Deferred) Error() string { return fmt.Sprintf("%s: %s", d.Provider, ErrDeferred) }
func (d *Deferred) Unwrap() []error {
	if d.Cause == nil {
		return []error{ErrDeferred, digest.ErrAICall}
	}
	return []error{ErrDeferred, digest.ErrAICall, d.Cause}
}

func operationID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}
func (r *Router) allowed(provider string) error {
	if !configProvider(provider) {
		return fmt.Errorf("unknown AI provider %q", provider)
	}
	if r.Allowed != nil {
		return r.Allowed(provider)
	}
	return providers.Allowed(provider)
}
func configProvider(p string) bool { return p == "claude" || p == "codex" || p == "ollama" }
func (r *Router) diagnostic(err error) {
	if err != nil && r.Diagnostic != nil {
		r.Diagnostic(err)
	}
}
func account(req Request, p string) providerhealth.Scope {
	id := ""
	if req.Identity != nil {
		id = req.Identity(p)
	}
	return providerhealth.AccountScope(p, id)
}
func scopes(req Request, p string) []providerhealth.Scope {
	a := account(req, p)
	out := []providerhealth.Scope{a}
	if req.Model != nil {
		if m := req.Model(p, req.Tier); m != "" {
			out = append(out, providerhealth.ModelScope(a, m))
		}
	}
	return out
}

type heldLease struct {
	scope providerhealth.Scope
	lease providerhealth.Lease
}

func (r *Router) release(leases []heldLease) {
	if r.Health == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	for _, l := range leases {
		r.diagnostic(r.Health.Release(ctx, l.lease))
	}
}

// gate combines exact account and selected model scopes. No worker is acquired
// here. A recovery probe needs an actual safe request and its real deadline.
func (r *Router) gate(ctx context.Context, req Request, p string, probe bool) ([]heldLease, error) {
	if r.Health == nil {
		return nil, nil
	}
	deadline, hasDeadline := ctx.Deadline()
	var due []providerhealth.Scope
	for _, scope := range scopes(req, p) {
		state, err := r.Health.Read(ctx, scope)
		if err != nil {
			r.diagnostic(err)
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, nil
		}
		if state.State == providerhealth.Available {
			continue
		}
		now := time.Now()
		if r.Now != nil {
			now = r.Now()
		}
		if !probe || !hasDeadline || state.State == providerhealth.ProbeLeased || now.Before(state.NextProbeAt) {
			return nil, &Deferred{Provider: p, NextProbeAt: state.NextProbeAt}
		}
		due = append(due, scope)
	}
	// Inspect every exact gate before claiming any: a blocked model must not
	// consume or postpone an otherwise due account probe without a model call.
	var leases []heldLease
	for _, scope := range due {
		lease, ok, err := r.Health.Claim(ctx, scope, providerhealth.ProbeRequest{PendingSafe: true, Deadline: deadline})
		if err != nil {
			r.diagnostic(err)
			r.release(leases)
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, nil
		}
		if ok {
			leases = append(leases, heldLease{scope, lease})
			continue
		}
		state, err := r.Health.Read(ctx, scope)
		if err == nil && state.State == providerhealth.Available {
			continue
		}
		r.release(leases)
		if err != nil {
			r.diagnostic(err)
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, nil
		}
		return nil, &Deferred{Provider: p, NextProbeAt: state.NextProbeAt}
	}
	return leases, nil
}
func (r *Router) finish(ctx context.Context, req Request, a Attempt, leases []heldLease, err error) {
	if r.Health == nil {
		return
	}
	if ctx.Err() != nil {
		r.release(leases)
		return
	}
	// A completed account-wide probe clears only its own scope. Model-specific
	// failure is separately recorded below, never promoted to account quota.
	var f *providers.Failure
	quota := errors.As(err, &f) && f.Category == providers.Quota && f.Provider == a.Provider
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
	defer cancel()
	quotaScope := account(req, a.Provider)
	if quota && modelQuota(f, a.Model) {
		quotaScope = providerhealth.ModelScope(quotaScope, a.Model)
	}
	recorded := false
	for _, l := range leases {
		if quota && l.scope != quotaScope {
			r.diagnostic(r.Health.Release(cleanup, l.lease))
			continue
		}
		r.diagnostic(r.Health.Complete(cleanup, l.lease, err))
		if quota {
			recorded = true
		}
	}
	if quota && !recorded {
		r.diagnostic(r.Health.RecordQuota(cleanup, quotaScope, f))
	}
}

// Window metadata is narrower only when the selected model proves the same
// family. Never use five_hour/seven_day as a circuit model bucket.
func modelQuota(f *providers.Failure, model string) bool {
	if f.Scope == "model" && f.Bucket != "" && f.Bucket == model {
		return true
	}
	// Only Claude reports per-family weekly windows (seven_day_opus, …).
	for _, family := range []string{"opus", "sonnet"} {
		if f.Window == "seven_day_"+family && (model == family || strings.HasPrefix(model, "claude-"+family+"-")) {
			return true
		}
	}
	return false
}

func (r *Router) capability(req Request, p string) error {
	if req.CheckCapability != nil {
		supported, err := req.CheckCapability(p, req.Profile)
		if err != nil {
			return fmt.Errorf("checking %s capabilities: %w", p, err)
		}
		if !supported {
			return providers.CapabilityError(p, req.Profile, errors.New("provider does not support the required invocation profile"))
		}
	}

	if req.Capable != nil && !req.Capable(p, req.Profile) {
		return providers.CapabilityError(p, req.Profile, errors.New("provider does not support the required invocation profile"))
	}
	return nil
}

// validPair reports whether the request's providers are each other's
// reserve peers (the capability table).
func validPair(req Request) bool { return providers.Pairs(req.Preferred, req.Reserve) }

// Select chooses before a tool child starts. It does not claim recovery probes,
// invoke a model, or enable replay. Callers must check policy again at dispatch.
func (r *Router) Select(ctx context.Context, req Request) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := r.allowed(req.Preferred); err != nil {
		return "", err
	}
	if req.Mode != PreferredReserve {
		if err := r.capability(req, req.Preferred); err != nil {
			return "", err
		}
		return req.Preferred, nil
	}
	if !validPair(req) {
		return "", errors.New("fallback requires a Claude/Codex pair")
	}
	// A known-blocked candidate will not run this turn. Check its health before
	// requiring turn capabilities, then validate the available selected candidate.
	// Policy always precedes both health I/O and capability checks.
	_, err := r.gate(ctx, req, req.Preferred, false)
	if err == nil {
		if err := r.capability(req, req.Preferred); err != nil {
			return "", err
		}
		return req.Preferred, nil
	}
	if !errors.Is(err, ErrDeferred) {
		return "", err
	}
	if err := r.allowed(req.Reserve); err != nil {
		return "", err
	}
	if _, err := r.gate(ctx, req, req.Reserve, false); err != nil {
		return "", err
	}
	if err := r.capability(req, req.Reserve); err != nil {
		return "", err
	}
	return req.Reserve, nil
}

// Run calls at most preferred + reserve. Only isolated no-tools profiles can
// retry, and only confirmed quota (or a shared known quota gate) permits it.
func (r *Router) Run(ctx context.Context, req Request, call func(context.Context, Attempt) (Result, error)) (Result, error) {
	if !req.Deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, req.Deadline)
		defer cancel()
	}
	if req.Mode == PreferredReserve && !validPair(req) {
		return Result{}, errors.New("fallback requires a Claude/Codex pair")
	}
	if req.OperationID == "" {
		req.OperationID = operationID()
	}
	safe := req.Mode == PreferredReserve && req.Retry == Isolated && req.Profile.ReplaySafe() // the pair was checked above
	candidates := []string{req.Preferred}
	if safe {
		candidates = append(candidates, req.Reserve)
	}
	var last error
	number := 0
	for _, p := range candidates {
		if err := ctx.Err(); err != nil {
			return Result{}, err
		}
		if err := r.allowed(p); err != nil {
			return Result{}, err
		}
		if err := r.capability(req, p); err != nil {
			return Result{}, err
		}
		var leases []heldLease
		if safe {
			var err error
			leases, err = r.gate(ctx, req, p, true)
			if err != nil {
				if errors.Is(err, ErrDeferred) {
					var deferred *Deferred
					errors.As(err, &deferred)
					last = &Deferred{Provider: p, NextProbeAt: deferred.NextProbeAt, Attempts: number, Cause: err}
					continue
				}
				return Result{}, err
			}
		}
		number++
		a := Attempt{OperationID: req.OperationID, Number: number, Provider: p, Revision: req.Revision, InputBytes: req.InputBytes}
		if req.Model != nil {
			a.Model = req.Model(p, req.Tier)
		}
		if req.Hook != nil {
			if err := req.Hook.Before(ctx, a); err != nil {
				r.release(leases)
				return Result{}, err
			}
		}
		if err := ctx.Err(); err != nil {
			r.release(leases)
			return Result{}, err
		}
		var calls []llmusage.Call
		var callMu sync.Mutex
		attemptCtx := llmusage.WithAttempt(ctx, llmusage.Attempt{OperationID: a.OperationID, Number: a.Number, Revision: a.Revision}, func(c llmusage.Call) { callMu.Lock(); defer callMu.Unlock(); calls = append(calls, c) })
		result, err := call(attemptCtx, a)
		callMu.Lock()
		observed := append([]llmusage.Call(nil), calls...)
		callMu.Unlock()
		r.finish(ctx, req, a, leases, err)
		if req.Hook != nil {
			if hookErr := req.Hook.After(ctx, a, Outcome{Result: result, Err: err, Calls: observed}); hookErr != nil {
				return result, hookErr
			}
		}
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		if err == nil {
			return result, nil
		}
		var failure *providers.Failure
		if !safe || !errors.As(err, &failure) || failure.Category != providers.Quota || failure.Provider != p {
			return result, err
		}
		last = &Deferred{Provider: p, Attempts: number, Cause: err}
	}
	return Result{}, last
}

// Check reports known quota waits before a scheduler claims a data-attempt
// marker. It never acquires a recovery lease or invokes a model. A due safe
// probe is allowed to proceed to Run, which arbitrates its lease atomically.
func (r *Router) Check(ctx context.Context, req Request) error {
	if req.Mode != PreferredReserve {
		return r.allowed(req.Preferred)
	}
	if !validPair(req) {
		return errors.New("fallback requires a Claude/Codex pair")
	}
	candidates := []string{req.Preferred}
	if req.Retry == Isolated && req.Profile.ReplaySafe() && req.Reserve != "" {
		candidates = append(candidates, req.Reserve)
	}
	var last error
	for _, p := range candidates {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := r.allowed(p); err != nil {
			return err
		}
		if err := r.capability(req, p); err != nil {
			return err
		}
		if r.Health == nil {
			return nil
		}
		blocked := false
		for _, scope := range scopes(req, p) {
			state, err := r.Health.Read(ctx, scope)
			if err != nil {
				r.diagnostic(err)
				if ctx.Err() != nil {
					return ctx.Err()
				}
				return nil
			}
			now := time.Now()
			if r.Now != nil {
				now = r.Now()
			}
			if state.State == providerhealth.ProbeLeased || (state.State == providerhealth.QuotaWait && now.Before(state.NextProbeAt)) {
				blocked = true
				last = &Deferred{Provider: p, NextProbeAt: state.NextProbeAt}
				break
			}
		}
		if !blocked {
			return nil
		}
	}
	return last
}
