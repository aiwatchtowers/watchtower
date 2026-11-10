package db

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"
)

// openItemsFixture is the open-items fixture the Desktop's InboxRefState
// tests read too.
const openItemsFixture = "../inbox/testdata/open_items.json"

func openIDs(items []OpenInboxItem) []int64 {
	ids := make([]int64, 0, len(items))
	for _, it := range items {
		ids = append(ids, int64(it.ID))
	}
	return ids
}

// The Go twin of HomeFeedQueries.openMessageClause agrees with the shared
// fixture: pending actionable feed-trigger rows, a snooze already past, a
// live Jira issue; not snoozed ahead, resolved, dismissed, ambient,
// archived, a deleted or unknown Jira issue, a non-feed trigger. Newest
// first by MAX(created_at, mentioned_at), then id.
func TestOpenInboxItems_SharedFixture(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestOpenItemsFixture(t, d, openItemsFixture)
	got, err := d.OpenInboxItems(context.Background(), fx.Now, 200)
	if err != nil {
		t.Fatal(err)
	}
	if ids := openIDs(got); !slices.Equal(ids, fx.OpenIDs) {
		t.Fatalf("open ids = %v, want %v", ids, fx.OpenIDs)
	}
	byID := map[int]OpenInboxItem{}
	for _, it := range got {
		byID[it.ID] = it
	}
	if it := byID[1]; it.SenderName != "Colleague A" || it.ChannelName != "general" || it.At != "2026-11-01T10:00:00Z" {
		t.Errorf("item 1 = sender %q channel %q at %q", it.SenderName, it.ChannelName, it.At)
	}
	if it := byID[17]; it.At != "2026-11-01T11:30:00Z" || it.Mentions == "[]" {
		t.Errorf("folded item 17 = at %q mentions %q; want its mentioned_at and its list", it.At, it.Mentions)
	}
	if it := byID[10]; it.SenderName != "" || it.ChannelName != "" {
		t.Errorf("Jira item 10 = sender %q channel %q; want none", it.SenderName, it.ChannelName)
	}
}

// A snooze ends at its instant: the item is open from snooze_until on.
func TestOpenInboxItems_SnoozeEndsAtItsInstant(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestOpenItemsFixture(t, d, openItemsFixture)
	got, err := d.OpenInboxItems(context.Background(), time.Date(2026, 11, 1, 18, 0, 0, 0, time.UTC), 200)
	if err != nil {
		t.Fatal(err)
	}
	if ids := openIDs(got); !slices.Contains(ids, 4) || len(ids) != len(fx.OpenIDs)+1 {
		t.Errorf("open ids at the snooze's end = %v; want the fixture's plus 4", ids)
	}
}

// The limit caps the rows, keeping the newest.
func TestOpenInboxItems_Limit(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	for _, n := range []int{0, 200, 201} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			if _, err := d.Exec(`DELETE FROM inbox_items`); err != nil {
				t.Fatal(err)
			}
			for i := 1; i <= n; i++ {
				at := now.Add(-time.Duration(i) * time.Minute).Format(time.RFC3339)
				if _, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
					VALUES ('C001', ?, 'U001', 'mention', ?)`, fmt.Sprintf("1000.%04d", i), at); err != nil {
					t.Fatal(err)
				}
			}
			got, err := d.OpenInboxItems(context.Background(), now, 200)
			if err != nil {
				t.Fatal(err)
			}
			if want := min(n, 200); len(got) != want {
				t.Fatalf("%d items read, want %d", len(got), want)
			}
			if n > 0 && got[0].MessageTS != "1000.0001" {
				t.Errorf("first = %s, want the newest", got[0].MessageTS)
			}
		})
	}
}

// A failed read is an error, never an empty list.
func TestOpenInboxItems_ReadErrorIsAnError(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`ALTER TABLE inbox_items RENAME TO inbox_items_gone`); err != nil {
		t.Fatal(err)
	}
	if got, err := d.OpenInboxItems(context.Background(), time.Now(), 200); err == nil {
		t.Fatalf("OpenInboxItems = %v, nil; want an error", got)
	}
}
