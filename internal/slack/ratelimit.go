package slack

import (
	"context"
	"fmt"
	"log"
	"maps"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/slack-go/slack"
	"golang.org/x/time/rate"
)

// Rate limit tiers: one token bucket each, and the stats key.
const (
	Tier2 = 2 // users.list, conversations.list, team.info, search.messages
	Tier3 = 3 // conversations.history, conversations.replies, conversations.info
	Tier4 = 4 // users.info
)

// aimdStepEvery is how many consecutive successes of a tier raise its rate
// by one step.
const aimdStepEvery = 20

// tierAIMD is a tier's adaptive rate, in calls per minute. Slack documents
// its tiers as minimums (Tier 2 "20+ per minute", Tier 3 "50+", Tier 4
// "100+") and tolerates bursts above them, so a bucket starts at the
// documented rate, probes toward twice it, and backs off to a quarter of it.
type tierAIMD struct {
	start, ceiling, floor, step float64
}

var tierRates = map[int]tierAIMD{
	Tier2: {start: 20, ceiling: 40, floor: 5, step: 1},
	Tier3: {start: 50, ceiling: 100, floor: 12, step: 2},
	Tier4: {start: 100, ceiling: 200, floor: 25, step: 5},
}

// tierBucket is one tier's token bucket and its AIMD state (under
// RateLimiter.mu).
type tierBucket struct {
	aimd      tierAIMD
	bucket    *rate.Limiter
	perMinute float64
	successes int // consecutive successes since the last step or 429
}

// setRate moves the tier to perMinute, clamped to its floor and ceiling.
func (b *tierBucket) setRate(perMinute float64) {
	b.perMinute = min(max(perMinute, b.aimd.floor), b.aimd.ceiling)
	b.bucket.SetLimit(rate.Limit(b.perMinute / 60))
}

// RateLimiter enforces Slack API rate limits for one account: a token bucket
// per tier whose rate adapts (AIMD: halved on that tier's 429, raised a step
// per aimdStepEvery successes), one account-wide Retry-After hold that every
// tier waits for, and one concurrency gate.
type RateLimiter struct {
	limiter map[int]*tierBucket // per-tier buckets; nil in unlimited mode
	gate    chan struct{}       // semaphore (capacity 3), nil in unlimited mode
	logger  *log.Logger

	// unstatedHold is the hold of a 429 without a usable Retry-After
	// (missing or 0): a second, none in the test-only unlimited mode.
	unstatedHold time.Duration

	mu      sync.Mutex
	backoff time.Time   // account-wide hold, until this time
	counts  map[int]int // tier -> request count (for stats)
	retries int         // total 429 count
}

// NewRateLimiter creates a rate limiter with one adaptive bucket per tier,
// each starting at the tier's documented rate, burst 3.
func NewRateLimiter() *RateLimiter {
	rl := &RateLimiter{
		limiter: make(map[int]*tierBucket, len(tierRates)),
		gate:         make(chan struct{}, 3),
		counts:       make(map[int]int),
		unstatedHold: time.Second,
	}
	for tier, a := range tierRates {
		b := &tierBucket{aimd: a, bucket: rate.NewLimiter(0, 3)}
		b.setRate(a.start)
		rl.limiter[tier] = b
	}
	return rl
}

// NewUnlimitedRateLimiter creates a rate limiter that enforces no rate and no
// gate; a 429's stated Retry-After still holds every call, while one without
// a usable Retry-After holds nothing, so a test faking such 429s never waits
// on the wall clock. Intended for testing only.
func NewUnlimitedRateLimiter() *RateLimiter {
	return &RateLimiter{counts: make(map[int]int)}
}

// Rate returns the tier's current rate in calls per minute; zero for a tier
// without a bucket (an unknown tier, the unlimited limiter).
func (rl *RateLimiter) Rate(tier int) float64 {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if b := rl.limiter[tier]; b != nil {
		return b.perMinute
	}
	return 0
}

// Wait blocks until the rate limiter allows a request: it acquires the gate,
// waits out the account-wide hold, then waits on the tier's bucket.
func (rl *RateLimiter) Wait(ctx context.Context, tier int) error {
	return rl.waitUntil(ctx, tier, time.Time{})
}

// waitUntil is Wait under a fetch deadline: a hold that ends after a
// non-zero deadline — found on entry or extended mid-wait — releases the
// gate and returns ErrFetchDeadline at once, wrapping a
// *slack.RateLimitedError for the hold's remainder.
func (rl *RateLimiter) waitUntil(ctx context.Context, tier int, deadline time.Time) error {
	if rl.gate != nil {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case rl.gate <- struct{}{}:
		}
	}

	for {
		rl.mu.Lock()
		backoff := rl.backoff
		rl.mu.Unlock()

		if !backoff.After(time.Now()) {
			break
		}
		if !deadline.IsZero() && backoff.After(deadline) {
			rl.releaseGate()
			return fmt.Errorf("%w: %w", ErrFetchDeadline, &slack.RateLimitedError{RetryAfter: time.Until(backoff)})
		}
		select {
		case <-ctx.Done():
			rl.releaseGate()
			return ctx.Err()
		case <-time.After(time.Until(backoff)):
		}
	}

	b := rl.limiter[tier] // the map is never written after construction
	if b == nil {
		return nil
	}
	if err := b.bucket.Wait(ctx); err != nil {
		rl.releaseGate()
		return err
	}
	return nil
}

// Done releases the gate and records a successful request: every
// aimdStepEvery consecutive successes raise the tier's rate a step.
// Only call this after a request was actually made.
func (rl *RateLimiter) Done(tier int) {
	rl.mu.Lock()
	rl.counts[tier]++
	if b := rl.limiter[tier]; b != nil {
		b.successes++
		if b.successes >= aimdStepEvery {
			b.successes = 0
			b.setRate(b.perMinute + b.aimd.step)
		}
	}
	rl.mu.Unlock()
	rl.releaseGate()
}

// doneCountOnly releases the gate and counts a request that is no success
// for the rate: a 429 (HandleRateLimit has already lowered the rate) or one
// Slack never answered (a transport error, a cancelled ctx).
func (rl *RateLimiter) doneCountOnly(tier int) {
	rl.mu.Lock()
	rl.counts[tier]++
	rl.mu.Unlock()
	rl.releaseGate()
}

// releaseGate releases the global gate without incrementing stats.
// Used on early exits where no API request was actually made.
func (rl *RateLimiter) releaseGate() {
	if rl.gate != nil {
		<-rl.gate
	}
}

// HandleRateLimit records a 429 of the tier: its rate halves (not below the
// floor) and every tier holds for retryAfter plus up to a quarter of jitter.
func (rl *RateLimiter) HandleRateLimit(tier int, retryAfter time.Duration) {
	if retryAfter <= 0 {
		retryAfter = rl.unstatedHold
	}
	var backoff time.Duration // zero (no hold) only in the unlimited mode
	if retryAfter > 0 {
		jitterMax := max(int64(retryAfter)/4, 1)
		backoff = retryAfter + time.Duration(rand.Int64N(jitterMax))
	}
	until := time.Now().Add(backoff)

	rl.mu.Lock()
	// Only extend backoff, never shorten — prevents concurrent 429s from
	// racing to reduce the wait time.
	if until.After(rl.backoff) {
		rl.backoff = until
	}
	rl.retries++
	perMinute := 0.0
	if b := rl.limiter[tier]; b != nil {
		b.successes = 0
		b.setRate(b.perMinute / 2)
		perMinute = b.perMinute
	}
	rl.mu.Unlock()

	if rl.logger != nil {
		rl.logger.Printf("rate limited: backing off %.1fs (tier %d now %.0f/min)", backoff.Seconds(), tier, perMinute)
	}
}

// HoldUntil returns the end of the account-wide hold, zero when none is
// active.
func (rl *RateLimiter) HoldUntil() time.Time {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if rl.backoff.After(time.Now()) {
		return rl.backoff
	}
	return time.Time{}
}

// Stats returns per-tier request counts and total 429 retry count.
func (rl *RateLimiter) Stats() (counts map[int]int, retries int) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	c := make(map[int]int, len(rl.counts))
	maps.Copy(c, rl.counts)
	return c, rl.retries
}

// ResetStats clears all counters.
func (rl *RateLimiter) ResetStats() {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rl.counts = make(map[int]int)
	rl.retries = 0
}
