package inboxfeed_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/inboxfeed/feedtest"
)

// BenchmarkInboxFeedBuild builds the feed over the gate fixture (2 000
// outputs, 200 approvals, 500 open items, 30 folders) with no options. The
// speed gate itself (≤ 100 ms median) is checked over the socket.
func BenchmarkInboxFeedBuild(b *testing.B) {
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	d, err := db.Open(filepath.Join(b.TempDir(), "watchtower.db"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = d.Close() })
	if err := feedtest.SeedGate(d, now); err != nil {
		b.Fatal(err)
	}
	ctx := context.Background()
	b.ResetTimer()
	for b.Loop() {
		feed, err := inboxfeed.Build(ctx, d, inboxfeed.Options{Now: now})
		if err != nil {
			b.Fatal(err)
		}
		if len(feed.Cards) < feedtest.Outputs/2 {
			b.Fatalf("only %d cards", len(feed.Cards))
		}
	}
}
