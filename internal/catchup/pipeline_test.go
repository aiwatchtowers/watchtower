package catchup

import (
	"context"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGenerator returns canned output and records that it was called.
type mockGenerator struct {
	out    string
	called bool
}

func (m *mockGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	m.called = true
	return m.out, &digest.Usage{}, "", nil
}

func newCfg() *config.Config {
	c := &config.Config{}
	c.Catchup.Caps = config.CatchupCaps{Digests: 40, Tracks: 20, Inbox: 30, Briefings: 5}
	return c
}

func seedUnreadDigest(t *testing.T, d *db.DB) {
	t.Helper()
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 1, 2, 'channel', 'something happened', NULL)`); err != nil {
		t.Fatal(err)
	}
}

func TestCatchup10_RunBuildsStoriesAndSections(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{out: `{"tldr":"You missed one thing.","stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true,"refs":[{"area":"digests","id":1,"label":"x"}]}]}`}

	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !gen.called {
		t.Fatal("generator not called for non-empty backlog")
	}
	if res.TLDR != "You missed one thing." {
		t.Fatalf("tldr = %q", res.TLDR)
	}
	if len(res.Stories) != 1 || res.Stories[0].Title != "S" {
		t.Fatalf("stories = %+v", res.Stories)
	}
	if res.Counts.TotalUnread != 1 {
		t.Fatalf("total unread = %d, want 1", res.Counts.TotalUnread)
	}
	// Sections come from the DB, not the model.
	if got := sectionItems(res, "digests"); len(got) != 1 || got[0].ID != 1 {
		t.Fatalf("digest section = %+v", got)
	}
}

func TestCatchup11_ZeroUnreadSkipsAI(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := &mockGenerator{out: `{"tldr":"x"}`}
	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if gen.called {
		t.Fatal("generator must not be called when nothing is unread")
	}
	if res.Counts.TotalUnread != 0 || len(res.Stories) != 0 {
		t.Fatalf("expected empty result, got %+v", res)
	}
}

func TestCatchup12_AIFailureFallsBackToSections(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{out: `not json at all`}
	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatalf("fallback must not error: %v", err)
	}
	if len(res.Stories) != 0 {
		t.Fatal("expected no stories on parse failure")
	}
	if sec := sectionItems(res, "digests"); len(sec) != 1 {
		t.Fatalf("sections must still populate on AI failure, got %+v", sec)
	}
}

func sectionItems(r *Result, area string) []SectionItem {
	for _, s := range r.Sections {
		if s.Area == area {
			return s.Items
		}
	}
	return nil
}
