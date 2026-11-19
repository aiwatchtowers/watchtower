package cloudkit

import "time"

// The bridge's rate limits as the owner sees them (Settings → Mobile's
// "iCloud is slowing sync down", go hub plan 3 Task 23): when CloudKit
// started refusing for rate (the class rate_limited, on a request, a record
// or an event) and has refused ever since. Any answered request without that
// class ends it.

// noteRate records one bridge answer: throttled (rate_limited) or not.
func (c *Client) noteRate(throttled bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	switch {
	case !throttled:
		c.throttledSince = time.Time{}
	case c.throttledSince.IsZero():
		c.throttledSince = c.c.Clock()
	}
}

// ThrottledSince is when CloudKit started rate-limiting this hub (zero: it
// does not now).
func (c *Client) ThrottledSince() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.throttledSince
}

// rateLimited: a bridge error class is CloudKit's rate limit.
func rateLimited(class string) bool { return class == "rate_limited" }
