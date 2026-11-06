package providerrouting

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

func TestStatusUsesExactScopesWithoutRecoveryOrWrites(t *testing.T) {
	now := time.Date(2026, 1, 2, 10, 0, 0, 0, time.UTC)
	for _, p := range []string{"claude", "codex"} {
		t.Run(p, func(t *testing.T) {
			dir := t.TempDir()
			health := providerhealth.New(dir, func() time.Time { return now })
			req := Request{Tier: digest.TierStrong, Identity: func(string) string { return "fake-account" },
				Model: func(string, digest.Tier) string { return "strong-a" }}
			router := &Router{Health: health, Allowed: func(string) error { return nil }}
			ctx := context.Background()
			scope := providerhealth.ModelScope(providerhealth.AccountScope(p, "fake-account"), "strong-a")
			require.NoError(t, health.RecordQuota(ctx, scope, &providers.Failure{Provider: p, Category: providers.Quota}))
			before, err := os.ReadFile(filepath.Join(dir, "health.json"))
			require.NoError(t, err)
			info, err := os.Stat(filepath.Join(dir, "health.json"))
			require.NoError(t, err)
			now = now.Add(24 * time.Hour)
			status, err := router.Status(ctx, req, p)
			require.NoError(t, err)
			require.Equal(t, providerhealth.QuotaWait, status.State)
			require.NotNil(t, status.NextProbeAt)
			require.True(t, now.After(*status.NextProbeAt), "a passed clock does not clear quota")
			after, err := os.ReadFile(filepath.Join(dir, "health.json"))
			require.NoError(t, err)
			finalInfo, err := os.Stat(filepath.Join(dir, "health.json"))
			require.NoError(t, err)
			require.Equal(t, before, after)
			require.True(t, info.ModTime().Equal(finalInfo.ModTime()))
			req.Identity = func(string) string { return "other-account" }
			available, err := router.Status(ctx, req, p)
			require.NoError(t, err)
			require.Equal(t, providerhealth.Available, available.State)
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			_, err = router.Status(cancelled, req, p)
			require.ErrorIs(t, err, context.Canceled)
		})
	}
}

func TestStatusStorageErrorsRemainOperational(t *testing.T) {
	path := filepath.Join(t.TempDir(), "blocked")
	health := providerhealth.New(path, nil)
	require.NoError(t, os.WriteFile(path, []byte("no"), 0600))
	// An invalid directory is storage degradation, never an available scope.
	router := &Router{Health: health, Allowed: func(string) error { return nil }}
	_, err := router.Status(context.Background(), Request{}, "claude")
	require.ErrorIs(t, err, providerhealth.ErrDegraded)
}

func TestStatusExpiredLeaseProjectsWaitingWithoutWriting(t *testing.T) {
	now := time.Date(2026, 1, 2, 10, 0, 0, 0, time.UTC)
	dir := t.TempDir()
	store := providerhealth.New(dir, func() time.Time { return now })
	scope := providerhealth.AccountScope("claude", "")
	ctx := context.Background()
	require.NoError(t, store.RecordQuota(ctx, scope, &providers.Failure{Provider: "claude", Category: providers.Quota}))
	now = now.Add(time.Hour)
	_, ok, err := store.Claim(ctx, scope, providerhealth.ProbeRequest{PendingSafe: true, Deadline: now.Add(time.Minute)})
	require.NoError(t, err)
	require.True(t, ok)
	path := filepath.Join(dir, "health.json")
	before, err := os.ReadFile(path)
	require.NoError(t, err)
	now = now.Add(2 * time.Minute)
	status, err := (&Router{Health: store, Allowed: func(string) error { return nil }}).Status(ctx, Request{}, "claude")
	require.NoError(t, err)
	require.Equal(t, providerhealth.QuotaWait, status.State)
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, before, after)
}

func TestCheckStatusRateGateKeepsExactModelQuotaBothDirections(t *testing.T) {
	for _, p := range []string{"claude", "codex"} {
		t.Run(p, func(t *testing.T) {
			now := time.Date(2026, 1, 1, 1, 2, 0, 0, time.UTC)
			store := providerhealth.New(t.TempDir(), func() time.Time { return now })
			req := Request{Identity: func(string) string { return "fixture-account" }, Model: func(string, digest.Tier) string { return "form-model" }}
			scope := providerhealth.ModelScope(providerhealth.AccountScope(p, "fixture-account"), "form-model")
			ctx := context.Background()
			require.NoError(t, store.RecordQuota(ctx, scope, &providers.Failure{Provider: p, Category: providers.Quota}))
			router := &Router{Health: store, Allowed: func(string) error { return nil }}
			first, err := router.CheckStatus(ctx, req, p)
			require.NoError(t, err)
			require.True(t, *first.ManualAllowed)
			require.Equal(t, providerhealth.QuotaWait, first.State)
			second, err := router.CheckStatus(ctx, req, p)
			require.NoError(t, err)
			require.False(t, *second.ManualAllowed)
			now = now.Add(time.Minute)
			third, err := router.CheckStatus(ctx, req, p)
			require.NoError(t, err)
			require.True(t, *third.ManualAllowed)
			require.Equal(t, providerhealth.QuotaWait, third.State)
			// Even a reset in the past never becomes a recovery success.
			now = now.Add(24 * time.Hour)
			last, err := router.CheckStatus(ctx, req, p)
			require.NoError(t, err)
			require.Equal(t, providerhealth.QuotaWait, last.State)
		})
	}
}

func TestCheckStatusRefusalAndStorageFailure(t *testing.T) {
	ctx := context.Background()
	denied := errors.New("denied")
	router := &Router{Allowed: func(string) error { return denied }}
	_, err := router.CheckStatus(ctx, Request{}, "codex")
	require.ErrorIs(t, err, denied)
	router.Allowed = func(string) error { return nil }
	_, err = router.CheckStatus(ctx, Request{}, "codex")
	require.ErrorIs(t, err, providerhealth.ErrDegraded)
}
