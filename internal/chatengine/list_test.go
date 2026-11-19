package chatengine

import (
	"testing"
	"time"

	"watchtower/internal/db"
)

// liveLease is the claim's complement and Swift's ChatLease.isLive: a
// heartbeat exactly db.ChatLeaseStaleMS old is still held.
func TestChatLease_LiveUntilStale(t *testing.T) {
	now := time.UnixMilli(1_000_000)
	if !liveLease(now.UnixMilli()-db.ChatLeaseStaleMS, now) {
		t.Error("exactly 60 s old: still held")
	}
	if liveLease(now.UnixMilli()-db.ChatLeaseStaleMS-1, now) {
		t.Error("60.001 s old: stale")
	}
}
