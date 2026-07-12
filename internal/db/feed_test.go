package db

import "testing"

func TestFeedBootstrapCutoffSeeded(t *testing.T) {
	d := openTestDB(t)
	cutoff, err := d.GetFeedBootstrapCutoff()
	if err != nil {
		t.Fatalf("GetFeedBootstrapCutoff: %v", err)
	}
	if cutoff == "" {
		t.Fatal("bootstrap cutoff should be seeded by migration 00014")
	}
}

func TestGetFeedItemMissingReturnsNil(t *testing.T) {
	d := openTestDB(t)
	item, err := d.GetFeedItem("situation", "999")
	if err != nil {
		t.Fatalf("GetFeedItem: %v", err)
	}
	if item != nil {
		t.Fatalf("expected nil for missing item, got %+v", item)
	}
}

func TestPublishSituationUpsertPreservesUserState(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'high', 'open', '2026-07-09T10:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if n, err := d.PublishSituationFeedItems(); err != nil || n != 1 {
		t.Fatalf("first publish: n=%d err=%v", n, err)
	}
	item, err := d.GetFeedItem("situation", "1")
	if err != nil || item == nil {
		t.Fatalf("GetFeedItem: %+v %v", item, err)
	}
	if item.EventTS != "2026-07-09T10:00:00Z" || item.Importance != 90 {
		t.Fatalf("unexpected item: %+v", item)
	}

	// User hides + sees the item; the situation then reranks (merge).
	if _, err := d.Exec(`UPDATE feed_items SET hidden_at='2026-07-09T11:00:00Z', seen_at='2026-07-09T11:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE situations SET priority='low', updated_at='2026-07-09T12:00:00Z' WHERE id=1`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.PublishSituationFeedItems(); err != nil {
		t.Fatal(err)
	}
	item, _ = d.GetFeedItem("situation", "1")
	if item.EventTS != "2026-07-09T12:00:00Z" || item.Importance != 30 {
		t.Fatalf("re-upsert should update event_ts/importance: %+v", item)
	}
	if item.HiddenAt == "" || item.SeenAt == "" {
		t.Fatalf("re-upsert must preserve hidden_at/seen_at: %+v", item)
	}

	// Idempotency: nothing changed → no rows touched.
	if n, err := d.PublishSituationFeedItems(); err != nil || n != 0 {
		t.Fatalf("no-op publish should touch 0 rows: n=%d err=%v", n, err)
	}
}
