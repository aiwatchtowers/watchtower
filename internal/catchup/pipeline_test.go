package catchup

import (
	"context"
	"encoding/json"
	"strings"
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

// TestCatchup13_EmptyStateMarshalsArraysNotNull guards the Go↔Swift wire
// contract: empty slices must serialize as [] not null, or the non-optional
// Swift decoder throws "Failed to parse catch-up".
func TestCatchup13_EmptyStateMarshalsArraysNotNull(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := &mockGenerator{out: `{"tldr":"x"}`}
	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, bad := range []string{`"stories":null`, `"sections":null`, `"items":null`} {
		if strings.Contains(s, bad) {
			t.Fatalf("marshaled empty-state result contains %s — breaks Swift decode: %s", bad, s)
		}
	}
}

// TestCatchup14_TruncatedAndCounts asserts cap truncation is reported honestly.
func TestCatchup14_TruncatedAndCounts(t *testing.T) {
	d := db.OpenTestDB(t)
	for i := 0; i < 3; i++ {
		if _, err := d.Exec(
			`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
			 VALUES ('C1', ?, ?, 'channel', 'x', NULL)`, float64(i), float64(i+1)); err != nil {
			t.Fatal(err)
		}
	}
	cfg := &config.Config{}
	cfg.Catchup.Caps = config.CatchupCaps{Digests: 1, Tracks: 20, Inbox: 30, Briefings: 5}
	gen := &mockGenerator{out: `{"tldr":"x","stories":[]}`}

	res, err := New(d, cfg, gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Truncated {
		t.Fatal("expected Truncated=true (3 digests, cap 1)")
	}
	if res.Counts.Digests.Included != 1 || res.Counts.Digests.Total != 3 {
		t.Fatalf("digests count = %+v, want {Included:1, Total:3}", res.Counts.Digests)
	}
	if res.Counts.TotalUnread != 3 {
		t.Fatalf("total unread = %d, want 3", res.Counts.TotalUnread)
	}
}

// TestCatchup15_ParseFenceStripping covers the markdown-fence path parseAIOutput exists for.
func TestCatchup15_ParseFenceStripping(t *testing.T) {
	raw := "```json\n{\"tldr\":\"hi\",\"stories\":[]}\n```"
	out, err := parseAIOutput(raw)
	if err != nil {
		t.Fatalf("fence-wrapped JSON must parse: %v", err)
	}
	if out.TLDR != "hi" {
		t.Fatalf("tldr = %q, want hi", out.TLDR)
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
