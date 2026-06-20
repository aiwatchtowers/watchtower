package catchup

import (
	"context"
	"log"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGenerator returns canned output and records that it was called.
type mockGenerator struct {
	out    string
	called bool
	calls  int
}

func (m *mockGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	m.called = true
	m.calls++
	return m.out, &digest.Usage{}, "", nil
}

func newCfg() *config.Config {
	c := &config.Config{}
	c.Catchup.Caps = config.CatchupCaps{Digests: 40, Tracks: 20, Inbox: 30, Briefings: 5}
	return c
}

func testLogger() *log.Logger {
	return log.New(log.Writer(), "", 0)
}

func seedUnreadDigest(t *testing.T, d *db.DB) {
	t.Helper()
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 1, 2, 'channel', 'something happened', NULL)`); err != nil {
		t.Fatal(err)
	}
}

func TestCatchup10_RunCreatesSessionWithSkeletonThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{out: `{"themes":[
		{"title":"First theme","priority":"high","refs":[{"area":"digests","id":1,"label":"channel digest C1"}]},
		{"title":"Second theme","priority":"low","refs":[]}
	]}`}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !gen.called {
		t.Fatal("outline generator not called for non-empty backlog")
	}
	if sessionID == 0 {
		t.Fatal("expected a non-zero session id")
	}

	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.ID != sessionID {
		t.Fatalf("active session = %+v, want id %d", sess, sessionID)
	}
	if sess.TotalThemes != 2 {
		t.Fatalf("total_themes = %d, want 2", sess.TotalThemes)
	}

	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 2 {
		t.Fatalf("got %d themes, want 2", len(themes))
	}
	if themes[0].Title != "First theme" || themes[0].OrderIdx != 0 {
		t.Fatalf("theme[0] = %+v", themes[0])
	}
	if themes[1].Title != "Second theme" || themes[1].OrderIdx != 1 {
		t.Fatalf("theme[1] = %+v", themes[1])
	}
	if themes[0].Priority != "high" {
		t.Fatalf("theme[0] priority = %q, want high", themes[0].Priority)
	}
	// Refs round-trip from the outline JSON.
	refs, err := decodeRefs(themes[0].RefsJSON)
	if err != nil {
		t.Fatal(err)
	}
	if len(refs) != 1 || refs[0].Area != "digests" || refs[0].ID != 1 {
		t.Fatalf("theme[0] refs = %+v", refs)
	}
}

func TestCatchup11_ZeroUnreadCreatesNoSession(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := &mockGenerator{out: `{"themes":[]}`}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if gen.called {
		t.Fatal("generator must not be called when nothing is unread")
	}
	if sessionID != 0 {
		t.Fatalf("expected no session (0), got %d", sessionID)
	}
	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess != nil {
		t.Fatalf("expected no session created, got %+v", sess)
	}
}

func decodeRefs(raw string) ([]db.CatchupRef, error) {
	return parseRefs(raw)
}
