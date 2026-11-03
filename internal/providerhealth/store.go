// Package providerhealth stores installation-wide quota circuits. It performs no
// inference, credential reads, polling or routing. Callers must consult BOTH the
// account-wide scope and any proven model scope before routing a model request;
// Read and Claim deliberately operate on one exact scope, never on window names.
package providerhealth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/fsutil"
	"watchtower/internal/providers"
)

type State string

const (
	Available   State = "available"
	QuotaWait   State = "quota_wait"
	ProbeLeased State = "probe_leased"
)

var (
	ErrDegraded   = errors.New("provider health storage degraded")
	ErrStaleLease = errors.New("provider health lease no longer owned")
	ErrInvalid    = errors.New("invalid provider health request")
)

// Scope keeps caller identity in memory only. Never pass credentials as identity.
// An empty reliable identity intentionally falls back to this installation's
// provider-wide circuit. Identity must come from the same provider's trusted auth
// metadata; an unrelated service's account identifier is not a substitute.
type Scope struct{ provider, identity, model string }

func AccountScope(provider, reliableIdentity string) Scope {
	return Scope{provider: provider, identity: reliableIdentity}
}

// ModelScope requires affirmative evidence that a quota applies only to this
// canonical selected-model bucket. Time windows (five_hour/seven_day) are NOT
// model buckets. The router must use this SAME canonical bucket on lookup.
func ModelScope(account Scope, canonicalModel string) Scope {
	account.model = canonicalModel
	return account
}

type Snapshot struct {
	State        State                   `json:"state"`
	ResetAt      time.Time               `json:"reset_at,omitempty"`
	NextProbeAt  time.Time               `json:"next_probe_at,omitempty"`
	QuotaCount   int                     `json:"quota_count"`
	LastFailure  providers.ErrorCategory `json:"last_failure,omitempty"`
	LastManualAt time.Time               `json:"last_manual_at,omitempty"`
	LeaseToken   string                  `json:"lease_token,omitempty"`
	LeaseUntil   time.Time               `json:"lease_until,omitempty"`
}
type diskState struct {
	Version int                 `json:"version"`
	Salt    string              `json:"salt"`
	Entries map[string]Snapshot `json:"entries"`
}

// Store persists circuits in an installation directory, independent of workspace DBs.
// New is also the isolation seam for tests; it does not touch disk until used.
type Store struct {
	dir string
	now func() time.Time
}

func New(dir string, now func() time.Time) *Store {
	if now == nil {
		now = time.Now
	}
	return &Store{dir: dir, now: now}
}
func Installation() (*Store, error) {
	root, err := config.AppSupportDir()
	if err != nil {
		return nil, degraded(err)
	}
	return New(filepath.Join(root, "provider-health"), nil), nil
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
func validScope(scope Scope) bool { return scope.provider == "claude" || scope.provider == "codex" }
func scopeKey(d *diskState, scope Scope) string {
	mac := hmac.New(sha256.New, []byte(d.Salt))
	// JSON tuple is unambiguous even if identity/model contain separators.
	b, _ := json.Marshal([]string{scope.provider, scope.identity, scope.model})
	_, _ = mac.Write(b)
	return hex.EncodeToString(mac.Sum(nil))
}
func degraded(err error) error {
	// Avoid including OS paths or arbitrary persisted content in diagnostics.
	return fmt.Errorf("%w: %s", ErrDegraded, storageReason(err))
}
func storageReason(err error) string {
	if errors.Is(err, os.ErrPermission) {
		return "permission denied"
	}
	return "state read/write failed"
}
func (s *Store) transaction(ctx context.Context, scope Scope, fn func(*Snapshot) (bool, error)) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !validScope(scope) {
		return ErrInvalid
	}
	if info, err := os.Lstat(s.dir); err == nil && !info.IsDir() {
		return degraded(ErrInvalid)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return degraded(err)
	}
	if err := fsutil.MakePrivateDir(s.dir); err != nil {
		return degraded(err)
	}
	for _, name := range []string{"health.lock", "health.json"} {
		info, err := os.Lstat(filepath.Join(s.dir, name))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return degraded(err)
		}
		if err == nil && (!info.Mode().IsRegular() || info.Mode().Perm() != 0600) {
			return degraded(os.ErrPermission)
		}
	}
	unlock, err := fsutil.LockFile(ctx, filepath.Join(s.dir, "health.lock"))
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return degraded(err)
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	path := filepath.Join(s.dir, "health.json")
	d := diskState{Version: 1, Entries: map[string]Snapshot{}}
	b, err := os.ReadFile(path)
	fresh := errors.Is(err, os.ErrNotExist)
	if err != nil && !fresh {
		return degraded(err)
	}
	if fresh {
		d.Salt, err = randomHex(32)
		if err != nil {
			return degraded(err)
		}
	} else {
		d = diskState{} // A missing version must not inherit the new-file default.
		if json.Unmarshal(b, &d) != nil || d.Version != 1 || len(d.Salt) != 64 || d.Entries == nil {
			return degraded(ErrInvalid)
		}
		if _, err := hex.DecodeString(d.Salt); err != nil {
			return degraded(err)
		}
		for key, v := range d.Entries {
			if !validEntry(key, v) {
				return degraded(ErrInvalid)
			}
		}
		info, err := os.Stat(path)
		if err != nil {
			return degraded(err)
		}
		if info.Mode().Perm() != 0600 {
			return degraded(os.ErrPermission)
		}
	}
	key := scopeKey(&d, scope)
	v, exists := d.Entries[key]
	if !exists {
		v.State = Available
	}
	changed, err := fn(&v)
	if err != nil {
		return err
	}
	if !changed {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	d.Entries[key] = v
	b, err = json.Marshal(d)
	if err != nil {
		return degraded(err)
	}
	if err := fsutil.WriteFileAtomic(path, b, 0600); err != nil {
		return degraded(err)
	}
	return nil
}
func validEntry(key string, v Snapshot) bool {
	if len(key) != 64 {
		return false
	}
	if _, err := hex.DecodeString(key); err != nil {
		return false
	}
	if v.LastFailure != "" && v.LastFailure != providers.Unknown && safeCategory(v.LastFailure) != v.LastFailure {
		return false
	}
	if v.QuotaCount < 0 || v.QuotaCount > 4 {
		return false
	}
	switch v.State {
	case Available:
		return v.QuotaCount == 0 && v.LastFailure == "" && v.ResetAt.IsZero() && v.NextProbeAt.IsZero() && v.LeaseToken == "" && v.LeaseUntil.IsZero()
	case QuotaWait:
		return v.QuotaCount > 0 && !v.NextProbeAt.IsZero() && v.LeaseToken == "" && v.LeaseUntil.IsZero()
	case ProbeLeased:
		if len(v.LeaseToken) != 48 {
			return false
		}
		if _, err := hex.DecodeString(v.LeaseToken); err != nil {
			return false
		}
		return v.QuotaCount > 0 && !v.NextProbeAt.IsZero() && !v.LeaseUntil.IsZero()
	default:
		return false
	}
}
func expire(v *Snapshot, now time.Time) bool {
	if v.State != ProbeLeased || now.Before(v.LeaseUntil) {
		return false
	}
	v.State = QuotaWait
	v.LeaseToken = ""
	v.LeaseUntil = time.Time{}
	return true
}
func (s *Store) Read(ctx context.Context, scope Scope) (Snapshot, error) {
	var out Snapshot
	err := s.transaction(ctx, scope, func(v *Snapshot) (bool, error) { changed := expire(v, s.now()); out = *v; return changed, nil })
	return out, err
}
func quota(v *Snapshot, f *providers.Failure, now time.Time) {
	v.QuotaCount++
	if v.QuotaCount > 4 {
		v.QuotaCount = 4
	}
	v.State = QuotaWait
	v.LastFailure = providers.Quota
	v.ResetAt = f.ResetAt
	v.NextProbeAt = now.Add(backoff(v.QuotaCount))
	if f.ResetAt.After(now) {
		v.NextProbeAt = f.ResetAt
	}
	v.LeaseToken = ""
	v.LeaseUntil = time.Time{}
}
func backoff(n int) time.Duration {
	if n < 1 {
		n = 1
	}
	if n > 4 {
		n = 4
	}
	return []time.Duration{5 * time.Minute, 15 * time.Minute, 30 * time.Minute, 60 * time.Minute}[n-1]
}

// RecordQuota accepts only an already classified quota. Scope selection is the
// caller's responsibility; raw Failure.Window/Bucket/Cause are never persisted.
func (s *Store) RecordQuota(ctx context.Context, scope Scope, f *providers.Failure) error {
	if f == nil || f.Category != providers.Quota || f.Provider != scope.provider {
		return ErrInvalid
	}
	return s.transaction(ctx, scope, func(v *Snapshot) (bool, error) { quota(v, f, s.now()); return true, nil })
}

type ProbeRequest struct {
	PendingSafe bool // An actual waiting no-tools request; never a synthetic ping.
	Manual      bool
	Deadline    time.Time // The real call's total deadline, not a new probe budget.
}

// Lease is an opaque CAS ownership capability, not a lock held during inference.
type Lease struct {
	scope Scope
	token string
}

func manual(v *Snapshot, now time.Time) bool {
	if !v.LastManualAt.IsZero() && now.Before(v.LastManualAt.Add(time.Minute)) {
		return false
	}
	v.LastManualAt = now
	return true
}

// ManualCheck reserves the per-minute metadata-only check when no safe request
// is pending. Call Claim(Manual:true) instead when a safe request IS pending.
func (s *Store) ManualCheck(ctx context.Context, scope Scope) (bool, error) {
	allowed := false
	err := s.transaction(ctx, scope, func(v *Snapshot) (bool, error) { allowed = manual(v, s.now()); return allowed, nil })
	if err != nil {
		return false, err
	}
	return allowed, nil
}
func (s *Store) Claim(ctx context.Context, scope Scope, req ProbeRequest) (Lease, bool, error) {
	var lease Lease
	claimed := false
	if !req.PendingSafe || req.Deadline.IsZero() {
		return lease, false, ErrInvalid
	}
	err := s.transaction(ctx, scope, func(v *Snapshot) (bool, error) {
		now := s.now()
		if !req.Deadline.After(now) {
			return false, ErrInvalid
		}
		changed := expire(v, now)
		if v.State != QuotaWait {
			return changed, nil
		}
		if req.Manual {
			if !manual(v, now) {
				return changed, nil
			}
		} else if now.Before(v.NextProbeAt) {
			return changed, nil
		}
		token, err := randomHex(24)
		if err != nil {
			return false, degraded(err)
		}
		v.State = ProbeLeased
		v.LeaseToken = token
		v.LeaseUntil = req.Deadline.Add(15 * time.Second)
		lease = Lease{scope: scope, token: token}
		claimed = true
		return true, nil
	})
	if err != nil {
		return Lease{}, false, err
	}
	return lease, claimed, nil
}

// Complete must be called after the pending request finishes. Nonquota failures
// keep the circuit open and persist only the category, never error text. On
// cancellation callers use Release with a bounded cleanup context (the call's
// canceled context cannot mutate); a crash is handled by lease expiry.
func (s *Store) Complete(ctx context.Context, lease Lease, callErr error) error {
	if lease.token == "" {
		return ErrStaleLease
	}
	return s.transaction(ctx, lease.scope, func(v *Snapshot) (bool, error) {
		now := s.now()
		if v.State != ProbeLeased || v.LeaseToken != lease.token || !now.Before(v.LeaseUntil) {
			return false, ErrStaleLease
		}
		if callErr == nil {
			lastManual := v.LastManualAt
			*v = Snapshot{State: Available, LastManualAt: lastManual}
			return true, nil
		}
		var f *providers.Failure
		if errors.As(callErr, &f) && f.Category == providers.Quota && f.Provider == lease.scope.provider {
			quota(v, f, now)
			return true, nil
		}
		category := providers.Unknown
		if errors.Is(callErr, context.Canceled) {
			category = providers.Cancelled
		} else if errors.Is(callErr, context.DeadlineExceeded) {
			category = providers.Timeout
		} else if f != nil && f.Provider == lease.scope.provider {
			category = safeCategory(f.Category)
		}
		v.State = QuotaWait
		v.LeaseToken = ""
		v.LeaseUntil = time.Time{}
		v.LastFailure = category
		v.NextProbeAt = now.Add(backoff(v.QuotaCount))
		if v.ResetAt.After(v.NextProbeAt) {
			v.NextProbeAt = v.ResetAt
		}
		return true, nil
	})
}
func safeCategory(c providers.ErrorCategory) providers.ErrorCategory {
	switch c {
	case providers.Unknown, providers.Quota, providers.RateLimit, providers.Overload, providers.Auth, providers.Model, providers.Policy, providers.ContextLimit, providers.Budget, providers.Cancelled, providers.Timeout, providers.Transport, providers.InvalidOutput, providers.Capability:
		return c
	}
	return providers.Unknown
}
func (s *Store) Release(ctx context.Context, lease Lease) error {
	return s.Complete(ctx, lease, context.Canceled)
}
