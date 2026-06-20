package catchup

import (
	"context"
	"log"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGenerator returns canned output and records that it was called. When fn is
// set it is used to compute the response from the (system, user) messages so a
// test can return different output for the outline vs expand passes (or for a
// regen correction); otherwise the static out is returned.
type mockGenerator struct {
	out    string
	fn     func(system, user string) string
	called bool
	calls  int
	mu     sync.Mutex
}

func (m *mockGenerator) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	m.mu.Lock()
	m.called = true
	m.calls++
	fn := m.fn
	out := m.out
	m.mu.Unlock()
	if fn != nil {
		out = fn(system, user)
	}
	return out, &digest.Usage{}, "", nil
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

func TestCatchup12_OutlineInjectsLearnedPreferences(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	// A catchup-pipeline rule derived from prior feedback must reach the prompt,
	// otherwise the learning loop is write-only.
	if err := d.UpsertLearnedRule(db.InboxLearnedRule{
		Pipeline: "catchup", RuleType: "source_mute",
		ScopeKey: "catchup:topic:standup-noise", Weight: -1.0,
		Source: "explicit_feedback", EvidenceCount: 1,
	}); err != nil {
		t.Fatal(err)
	}

	var outlineUser string
	gen := &mockGenerator{fn: func(system, user string) string {
		if system == outlineSystemPrompt {
			outlineUser = user
			return twoThemeOutline
		}
		return `{"narrative":"x","priority":"low","needs_you":false,"suggested_action":""}`
	}}
	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(outlineUser, "LEARNED PREFERENCES") {
		t.Fatalf("outline prompt missing preferences header; got:\n%s", outlineUser)
	}
	if !strings.Contains(outlineUser, "catchup:topic:standup-noise") {
		t.Fatalf("outline prompt missing learned rule scope; got:\n%s", outlineUser)
	}
}

func TestCatchup24_AcknowledgeReviewedCountIsIdempotent(t *testing.T) {
	d := db.OpenTestDB(t)
	sid, err := d.CreateCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	tid, err := d.InsertCatchupTheme(db.CatchupTheme{
		SessionID: sid, Title: "T", Priority: "medium", RefsJSON: "[]", GenState: "ready",
	})
	if err != nil {
		t.Fatal(err)
	}

	p := New(d, newCfg(), &mockGenerator{}, testLogger())
	if err := p.Acknowledge(tid); err != nil {
		t.Fatal(err)
	}
	if err := p.Acknowledge(tid); err != nil {
		t.Fatal(err)
	}

	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.ReviewedCount != 1 {
		t.Fatalf("reviewed_count = %v, want 1 (re-ack must not double-count)", sess)
	}
}

func TestCatchup25_RegenThemePropagatesExpandFailure(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	// Outline succeeds; every expand returns garbage so it fails to parse.
	gen := &mockGenerator{fn: func(system, _ string) string {
		if system == outlineSystemPrompt {
			return twoThemeOutline
		}
		return "not json at all"
	}}
	p := New(d, newCfg(), gen, testLogger())
	sessionID, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	// A user-initiated regen must surface the failure, not report success.
	if err := p.RegenTheme(context.Background(), themes[0].ID, "fix it"); err == nil {
		t.Fatal("RegenTheme must return an error when the expand call fails")
	}
}

// twoThemeOutline is an outline JSON with two themes, each referencing the one
// seeded digest so expand has a source record to work from.
const twoThemeOutline = `{"themes":[
	{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]},
	{"title":"Beta","priority":"low","refs":[{"area":"digests","id":1,"label":"d1"}]}
]}`

func TestCatchup20_ExpandFillsNarrativesAndActivatesSession(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{fn: func(system, _ string) string {
		if system == outlineSystemPrompt {
			return twoThemeOutline
		}
		return `{"narrative":"expanded story","priority":"high","needs_you":true,"suggested_action":"reply soon"}`
	}}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 2 {
		t.Fatalf("got %d themes, want 2", len(themes))
	}
	for _, th := range themes {
		if th.GenState != "ready" {
			t.Fatalf("theme %d gen_state = %q, want ready", th.ID, th.GenState)
		}
		if th.Narrative != "expanded story" {
			t.Fatalf("theme %d narrative = %q, want expanded story", th.ID, th.Narrative)
		}
		if th.Priority != "high" {
			t.Fatalf("theme %d priority = %q, want high", th.ID, th.Priority)
		}
		if !th.NeedsYou {
			t.Fatalf("theme %d needs_you = false, want true", th.ID)
		}
		if th.SuggestedAction != "reply soon" {
			t.Fatalf("theme %d suggested_action = %q", th.ID, th.SuggestedAction)
		}
	}

	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.Status != "active" {
		t.Fatalf("session = %+v, want status active", sess)
	}
}

func TestCatchup21_PerThemeExpandFailureDoesNotFailRun(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	var expandCalls int
	gen := &mockGenerator{}
	gen.fn = func(system, _ string) string {
		if system == outlineSystemPrompt {
			return twoThemeOutline
		}
		gen.mu.Lock()
		expandCalls++
		n := expandCalls
		gen.mu.Unlock()
		// First expand call returns garbage (parse failure) → that theme fails.
		if n == 1 {
			return "not json at all"
		}
		return `{"narrative":"good story","priority":"medium","needs_you":false,"suggested_action":""}`
	}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatalf("Run must not fail on a per-theme expand error: %v", err)
	}

	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	var failed, ready int
	for _, th := range themes {
		switch th.GenState {
		case "failed":
			failed++
		case "ready":
			ready++
		}
	}
	if failed != 1 || ready != 1 {
		t.Fatalf("got failed=%d ready=%d, want 1 and 1 (themes=%+v)", failed, ready, themes)
	}

	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.Status != "active" {
		t.Fatalf("session = %+v, want status active", sess)
	}
}

func TestCatchup22_RegenThemeOverwritesNarrativeWithCorrection(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{fn: func(system, user string) string {
		if system == outlineSystemPrompt {
			return twoThemeOutline
		}
		if strings.Contains(user, "OPERATOR CORRECTION") {
			return `{"narrative":"corrected story","priority":"low","needs_you":false,"suggested_action":"none"}`
		}
		return `{"narrative":"original story","priority":"high","needs_you":true,"suggested_action":"reply"}`
	}}

	p := New(d, newCfg(), gen, testLogger())
	sessionID, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) == 0 {
		t.Fatal("no themes produced")
	}
	target := themes[0]
	other := themes[1]
	if target.Narrative != "original story" {
		t.Fatalf("pre-regen narrative = %q, want original story", target.Narrative)
	}

	if err := p.RegenTheme(context.Background(), target.ID, "be more concise"); err != nil {
		t.Fatal(err)
	}

	got, err := d.GetCatchupTheme(target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Narrative != "corrected story" {
		t.Fatalf("post-regen narrative = %q, want corrected story", got.Narrative)
	}
	if got.GenState != "ready" {
		t.Fatalf("post-regen gen_state = %q, want ready", got.GenState)
	}
	if got.ReviewState != "pending" {
		t.Fatalf("post-regen review_state = %q, want pending (preserved)", got.ReviewState)
	}

	// The other theme is untouched by a targeted regen.
	otherGot, err := d.GetCatchupTheme(other.ID)
	if err != nil {
		t.Fatal(err)
	}
	if otherGot.Narrative != "original story" {
		t.Fatalf("other theme narrative = %q, want original story (untouched)", otherGot.Narrative)
	}
}
