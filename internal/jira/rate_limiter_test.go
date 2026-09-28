package jira

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRateLimiter_Wait(t *testing.T) {
	rl := NewRateLimiter()

	// Should be able to consume all 8 tokens immediately.
	ctx := context.Background()
	for i := 0; i < 8; i++ {
		require.NoError(t, rl.Wait(ctx))
	}

	// 9th should require waiting (tokens depleted).
	start := time.Now()
	require.NoError(t, rl.Wait(ctx))
	elapsed := time.Since(start)
	// Should have waited some time for token refill.
	assert.Greater(t, elapsed, 10*time.Millisecond)
}

func TestRateLimiter_Wait_CancelledContext(t *testing.T) {
	rl := NewRateLimiter()

	// Drain all tokens.
	ctx := context.Background()
	for i := 0; i < 8; i++ {
		require.NoError(t, rl.Wait(ctx))
	}

	// Cancel context.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := rl.Wait(ctx)
	assert.Error(t, err)
}

func TestBackoffDuration(t *testing.T) {
	assert.Equal(t, 1*time.Second, BackoffDuration(0))
	assert.Equal(t, 2*time.Second, BackoffDuration(1))
	assert.Equal(t, 4*time.Second, BackoffDuration(2))
	assert.Equal(t, 4*time.Second, BackoffDuration(5)) // capped at 4s
}

func TestRetryAfterDuration_Seconds(t *testing.T) {
	d, ok := retryAfterDuration("2", time.Now())
	require.True(t, ok)
	assert.Equal(t, 2*time.Second, d)
}

func TestRetryAfterDuration_HTTPDate(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	future := now.Add(30 * time.Second)
	d, ok := retryAfterDuration(future.Format(http.TimeFormat), now)
	require.True(t, ok)
	assert.InDelta(t, float64(30*time.Second), float64(d), float64(time.Second))
}

func TestRetryAfterDuration_Empty(t *testing.T) {
	_, ok := retryAfterDuration("", time.Now())
	assert.False(t, ok)
}

func TestRetryAfterDuration_Malformed(t *testing.T) {
	_, ok := retryAfterDuration("not-a-duration", time.Now())
	assert.False(t, ok)
}

func TestRetryAfterDuration_NegativeSecondsIgnored(t *testing.T) {
	_, ok := retryAfterDuration("-5", time.Now())
	assert.False(t, ok)
}

func TestRetryAfterDuration_PastHTTPDateIgnored(t *testing.T) {
	// http.TimeFormat's layout appends the literal "GMT" without converting
	// the instant, so both sides must already be in UTC or the comparison
	// silently drifts by the local UTC offset.
	now := time.Now().UTC()
	past := now.Add(-time.Hour)
	_, ok := retryAfterDuration(past.Format(http.TimeFormat), now)
	assert.False(t, ok)
}

// TestRetryAfterDuration_HugeSecondsClamped pins the fix for an unbounded
// Retry-After stalling a whole daemon sync cycle: a server (or misbehaving
// proxy) asking for a day's wait must be clamped to maxRetryAfter, not
// honored verbatim.
func TestRetryAfterDuration_HugeSecondsClamped(t *testing.T) {
	d, ok := retryAfterDuration("86400", time.Now()) // 24h
	require.True(t, ok)
	assert.Equal(t, maxRetryAfter, d)
}

// TestRetryAfterDuration_OverflowSecondsClampedNotNegative pins the fix for
// the multiplication overflow the old code had: a validly-parsed but huge
// seconds count (Atoi accepts anything an int holds, well past what
// secs*time.Second can represent as int64 nanoseconds without wrapping)
// must come back as the clamped ceiling, never a corrupted negative
// duration that would make time.After fire immediately.
func TestRetryAfterDuration_OverflowSecondsClampedNotNegative(t *testing.T) {
	// 9223372037 * time.Second overflows int64 nanoseconds under a naive
	// secs*time.Second multiplication (int64 nanosecond overflow happens
	// past ~9.223e9 seconds).
	d, ok := retryAfterDuration("9223372037", time.Now())
	require.True(t, ok)
	assert.Equal(t, maxRetryAfter, d)
	assert.Positive(t, d, "must never come back negative")
}

// TestRetryAfterDuration_FarFutureHTTPDateClamped pins the HTTP-date path's
// clamp: an hour-out date is honored only up to the ceiling.
func TestRetryAfterDuration_FarFutureHTTPDateClamped(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	future := now.Add(2 * time.Hour)
	d, ok := retryAfterDuration(future.Format(http.TimeFormat), now)
	require.True(t, ok)
	assert.Equal(t, maxRetryAfter, d)
}
