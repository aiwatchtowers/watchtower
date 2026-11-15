package slack

import (
	"bytes"
	"context"
	"log"
	"strconv"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewRateLimiter(t *testing.T) {
	rl := NewRateLimiter()
	assert.NotNil(t, rl.limiter)
	assert.NotNil(t, rl.gate)
	assert.True(t, rl.backoff.IsZero())
}

func TestWaitRespectsContext(t *testing.T) {
	rl := NewRateLimiter()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled

	err := rl.Wait(ctx, Tier2)
	assert.ErrorIs(t, err, context.Canceled)
}

func TestWaitUnknownTierPassesThrough(t *testing.T) {
	rl := NewRateLimiter()
	err := rl.Wait(context.Background(), 99)
	assert.NoError(t, err)
	rl.Done(99)
}

// The timing tests run in a synctest bubble: the clock is the bubble's,
// so a wait is measured exactly and a loaded machine cannot stretch it.

func TestWaitRespectsBackoff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewRateLimiter()

		// Set a short backoff.
		backoffDuration := 50 * time.Millisecond
		rl.HandleRateLimit(Tier2, backoffDuration)

		start := time.Now()
		err := rl.Wait(context.Background(), Tier2)
		elapsed := time.Since(start)

		require.NoError(t, err)
		rl.Done(Tier2)
		// Waits out the backoff, which includes jitter up to 25%.
		assert.GreaterOrEqual(t, elapsed, backoffDuration)
		assert.LessOrEqual(t, elapsed, backoffDuration*5/4)
	})
}

func TestHandleRateLimitSetsBackoff(t *testing.T) {
	rl := NewRateLimiter()

	rl.HandleRateLimit(Tier3, 2*time.Second)

	rl.mu.Lock()
	until := rl.backoff
	rl.mu.Unlock()

	assert.False(t, until.IsZero())
	// Should be at least 2 seconds from now (before jitter check, it's at least 2s).
	assert.True(t, until.After(time.Now().Add(1*time.Second)),
		"backoff should be at least 1 second in the future")
}

func TestBackoffContextCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewRateLimiter()

		// Set a long backoff.
		rl.HandleRateLimit(Tier2, 10*time.Second)

		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()

		start := time.Now()
		err := rl.Wait(ctx, Tier2)
		elapsed := time.Since(start)

		assert.ErrorIs(t, err, context.DeadlineExceeded)
		// Ends with the context, not after the 10-second backoff.
		assert.Equal(t, 50*time.Millisecond, elapsed)
	})
}

func TestTierConstants(t *testing.T) {
	assert.Equal(t, 2, Tier2)
	assert.Equal(t, 3, Tier3)
}

func TestUnlimitedRateLimiter(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewUnlimitedRateLimiter()

		// Many rapid calls never wait.
		start := time.Now()
		for range 100 {
			err := rl.Wait(context.Background(), Tier2)
			require.NoError(t, err)
			err = rl.Wait(context.Background(), Tier3)
			require.NoError(t, err)
		}
		assert.Zero(t, time.Since(start), "unlimited limiter should not throttle")
	})
}

func TestStatsAndResetStats(t *testing.T) {
	rl := NewUnlimitedRateLimiter()

	// Record some requests
	rl.Done(Tier2)
	rl.Done(Tier2)
	rl.Done(Tier3)
	rl.Done(Tier4)

	// Simulate a rate limit
	rl.HandleRateLimit(Tier2, 10*time.Millisecond)

	counts, retries := rl.Stats()
	assert.Equal(t, 2, counts[Tier2])
	assert.Equal(t, 1, counts[Tier3])
	assert.Equal(t, 1, counts[Tier4])
	assert.Equal(t, 1, retries)

	// Verify Stats returns a copy (modifying returned map should not affect internal state)
	counts[Tier2] = 999
	counts2, _ := rl.Stats()
	assert.Equal(t, 2, counts2[Tier2])

	// Reset and verify
	rl.ResetStats()
	counts, retries = rl.Stats()
	assert.Empty(t, counts)
	assert.Equal(t, 0, retries)
}

func TestHandleRateLimitDefaultDuration(t *testing.T) {
	rl := NewRateLimiter()

	// Zero duration should default to at least 1 second
	rl.HandleRateLimit(Tier2, 0)

	rl.mu.Lock()
	until := rl.backoff
	rl.mu.Unlock()

	assert.False(t, until.IsZero())
	// With 0 duration, it defaults to 1s + jitter (up to 250ms)
	assert.True(t, until.After(time.Now().Add(500*time.Millisecond)))
}

func TestHandleRateLimitNeverShortens(t *testing.T) {
	rl := NewRateLimiter()

	// Set a long backoff
	rl.HandleRateLimit(Tier2, 10*time.Second)
	rl.mu.Lock()
	firstBackoff := rl.backoff
	rl.mu.Unlock()

	// Set a shorter backoff — should not shorten
	rl.HandleRateLimit(Tier2, 1*time.Millisecond)
	rl.mu.Lock()
	secondBackoff := rl.backoff
	rl.mu.Unlock()

	assert.False(t, secondBackoff.Before(firstBackoff), "backoff should never be shortened")
}

func TestHandleRateLimitWithLogger(t *testing.T) {
	rl := NewRateLimiter()
	var buf bytes.Buffer
	rl.logger = log.New(&buf, "", 0)

	rl.HandleRateLimit(Tier2, 100*time.Millisecond)
	assert.Contains(t, buf.String(), "rate limited")
}

func TestTier4Constant(t *testing.T) {
	assert.Equal(t, 4, Tier4)
}

func TestDoneIncrementsCount(t *testing.T) {
	rl := NewUnlimitedRateLimiter()

	rl.Done(Tier2)
	rl.Done(Tier2)
	rl.Done(Tier3)

	counts, _ := rl.Stats()
	assert.Equal(t, 2, counts[Tier2])
	assert.Equal(t, 1, counts[Tier3])
}

func TestBackoffExpires(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewRateLimiter()

		// Set a very short backoff
		rl.HandleRateLimit(Tier2, 10*time.Millisecond)

		// Wait for backoff to expire
		time.Sleep(50 * time.Millisecond)

		// Should succeed without any delay
		start := time.Now()
		err := rl.Wait(context.Background(), Tier2)
		elapsed := time.Since(start)

		require.NoError(t, err)
		rl.Done(Tier2)
		assert.Zero(t, elapsed, "expired backoff should not cause delay")
	})
}

// AIMD: one bucket per tier, halved on that tier's 429 down to a quarter of
// the documented rate, raised one step per aimdStepEvery successes up to
// twice it.

// call waits for one tier-t request and records it as a success.
func call(t *testing.T, rl *RateLimiter, tier int) {
	t.Helper()
	require.NoError(t, rl.Wait(context.Background(), tier))
	rl.Done(tier)
}

func TestAIMD_HalvesOnRateLimitAndRecovers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewRateLimiter()
		assert.InDelta(t, 20.0, rl.Rate(Tier2), 1e-9)

		rl.HandleRateLimit(Tier2, time.Second)
		assert.InDelta(t, 10.0, rl.Rate(Tier2), 1e-9)
		rl.HandleRateLimit(Tier2, time.Second)
		assert.InDelta(t, 5.0, rl.Rate(Tier2), 1e-9)
		rl.HandleRateLimit(Tier2, time.Second)
		assert.InDelta(t, 5.0, rl.Rate(Tier2), 1e-9, "never below the floor")

		for range aimdStepEvery - 1 {
			call(t, rl, Tier2)
		}
		assert.InDelta(t, 5.0, rl.Rate(Tier2), 1e-9, "one success short of a step")
		call(t, rl, Tier2)
		assert.InDelta(t, 6.0, rl.Rate(Tier2), 1e-9)
	})
}

func TestAIMD_ProbesUpToTwiceTheTier(t *testing.T) {
	for _, tc := range []struct {
		tier          int
		calls         int
		step, ceiling float64
	}{
		{Tier2, 400, 1, 40},
		{Tier3, 500, 2, 100},
		{Tier4, 400, 5, 200},
	} {
		t.Run(strconv.Itoa(tc.tier), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				rl := NewRateLimiter()
				for range tc.calls - 1 {
					call(t, rl, tc.tier)
				}
				assert.InDelta(t, tc.ceiling-tc.step, rl.Rate(tc.tier), 1e-9, "one step short of the ceiling")
				call(t, rl, tc.tier)
				assert.InDelta(t, tc.ceiling, rl.Rate(tc.tier), 1e-9)
				for range 100 {
					call(t, rl, tc.tier)
				}
				assert.InDelta(t, tc.ceiling, rl.Rate(tc.tier), 1e-9, "never above the ceiling")
			})
		})
	}
}

func TestAIMD_TiersAreIndependent(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewRateLimiter()

		// A Tier-4 burst well past its bucket's burst.
		for range 10 {
			call(t, rl, Tier4)
		}
		start := time.Now()
		call(t, rl, Tier2)
		assert.Zero(t, time.Since(start), "a Tier-2 call waits only on its own full bucket")

		rl.HandleRateLimit(Tier2, 30*time.Second)
		assert.InDelta(t, 10.0, rl.Rate(Tier2), 1e-9, "Tier 2 halves")
		assert.InDelta(t, 50.0, rl.Rate(Tier3), 1e-9, "Tier 3 untouched")
		assert.InDelta(t, 100.0, rl.Rate(Tier4), 1e-9, "Tier 4 untouched")

		start = time.Now()
		call(t, rl, Tier4)
		assert.GreaterOrEqual(t, time.Since(start), 30*time.Second, "the hold covers every tier")
	})
}

func TestAIMD_UnknownTierAndUnlimitedHaveNoRate(t *testing.T) {
	assert.Zero(t, NewRateLimiter().Rate(99))
	assert.Zero(t, NewUnlimitedRateLimiter().Rate(Tier2))
}

// The test-only unlimited limiter holds for a 429 only as long as Slack
// said: one without a usable Retry-After (missing or 0) holds nothing, so a
// test faking such 429s never waits the production default of a second per
// retry. A stated Retry-After still holds every call.
func TestUnlimited_UnstatedRetryAfterHoldsNothing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		rl := NewUnlimitedRateLimiter()
		rl.HandleRateLimit(Tier2, 0)
		assert.True(t, rl.HoldUntil().IsZero(), "no hold without a stated Retry-After")

		rl.HandleRateLimit(Tier2, 2*time.Second)
		assert.False(t, rl.HoldUntil().Before(time.Now().Add(2*time.Second)))

		limited := NewRateLimiter()
		limited.HandleRateLimit(Tier2, 0)
		assert.False(t, limited.HoldUntil().Before(time.Now().Add(time.Second)),
			"the production limiter still holds a second")
	})
}
