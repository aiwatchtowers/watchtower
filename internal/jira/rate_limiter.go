package jira

import (
	"context"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// RateLimiter implements a token bucket rate limiter for Jira API requests.
type RateLimiter struct {
	tokens     float64
	maxTokens  float64
	refillRate float64 // tokens per second
	lastRefill time.Time
	mu         sync.Mutex
}

// NewRateLimiter creates a rate limiter with 8 requests/second.
func NewRateLimiter() *RateLimiter {
	return &RateLimiter{
		tokens:     8,
		maxTokens:  8,
		refillRate: 8,
		lastRefill: time.Now(),
	}
}

// Wait blocks until a token is available or the context is cancelled.
func (rl *RateLimiter) Wait(ctx context.Context) error {
	for {
		rl.mu.Lock()
		rl.refill()
		if rl.tokens >= 1 {
			rl.tokens--
			rl.mu.Unlock()
			return nil
		}
		rl.mu.Unlock()

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (rl *RateLimiter) refill() {
	now := time.Now()
	elapsed := now.Sub(rl.lastRefill).Seconds()
	rl.tokens += elapsed * rl.refillRate
	if rl.tokens > rl.maxTokens {
		rl.tokens = rl.maxTokens
	}
	rl.lastRefill = now
}

// BackoffDuration returns exponential backoff duration for a given attempt (0-indexed).
// 1s, 2s, 4s.
func BackoffDuration(attempt int) time.Duration {
	switch attempt {
	case 0:
		return 1 * time.Second
	case 1:
		return 2 * time.Second
	default:
		return 4 * time.Second
	}
}

// maxRetryAfter caps how long doURLWith will honor a server's Retry-After
// hint. jira.Client.doURLWith runs inside phaseJiraSync's sequential
// runSync, and nothing reads the daemon's ctx before shutdown — an
// uncapped hour-long (or longer) Retry-After from a misbehaving proxy or a
// long throttling window would stall that one request, and everything the
// daemon cycle runs after it, for as long as the header says (up to 3x
// before "max retries exceeded"). A capped wait still honors the server's
// "not now" without blocking a whole sync cycle on it.
const maxRetryAfter = 60 * time.Second

// retryAfterDuration parses a Retry-After header value (RFC 9110 §10.2.3) —
// either a non-negative number of seconds or an HTTP-date — as a duration to
// wait measured from now, clamped to maxRetryAfter. ok is false when the
// header is absent, malformed, negative, or names a time already in the
// past; the caller falls back to BackoffDuration's fixed schedule in that
// case. The seconds path checks secs against the cap BEFORE the
// time.Duration multiplication: a very large but validly-parsed value (Atoi
// accepts anything an int holds) would otherwise overflow int64 nanoseconds
// and wrap to a negative duration, making time.After fire immediately
// instead of waiting — the opposite of what Retry-After asks for.
func retryAfterDuration(header string, now time.Time) (time.Duration, bool) {
	if header == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(header); err == nil {
		switch {
		case secs < 0:
			return 0, false
		case secs > int(maxRetryAfter/time.Second):
			return maxRetryAfter, true
		default:
			return time.Duration(secs) * time.Second, true
		}
	}
	if t, err := http.ParseTime(header); err == nil {
		if d := t.Sub(now); d > 0 {
			if d > maxRetryAfter {
				return maxRetryAfter, true
			}
			return d, true
		}
	}
	return 0, false
}
