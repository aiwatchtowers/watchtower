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

// retryAfterDuration parses a Retry-After header value (RFC 9110 §10.2.3) —
// either a non-negative number of seconds or an HTTP-date — as a duration to
// wait measured from now. ok is false when the header is absent, malformed,
// negative, or names a time already in the past; the caller falls back to
// BackoffDuration's fixed schedule in that case. Without this, a 429's fixed
// 1/2/4s backoff ignored the server's own Retry-After hint entirely.
func retryAfterDuration(header string, now time.Time) (time.Duration, bool) {
	if header == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(header); err == nil {
		if secs < 0 {
			return 0, false
		}
		return time.Duration(secs) * time.Second, true
	}
	if t, err := http.ParseTime(header); err == nil {
		if d := t.Sub(now); d > 0 {
			return d, true
		}
	}
	return 0, false
}
