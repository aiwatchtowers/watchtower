package providerhealth

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"watchtower/internal/providers"
)

func TestRecoveryLease(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s := New(t.TempDir(), func() time.Time { return now })
	scope := AccountScope("claude", "fake-account")
	ctx := context.Background()
	if err := s.RecordQuota(ctx, scope, &providers.Failure{Provider: "claude", Category: providers.Quota}); err != nil {
		t.Fatal(err)
	}
	request := ProbeRequest{PendingSafe: true, Deadline: now.Add(time.Hour)}
	if _, ok, err := s.Claim(ctx, scope, request); err != nil || ok {
		t.Fatalf("early probe: %v %v", ok, err)
	}
	now = now.Add(5 * time.Minute)
	lease, ok, err := s.Claim(ctx, scope, request)
	if err != nil || !ok {
		t.Fatalf("due probe: %v %v", ok, err)
	}
	if _, ok, err := s.Claim(ctx, scope, request); err != nil || ok {
		t.Fatalf("duplicate probe: %v %v", ok, err)
	}
	if err := s.Complete(ctx, lease, nil); err != nil {
		t.Fatal(err)
	}
	state, err := s.Read(ctx, scope)
	if err != nil || state.State != Available {
		t.Fatalf("recovery: %+v %v", state, err)
	}
}

func fixture(t *testing.T) (*Store, *time.Time, Scope) {
	t.Helper()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return New(t.TempDir(), func() time.Time { return now }), &now, AccountScope("claude", "fake-account")
}
func read(t *testing.T, s *Store, scope Scope) Snapshot {
	t.Helper()
	v, err := s.Read(context.Background(), scope)
	if err != nil {
		t.Fatal(err)
	}
	return v
}
func record(t *testing.T, s *Store, scope Scope, reset time.Time) {
	t.Helper()
	if err := s.RecordQuota(context.Background(), scope, &providers.Failure{Provider: scope.provider, Category: providers.Quota, ResetAt: reset, Cause: errors.New("secret-payload")}); err != nil {
		t.Fatal(err)
	}
}
func claim(t *testing.T, s *Store, scope Scope, manual bool, deadline time.Time) Lease {
	t.Helper()
	l, ok, err := s.Claim(context.Background(), scope, ProbeRequest{PendingSafe: true, Manual: manual, Deadline: deadline})
	if err != nil || !ok {
		t.Fatalf("claim: %v %v", ok, err)
	}
	return l
}

func TestBackoffAndKnownReset(t *testing.T) {
	s, now, scope := fixture(t)
	for _, delay := range []time.Duration{5 * time.Minute, 15 * time.Minute, 30 * time.Minute, 60 * time.Minute, 60 * time.Minute} {
		record(t, s, scope, time.Time{})
		if got := read(t, s, scope).NextProbeAt.Sub(*now); got != delay {
			t.Fatalf("delay %v", got)
		}
	}
	reset := now.Add(2 * time.Hour)
	record(t, s, scope, reset)
	*now = reset.Add(-time.Second)
	if _, ok, err := s.Claim(context.Background(), scope, ProbeRequest{PendingSafe: true, Deadline: now.Add(time.Minute)}); err != nil || ok {
		t.Fatalf("before reset %v %v", ok, err)
	}
	*now = reset
	claim(t, s, scope, false, now.Add(time.Minute))
}
func TestManualCheckAndNoSyntheticRequest(t *testing.T) {
	s, now, scope := fixture(t)
	record(t, s, scope, now.Add(time.Hour))
	if _, _, err := s.Claim(context.Background(), scope, ProbeRequest{Manual: true, Deadline: now.Add(time.Minute)}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	l := claim(t, s, scope, true, now.Add(time.Minute))
	if err := s.Release(context.Background(), l); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.ManualCheck(context.Background(), scope); err != nil || ok {
		t.Fatalf("rate limit %v %v", ok, err)
	}
	*now = now.Add(time.Minute)
	if ok, err := s.ManualCheck(context.Background(), scope); err != nil || !ok {
		t.Fatalf("metadata %v %v", ok, err)
	}
	if _, ok, err := s.Claim(context.Background(), scope, ProbeRequest{PendingSafe: true, Manual: true, Deadline: now.Add(time.Minute)}); err != nil || ok {
		t.Fatalf("metadata shares limit %v %v", ok, err)
	}
}
func TestLeaseExpiryAndStaleCAS(t *testing.T) {
	s, now, scope := fixture(t)
	record(t, s, scope, time.Time{})
	*now = now.Add(5 * time.Minute)
	deadline := now.Add(time.Minute)
	old := claim(t, s, scope, false, deadline)
	*now = deadline.Add(14 * time.Second)
	if v := read(t, s, scope); v.State != ProbeLeased {
		t.Fatal(v)
	}
	*now = deadline.Add(15 * time.Second)
	current := claim(t, s, scope, false, now.Add(time.Minute))
	if err := s.Complete(context.Background(), old, nil); !errors.Is(err, ErrStaleLease) {
		t.Fatal(err)
	}
	if v := read(t, s, scope); v.State != ProbeLeased {
		t.Fatal(v)
	}
	if err := s.Complete(context.Background(), current, providers.WithFailure("claude", providers.Auth, errors.New("secret-payload"))); err != nil {
		t.Fatal(err)
	}
	if v := read(t, s, scope); v.State != QuotaWait || v.LastFailure != providers.Auth || v.QuotaCount != 1 || !v.NextProbeAt.After(*now) {
		t.Fatal(v)
	}
}
func TestExactScopeIsolationAndPrivacy(t *testing.T) {
	s, _, scope := fixture(t)
	global := AccountScope("claude", "fake-account")
	model := ModelScope(global, "opus")
	record(t, s, model, time.Time{})
	for _, other := range []Scope{global, ModelScope(global, "sonnet"), AccountScope("claude", "other-account"), AccountScope("codex", "fake-account"), AccountScope("claude", "")} {
		if v := read(t, s, other); v.State != Available {
			t.Fatal(v)
		}
	}
	record(t, s, scope, time.Time{})
	// Consumers must combine global AND model lookup: a global failure is stored
	// at the account key, regardless of the model of the request that found it.
	if read(t, s, global).State != QuotaWait {
		t.Fatal("global missing")
	}
	if read(t, New(s.dir, nil), model).State != QuotaWait {
		t.Fatal("restart lost model circuit")
	}
	b, err := os.ReadFile(filepath.Join(s.dir, "health.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"fake-account", "other-account", "opus", "secret-payload", "claude"} {
		if bytes.Contains(b, []byte(raw)) {
			t.Fatalf("persisted raw value %q", raw)
		}
	}
	for name, mode := range map[string]os.FileMode{"health.json": 0600, "health.lock": 0600, ".": 0700} {
		info, err := os.Stat(filepath.Join(s.dir, name))
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("permissions %s: %v %v", name, info, err)
		}
	}
}
func TestCancellationAndInvalidQuota(t *testing.T) {
	s, now, scope := fixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.RecordQuota(ctx, scope, &providers.Failure{Provider: "claude", Category: providers.Quota}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.dir + "/health.json"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if err := s.RecordQuota(context.Background(), scope, &providers.Failure{Provider: "claude", Category: providers.RateLimit}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	record(t, s, scope, time.Time{})
	*now = now.Add(5 * time.Minute)
	if _, ok, err := s.Claim(ctx, scope, ProbeRequest{PendingSafe: true, Deadline: now.Add(time.Minute)}); ok || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel claim %v %v", ok, err)
	}
	l := claim(t, s, scope, false, now.Add(time.Minute))
	if err := s.Release(context.Background(), l); err != nil {
		t.Fatal(err)
	}
	if v := read(t, s, scope); v.State != QuotaWait || v.LastFailure != providers.Cancelled {
		t.Fatal(v)
	}
}
func TestDegradedStateNeverOverwritten(t *testing.T) {
	for _, content := range []string{`{"salt":"` + strings.Repeat("a", 64) + `","entries":{}}`, "not-json", `{"version":2,"salt":"secret"}`, `{"version":1,"salt":"secret","entries":{}}`} {
		t.Run(content, func(t *testing.T) {
			s, _, scope := fixture(t)
			path := filepath.Join(s.dir, "health.json")
			if err := os.WriteFile(path, []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
			err := s.RecordQuota(context.Background(), scope, &providers.Failure{Provider: "claude", Category: providers.Quota})
			if !errors.Is(err, ErrDegraded) {
				t.Fatal(err)
			}
			b, _ := os.ReadFile(path)
			if string(b) != content {
				t.Fatal("clobbered damaged state")
			}
			if strings.Contains(err.Error(), "secret") {
				t.Fatal("leaked state")
			}
		})
	}
	s, _, scope := fixture(t)
	record(t, s, scope, time.Time{})
	if err := os.Chmod(filepath.Join(s.dir, "health.json"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read(context.Background(), scope); !errors.Is(err, ErrDegraded) {
		t.Fatal(err)
	}
}

func TestPastResetBacksOffAndQuotaInvalidatesLease(t *testing.T) {
	s, now, scope := fixture(t)
	record(t, s, scope, now.Add(-time.Second))
	if got := read(t, s, scope).NextProbeAt; !got.Equal(now.Add(5 * time.Minute)) {
		t.Fatal(got)
	}
	*now = now.Add(5 * time.Minute)
	l := claim(t, s, scope, false, now.Add(time.Minute))
	record(t, s, scope, time.Time{})
	if err := s.Complete(context.Background(), l, nil); !errors.Is(err, ErrStaleLease) {
		t.Fatal(err)
	}
	if v := read(t, s, scope); v.State != QuotaWait || v.QuotaCount != 2 || !v.NextProbeAt.Equal(now.Add(15*time.Minute)) {
		t.Fatal(v)
	}
}
func TestExpiredCompletionCannotRecover(t *testing.T) {
	s, now, scope := fixture(t)
	record(t, s, scope, time.Time{})
	*now = now.Add(5 * time.Minute)
	l := claim(t, s, scope, false, now.Add(time.Minute))
	*now = now.Add(time.Minute + 15*time.Second)
	if err := s.Complete(context.Background(), l, nil); !errors.Is(err, ErrStaleLease) {
		t.Fatal(err)
	}
	if v := read(t, s, scope); v.State != QuotaWait {
		t.Fatal(v)
	}
}
func TestRejectSymlinksAndSpecialFiles(t *testing.T) {
	s, _, scope := fixture(t)
	other := filepath.Join(t.TempDir(), "other")
	if err := os.WriteFile(other, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, filepath.Join(s.dir, "health.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Read(context.Background(), scope); !errors.Is(err, ErrDegraded) {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(other)
	if string(b) != "unchanged" {
		t.Fatal("modified symlink target")
	}
}
