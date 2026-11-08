package providerrouting

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

func TestQuotaOnlyBoundedBothDirections(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			reserve := "codex"
			if preferred == reserve {
				reserve = "claude"
			}
			for _, category := range []providers.ErrorCategory{providers.Quota, providers.Auth, providers.RateLimit, providers.Model, providers.Transport, providers.Policy, providers.InvalidOutput} {
				t.Run(string(category), func(t *testing.T) {
					calls := []string{}
					r := Router{Allowed: func(string) error { return nil }}
					result, err := r.Run(context.Background(), Request{Preferred: preferred, Reserve: reserve, Mode: PreferredReserve, Retry: Isolated, Profile: providers.BatchText}, func(ctx context.Context, a Attempt) (Result, error) {
						calls = append(calls, a.Provider)
						if a.Provider == preferred {
							return Result{}, providers.WithFailure(preferred, category, errors.New("failed"))
						}
						return Result{Text: "ok"}, nil
					})
					if category == providers.Quota {
						if err != nil || result.Text != "ok" || len(calls) != 2 || calls[1] != reserve {
							t.Fatalf("%v %v %v", result, err, calls)
						}
					} else if err == nil || len(calls) != 1 {
						t.Fatalf("%v %v", err, calls)
					}
				})
			}
		})
	}
}
func TestPolicyCancellationAndSharedDeadline(t *testing.T) {
	denied := errors.New("denied")
	calls := 0
	r := Router{Allowed: func(string) error { return denied }}
	_, err := r.Run(context.Background(), Request{Preferred: "claude", Reserve: "codex", Mode: PreferredReserve, Retry: Isolated, Profile: providers.BatchText}, func(context.Context, Attempt) (Result, error) { calls++; return Result{}, nil })
	if !errors.Is(err, denied) || calls != 0 {
		t.Fatal(err, calls)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var deadline time.Time
	r.Allowed = func(string) error { return nil }
	_, err = r.Run(ctx, Request{Preferred: "claude", Reserve: "codex", Mode: PreferredReserve, Retry: Isolated, Profile: providers.BatchText}, func(ctx context.Context, a Attempt) (Result, error) {
		d, _ := ctx.Deadline()
		if deadline.IsZero() {
			deadline = d
		} else if d != deadline {
			t.Fatal("restarted deadline")
		}
		calls++
		cancel()
		return Result{}, providers.WithFailure(a.Provider, providers.Quota, errors.New("quota"))
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal(err, calls)
	}
}

type hook struct {
	before func(context.Context, Attempt) error
	after  func(context.Context, Attempt, Outcome) error
}

func (h hook) Before(c context.Context, a Attempt) error {
	if h.before != nil {
		return h.before(c, a)
	}
	return nil
}
func (h hook) After(c context.Context, a Attempt, o Outcome) error {
	if h.after != nil {
		return h.after(c, a, o)
	}
	return nil
}
func request() Request {
	return Request{Preferred: "claude", Reserve: "codex", Mode: PreferredReserve, Retry: Isolated, Profile: providers.BatchText}
}
func quota(p string) error { return providers.WithFailure(p, providers.Quota, errors.New("quota")) }

func TestReservePolicyCapabilitiesPinsAndNoToolReplay(t *testing.T) {
	for _, variant := range []string{"reserve_forbidden", "preferred_capability", "reserve_image", "pinned", "never", "tool"} {
		t.Run(variant, func(t *testing.T) {
			req := request()
			r := Router{Allowed: func(string) error { return nil }}
			calls := 0
			switch variant {
			case "reserve_forbidden":
				r.Allowed = func(p string) error {
					if p == "codex" {
						return errors.New("policy")
					}
					return nil
				}
			case "preferred_capability":
				req.Capable = func(string, providers.InvocationProfile) bool { return false }
			case "reserve_image":
				req.Profile = providers.Image
				req.Capable = func(p string, _ providers.InvocationProfile) bool { return p == "claude" }
			case "pinned":
				req.Mode = Pinned
			case "never":
				req.Retry = Never
			case "tool":
				req.Profile = providers.ToolPreflight
				req.Retry = BeforeChild
			}
			_, err := r.Run(context.Background(), req, func(_ context.Context, a Attempt) (Result, error) { calls++; return Result{}, quota(a.Provider) })
			want := 1
			if variant == "preferred_capability" {
				want = 0
			}
			if err == nil || calls != want {
				t.Fatal(err, calls)
			}
		})
	}
}
func TestTwoQuotaAndHookCompletionBeforeReserveAdmission(t *testing.T) {
	req := request()
	req.OperationID = "operation"
	req.Revision = "revision"
	req.Model = func(p string, _ digest.Tier) string { return p + "-model" }
	events := []string{}
	calls := 0
	req.Hook = hook{before: func(_ context.Context, a Attempt) error {
		events = append(events, "before:"+a.Provider)
		if a.Number == 2 && calls != 1 {
			t.Fatal("failed attempt was free")
		}
		return nil
	}, after: func(_ context.Context, a Attempt, o Outcome) error {
		events = append(events, "after:"+a.Provider)
		if len(o.Calls) != 1 || o.Calls[0].OperationID != "operation" || o.Calls[0].Attempt != a.Number || o.Calls[0].Model != a.Model || !o.Calls[0].Estimated {
			t.Fatalf("leaf facts: %+v", o.Calls)
		}
		calls++
		return nil
	}}
	r := Router{Allowed: func(string) error { return nil }}
	_, err := r.Run(context.Background(), req, func(ctx context.Context, a Attempt) (Result, error) {
		llmusage.Record(ctx, llmusage.Call{Provider: a.Provider, Model: a.Model, Tokens: llmusage.Tokens{Input: 13, Estimated: true}})
		return Result{}, quota(a.Provider)
	})
	var deferred *Deferred
	if !errors.As(err, &deferred) || deferred.Attempts != 2 || !errors.Is(err, digest.ErrAICall) || calls != 2 {
		t.Fatal(err, calls)
	}
	if strings.Join(events, ",") != "before:claude,after:claude,before:codex,after:codex" {
		t.Fatal(events)
	}
	req.Hook = hook{after: func(context.Context, Attempt, Outcome) error { return errors.New("unknown budget remainder") }}
	calls = 0
	_, err = r.Run(context.Background(), req, func(context.Context, Attempt) (Result, error) { calls++; return Result{}, quota("claude") })
	if err == nil || calls != 1 {
		t.Fatal(err, calls)
	}
}
func TestRealTotalDeadlineAndQueueTime(t *testing.T) {
	req := request()
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	var first time.Time
	calls := 0
	r := Router{Allowed: func(string) error { return nil }}
	_, err := r.Run(ctx, req, func(ctx context.Context, a Attempt) (Result, error) {
		calls++
		deadline, _ := ctx.Deadline()
		if first.IsZero() {
			first = deadline
		} else if !first.Equal(deadline) {
			t.Fatal("reserve deadline restarted")
		}
		if calls == 1 {
			timer := time.NewTimer(40 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-ctx.Done():
				return Result{}, ctx.Err()
			case <-timer.C:
			}
			return Result{}, quota(a.Provider)
		}
		<-ctx.Done()
		return Result{}, ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) || calls != 2 {
		t.Fatal(err, calls)
	}
}
func TestSharedHealthScopesRecoveryAndCancellation(t *testing.T) {
	now := time.Now()
	store := providerhealth.New(t.TempDir(), func() time.Time { return now })
	r := Router{Health: store, Now: func() time.Time { return now }, Allowed: func(string) error { return nil }}
	req := request()
	req.Model = func(string, digest.Tier) string { return "opus" }
	account := providerhealth.AccountScope("claude", "")
	if err := store.RecordQuota(context.Background(), account, &providers.Failure{Provider: "claude", Category: providers.Quota}); err != nil {
		t.Fatal(err)
	}
	calls := 0
	run := func(ctx context.Context) (Result, error) {
		return r.Run(ctx, req, func(_ context.Context, a Attempt) (Result, error) {
			calls++
			if a.Provider != "codex" {
				t.Fatal("cooldown not respected")
			}
			return Result{Text: "ok"}, nil
		})
	}
	if _, err := run(context.Background()); err != nil || calls != 1 {
		t.Fatal(err, calls)
	}
	// The due circuit may be probed by exactly one real bounded safe request.
	now = now.Add(6 * time.Minute)
	ctx, cancel := context.WithDeadline(context.Background(), now.Add(time.Minute))
	defer cancel()
	_, err := r.Run(ctx, req, func(_ context.Context, a Attempt) (Result, error) {
		if a.Provider != "claude" {
			t.Fatal(a)
		}
		state, e := store.Read(context.Background(), account)
		if e != nil || state.State != providerhealth.ProbeLeased {
			t.Fatal(state, e)
		}
		return Result{Text: "recovered"}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	state, err := store.Read(context.Background(), account)
	if err != nil || state.State != providerhealth.Available {
		t.Fatal(state, err)
	}
	// Model-only limits do not block a different model or another account.
	model := providerhealth.ModelScope(account, "opus")
	if err := store.RecordQuota(context.Background(), model, &providers.Failure{Provider: "claude", Category: providers.Quota}); err != nil {
		t.Fatal(err)
	}
	req.Model = func(string, digest.Tier) string { return "sonnet" }
	selected, err := r.Select(context.Background(), req)
	if err != nil || selected != "claude" {
		t.Fatal(selected, err)
	}
	req.Model = func(string, digest.Tier) string { return "opus" }
	selected, err = r.Select(context.Background(), req)
	if err != nil || selected != "codex" {
		t.Fatal(selected, err)
	}
	req.Identity = func(string) string { return "different-account" }
	selected, err = r.Select(context.Background(), req)
	if err != nil || selected != "claude" {
		t.Fatal(selected, err)
	}
}
func TestKnownBothQuotaZeroAttemptsAndDegradedSuccess(t *testing.T) {
	store := providerhealth.New(t.TempDir(), nil)
	r := Router{Health: store, Allowed: func(string) error { return nil }}
	req := request()
	for _, p := range []string{"claude", "codex"} {
		if err := store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}); err != nil {
			t.Fatal(err)
		}
	}
	calls := 0
	_, err := r.Run(context.Background(), req, func(context.Context, Attempt) (Result, error) { calls++; return Result{}, nil })
	var deferred *Deferred
	if !errors.As(err, &deferred) || deferred.Attempts != 0 || calls != 0 {
		t.Fatal(err, calls)
	}
	bad := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(bad, []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	r.Health = providerhealth.New(bad, nil)
	diagnostics := 0
	r.Diagnostic = func(err error) {
		if errors.Is(err, providerhealth.ErrDegraded) {
			diagnostics++
		}
	}
	result, err := r.Run(context.Background(), req, func(context.Context, Attempt) (Result, error) { return Result{Text: "valid"}, nil })
	if err != nil || result.Text != "valid" || diagnostics == 0 {
		t.Fatal(result, err, diagnostics)
	}
}

func TestSchedulerCheckBeforeDataClaimDoesNotLeaseProbe(t *testing.T) {
	now := time.Now()
	store := providerhealth.New(t.TempDir(), func() time.Time { return now })
	r := Router{Health: store, Now: func() time.Time { return now }, Allowed: func(string) error { return nil }}
	req := request()
	for _, p := range []string{"claude", "codex"} {
		if err := store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.Check(context.Background(), req); !errors.Is(err, ErrDeferred) {
		t.Fatal(err)
	}
	now = now.Add(6 * time.Minute)
	if err := r.Check(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	state, err := store.Read(context.Background(), providerhealth.AccountScope("claude", ""))
	if err != nil || state.State != providerhealth.QuotaWait {
		t.Fatal(state, err)
	}
}

func TestModelQuotaRecordedOnlyOnProvenSelectedBucket(t *testing.T) {
	for _, tc := range []struct {
		provider, scope, bucket, window string
		modelOnly                       bool
	}{
		{"claude", "installation", "", "five_hour", false},
		{"claude", "installation", "", "seven_day", false},
		{"claude", "installation", "", "seven_day_opus", true},
		{"codex", "model", "opus", "", true},
	} {
		t.Run(tc.provider+tc.window+tc.scope, func(t *testing.T) {
			store := providerhealth.New(t.TempDir(), nil)
			r := Router{Health: store, Allowed: func(string) error { return nil }}
			req := request()
			if tc.provider == "codex" {
				req.Preferred, req.Reserve = "codex", "claude"
			}
			req.Model = func(string, digest.Tier) string { return "opus" }
			_, err := r.Run(context.Background(), req, func(_ context.Context, a Attempt) (Result, error) {
				if a.Provider == req.Preferred {
					return Result{}, &providers.Failure{Provider: a.Provider, Category: providers.Quota, Scope: tc.scope, Bucket: tc.bucket, Window: tc.window}
				}
				return Result{Text: "ok"}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			account := providerhealth.AccountScope(req.Preferred, "")
			global, e := store.Read(context.Background(), account)
			if e != nil {
				t.Fatal(e)
			}
			model, e := store.Read(context.Background(), providerhealth.ModelScope(account, "opus"))
			if e != nil {
				t.Fatal(e)
			}
			if tc.modelOnly {
				if global.State != providerhealth.Available || model.State != providerhealth.QuotaWait {
					t.Fatal(global, model)
				}
			} else if global.State != providerhealth.QuotaWait || model.State != providerhealth.Available {
				t.Fatal(global, model)
			}
		})
	}
}
func TestBlockedModelDoesNotClaimOrPostponeAccountProbe(t *testing.T) {
	now := time.Now()
	store := providerhealth.New(t.TempDir(), func() time.Time { return now })
	r := Router{Health: store, Now: func() time.Time { return now }, Allowed: func(string) error { return nil }}
	req := request()
	req.Model = func(string, digest.Tier) string { return "opus" }
	account := providerhealth.AccountScope("claude", "")
	f := &providers.Failure{Provider: "claude", Category: providers.Quota}
	if err := store.RecordQuota(context.Background(), account, f); err != nil {
		t.Fatal(err)
	}
	now = now.Add(6 * time.Minute)
	if err := store.RecordQuota(context.Background(), providerhealth.ModelScope(account, "opus"), f); err != nil {
		t.Fatal(err)
	}
	before, _ := store.Read(context.Background(), account)
	ctx, cancel := context.WithDeadline(context.Background(), now.Add(time.Minute))
	defer cancel()
	_, err := r.Run(ctx, req, func(_ context.Context, a Attempt) (Result, error) {
		if a.Provider != "codex" {
			t.Fatal("blocked model called")
		}
		return Result{Text: "reserve"}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	after, _ := store.Read(context.Background(), account)
	if before != after {
		t.Fatal("metadata-only blocked request consumed account probe", before, after)
	}
}
func TestCanceledRecoveryReleasesLeaseBeforeReturn(t *testing.T) {
	now := time.Now()
	store := providerhealth.New(t.TempDir(), func() time.Time { return now })
	r := Router{Health: store, Now: func() time.Time { return now }, Allowed: func(string) error { return nil }}
	req := request()
	account := providerhealth.AccountScope("claude", "")
	if err := store.RecordQuota(context.Background(), account, &providers.Failure{Provider: "claude", Category: providers.Quota}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(6 * time.Minute)
	ctx, cancel := context.WithDeadline(context.Background(), now.Add(time.Minute))
	defer cancel()
	calls := 0
	_, err := r.Run(ctx, req, func(_ context.Context, a Attempt) (Result, error) {
		calls++
		cancel()
		return Result{}, quota(a.Provider)
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal(err, calls)
	}
	state, err := store.Read(context.Background(), account)
	if err != nil || state.State != providerhealth.QuotaWait || state.LeaseToken != "" {
		t.Fatal(state, err)
	}
}
