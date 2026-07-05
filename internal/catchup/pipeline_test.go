package catchup

import (
	"context"
	"log"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
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

// seedDigestPeriod hands out a unique period per seeded digest so repeated calls
// in one test do not collide on the (channel_id, type, period_from, period_to)
// UNIQUE constraint. Ids still autoincrement from 1 within each fresh test DB.
var seedDigestPeriod atomic.Int64

func seedUnreadDigest(t *testing.T, d *db.DB) {
	t.Helper()
	n := seedDigestPeriod.Add(1)
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', ?, ?, 'channel', 'something happened', NULL)`, n, n+1); err != nil {
		t.Fatal(err)
	}
}

// expandOK is a generic successful expand response for tests that do not assert
// on narrative content. It omits priority so the skeleton priority is preserved
// (normalizePriority falls back to the theme's value on an empty string).
const expandOK = `{"narrative":"x","needs_you":false,"suggested_action":""}`

// peelScript returns a mock fn that emits the given theme JSONs one per peel
// round (in order) and then {"done":true}; every non-peel (expand) call returns
// the supplied expand JSON. Round counting is safe because the peel loop is
// sequential and expand calls take the else branch.
func peelScript(expand string, themesJSON ...string) func(system, user string) string {
	round := 0
	return func(system, _ string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			i := round
			round++
			if i < len(themesJSON) {
				return themesJSON[i]
			}
			return `{"done":true}`
		}
		return expand
	}
}

func TestCatchup10_RunCreatesSessionWithSkeletonThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	gen := &mockGenerator{fn: peelScript(expandOK,
		`{"theme":{"title":"First theme","priority":"high","refs":[{"area":"digests","id":1,"label":"channel digest C1"}]}}`,
		`{"theme":{"title":"Second theme","priority":"low","refs":[{"area":"digests","id":2,"label":"d2"}]}}`,
	)}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !gen.called {
		t.Fatal("peel generator not called for non-empty backlog")
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

func TestCatchup12_PeelInjectsLearnedPreferences(t *testing.T) {
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

	var peelUser string
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			peelUser = user
			return `{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`
		}
		return expandOK
	}}
	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(peelUser, "LEARNED PREFERENCES") {
		t.Fatalf("peel prompt missing preferences header; got:\n%s", peelUser)
	}
	if !strings.Contains(peelUser, "catchup:topic:standup-noise") {
		t.Fatalf("peel prompt missing learned rule scope; got:\n%s", peelUser)
	}
}

// TestCatchup13_PromptsCarryLanguageDirective enforces the architectural
// invariant that every operator-facing catch-up AI call (outline + expand)
// carries the workspace language directive. Without it the model silently
// answers in English regardless of the configured digest.language.
func TestCatchup13_PromptsCarryLanguageDirective(t *testing.T) {
	// BEHAVIOR CATCHUP-02 — see docs/inventory/catchup.md
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)

	cfg := newCfg()
	cfg.Digest.Language = "Ukrainian"

	var mu sync.Mutex
	var systems []string
	peelRound := 0
	gen := &mockGenerator{fn: func(system, _ string) string {
		mu.Lock()
		systems = append(systems, system)
		mu.Unlock()
		if strings.HasPrefix(system, peelSystemPrompt) {
			mu.Lock()
			i := peelRound
			peelRound++
			mu.Unlock()
			if i == 0 {
				return `{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`
			}
			return `{"done":true}`
		}
		return expandOK
	}}
	if _, err := New(d, cfg, gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(systems) == 0 {
		t.Fatal("no AI calls captured")
	}
	var sawPeel bool
	for _, s := range systems {
		if strings.HasPrefix(s, peelSystemPrompt) {
			sawPeel = true
		}
		if !prompts.HasDirective(s) {
			t.Fatalf("catch-up system prompt missing language directive:\n%s", s)
		}
		if !strings.Contains(s, "Ukrainian") {
			t.Fatalf("catch-up system prompt does not honour configured language:\n%s", s)
		}
	}
	// The peel prompt specifically must carry the directive (CATCHUP-02): it is
	// the call that regressed to English before this invariant was pinned.
	if !sawPeel {
		t.Fatal("expected at least one peel-prompt AI call carrying the language directive")
	}
}

// TestCatchup14_AcknowledgeMarksDigestDecisionsRead locks the end-to-end
// behaviour that reviewing a catch-up theme clears the decisions of its source
// digests, not just the digests themselves — otherwise decisions seen via
// catch-up linger in the Decisions feed's unread count.
func TestCatchup14_AcknowledgeMarksDigestDecisionsRead(t *testing.T) {
	// BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
	d := db.OpenTestDB(t)

	digestID, err := d.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: 1, PeriodTo: 2,
		Summary:   "s",
		Decisions: `[{"text":"a"},{"text":"b"}]`,
	})
	if err != nil {
		t.Fatal(err)
	}

	sid, err := d.CreateCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	themeID, err := d.InsertCatchupTheme(db.CatchupTheme{
		SessionID: sid, Title: "T", Priority: "high", GenState: "ready",
		RefsJSON: `[{"area":"digests","id":` + strconv.FormatInt(digestID, 10) + `,"label":"x"}]`,
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := New(d, newCfg(), &mockGenerator{}, testLogger()).Acknowledge(themeID); err != nil {
		t.Fatal(err)
	}

	var read int
	if err := d.QueryRow(`SELECT COUNT(*) FROM decision_reads WHERE digest_id = ?`, digestID).Scan(&read); err != nil {
		t.Fatal(err)
	}
	if read != 2 {
		t.Fatalf("decision_reads for digest = %d, want 2 (both decisions read via catch-up ack)", read)
	}
}

func TestCatchup24_AcknowledgeReviewedCountIsIdempotent(t *testing.T) {
	// BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
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
	// Peel produces a theme; every expand returns garbage so it fails to parse.
	gen := &mockGenerator{fn: peelScript("not json at all",
		`{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`,
	)}
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

// twoDigestThemes is a peel script yielding two themes (Alpha, Beta), each
// referencing a distinct seeded digest, then done. Callers seed two digests.
func twoDigestThemes(expand string) func(system, user string) string {
	return peelScript(expand,
		`{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`,
		`{"theme":{"title":"Beta","priority":"low","refs":[{"area":"digests","id":2,"label":"d2"}]}}`,
	)
}

func TestCatchup20_ExpandFillsNarrativesAndActivatesSession(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	gen := &mockGenerator{fn: twoDigestThemes(
		`{"narrative":"expanded story","priority":"high","needs_you":true,"suggested_action":"reply soon"}`,
	)}

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
	// BEHAVIOR CATCHUP-03 — see docs/inventory/catchup.md
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	var expandCalls, peelRound int
	gen := &mockGenerator{}
	gen.fn = func(system, _ string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			// peel is sequential, so peelRound needs no lock.
			r := peelRound
			peelRound++
			switch r {
			case 0:
				return `{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`
			case 1:
				return `{"theme":{"title":"Beta","priority":"low","refs":[{"area":"digests","id":2,"label":"d2"}]}}`
			default:
				return `{"done":true}`
			}
		}
		gen.mu.Lock()
		expandCalls++
		n := expandCalls
		gen.mu.Unlock()
		// The first expand call returns garbage (parse failure) → that theme fails;
		// the other still expands. Which theme fails is non-deterministic (expands
		// run concurrently) but exactly one of two does.
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
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	peelRound := 0
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			r := peelRound
			peelRound++
			switch r {
			case 0:
				return `{"theme":{"title":"Alpha","priority":"high","refs":[{"area":"digests","id":1,"label":"d1"}]}}`
			case 1:
				return `{"theme":{"title":"Beta","priority":"low","refs":[{"area":"digests","id":2,"label":"d2"}]}}`
			default:
				return `{"done":true}`
			}
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

// TestCatchup26_PeelExtractsMoreThanEightThemes proves the old 3–8 ceiling is
// gone: ten unread digests, each its own theme, all ten survive.
func TestCatchup26_PeelExtractsMoreThanEightThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	for i := 0; i < 10; i++ {
		seedUnreadDigest(t, d) // ids 1..10
	}
	themesJSON := make([]string, 10)
	for i := 0; i < 10; i++ {
		themesJSON[i] = `{"theme":{"title":"T` + strconv.Itoa(i+1) +
			`","priority":"medium","refs":[{"area":"digests","id":` + strconv.Itoa(i+1) + `}]}}`
	}
	gen := &mockGenerator{fn: peelScript(expandOK, themesJSON...)}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 10 {
		t.Fatalf("got %d themes, want 10 (no artificial ceiling)", len(themes))
	}
}

// TestCatchup27_DoneMarksLeftoverRead — when the model signals done with items
// still in the pool, those leftover items are marked read (noise auto-clear).
func TestCatchup27_DoneMarksLeftoverRead(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1 -> themed
	seedUnreadDigest(t, d) // id=2 -> leftover noise
	gen := &mockGenerator{fn: peelScript(expandOK,
		`{"theme":{"title":"Only one","priority":"high","refs":[{"area":"digests","id":1}]}}`,
	)}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	// digest id=2 was never themed; a clean (done) exit must mark it read.
	var leftoverRead int
	if err := d.QueryRow(`SELECT COUNT(*) FROM digests WHERE id = 2 AND read_at IS NOT NULL`).Scan(&leftoverRead); err != nil {
		t.Fatal(err)
	}
	if leftoverRead != 1 {
		t.Fatal("leftover digest id=2 should be marked read after a done exit")
	}
	// The themed digest id=1 stays unread — it is cleared only when the operator
	// acknowledges its theme.
	var themedUnread int
	if err := d.QueryRow(`SELECT COUNT(*) FROM digests WHERE id = 1 AND read_at IS NULL`).Scan(&themedUnread); err != nil {
		t.Fatal(err)
	}
	if themedUnread != 1 {
		t.Fatal("themed digest id=1 should stay unread until its theme is acknowledged")
	}
}

// TestCatchup28_SafetyCapLeavesLeftoverUnread — if the loop never sees done and
// hits the round cap, leftover stays unread (unprocessed, not noise).
func TestCatchup28_SafetyCapLeavesLeftoverUnread(t *testing.T) {
	d := db.OpenTestDB(t)
	// Seed more digests than the cap; the script claims one fresh id per round and
	// never says done, so the cap stops the loop with items still unclaimed.
	n := maxPeelRounds + 5
	for i := 0; i < n; i++ {
		seedUnreadDigest(t, d)
	}
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			id := firstID(user)
			return `{"theme":{"title":"t","priority":"low","refs":[{"area":"digests","id":` + strconv.Itoa(id) + `}]}}`
		}
		return expandOK
	}}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	// A safety-cap exit marks nothing read: every seeded digest stays unread
	// (the themed ones await ack, the unclaimed leftover is untouched).
	_, total, err := d.GetUnreadDigests(200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total != n {
		t.Fatalf("unread digests after safety-cap exit = %d, want %d (nothing marked read)", total, n)
	}
}

// firstID returns the first [id=N] in a peel user message.
func firstID(user string) int {
	const marker = "[id="
	i := strings.Index(user, marker)
	if i < 0 {
		return 0
	}
	rest := user[i+len(marker):]
	j := strings.IndexByte(rest, ']')
	if j < 0 {
		return 0
	}
	n, _ := strconv.Atoi(rest[:j])
	return n
}

// TestCatchup29_MidLoopPeelErrorKeepsEarlierThemes — a parse failure on round 2
// keeps round 1's theme and leaves the session usable (not failed). Leftover is
// NOT marked read on an error exit.
func TestCatchup29_MidLoopPeelErrorKeepsEarlierThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	peelRound := 0
	gen := &mockGenerator{fn: func(system, _ string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			peelRound++
			if peelRound == 1 {
				return `{"theme":{"title":"Kept","priority":"high","refs":[{"area":"digests","id":1}]}}`
			}
			return `not json at all` // round 2 fails -> stop, keep theme 1
		}
		return expandOK
	}}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatalf("partial peel must not fail Run: %v", err)
	}
	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.ID != sessionID {
		t.Fatalf("expected an active session, got %+v", sess)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 1 || themes[0].Title != "Kept" {
		t.Fatalf("themes = %+v, want one 'Kept'", themes)
	}
	// leftover (id=2) NOT marked read on an error exit.
	_, total, err := d.GetUnreadDigests(40, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total == 0 {
		t.Fatal("leftover should remain unread on error exit")
	}
}

// TestCatchup34_DegenerateRoundDoesNotClearUnthemedPool — a peel round that
// returns valid-but-degenerate JSON (a parseable object that is neither a theme
// nor done, e.g. `{}`) must NOT be treated as a clean "all noise" signal: with
// zero themes produced, the whole gathered pool must stay unread. Guards the
// data-loss path where a degenerate light-model response silently marked the
// operator's entire backlog read.
func TestCatchup34_DegenerateRoundDoesNotClearUnthemedPool(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	// Round 0 returns a parseable object with neither theme nor done.
	gen := &mockGenerator{fn: peelScript(expandOK, `{}`)}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, total, err := d.GetUnreadDigests(40, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total != 2 {
		t.Fatalf("degenerate round produced zero themes; pool must stay unread, got unread=%d want 2", total)
	}
}

// TestCatchup35_AllInvalidRefsDoesNotClearPool — a theme whose refs are all
// unknown ids (model misfire) yields len(refs)==0; that must stop WITHOUT
// clearing the leftover, not silently mark the whole pool read.
func TestCatchup35_AllInvalidRefsDoesNotClearPool(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	// Round 0 returns a theme referencing a nonexistent id only.
	gen := &mockGenerator{fn: peelScript(expandOK,
		`{"theme":{"title":"Bogus","priority":"high","refs":[{"area":"digests","id":999}]}}`,
	)}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 0 {
		t.Fatalf("a theme with no valid refs must not be persisted; got %d themes", len(themes))
	}
	_, total, err := d.GetUnreadDigests(40, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total != 2 {
		t.Fatalf("all-invalid-refs misfire must not clear the pool; got unread=%d want 2", total)
	}
}

// TestCatchup33_ZeroThemesWithErrorFailsSession — the first peel round errors
// before any theme is found => the session is marked failed (no active session).
func TestCatchup33_ZeroThemesWithErrorFailsSession(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{fn: func(system, _ string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			return `totally broken` // round 1 unparseable, zero themes so far
		}
		return expandOK
	}}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err == nil {
		t.Fatal("expected error when the first peel round fails with zero themes")
	}
	// A failed session is not active.
	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess != nil {
		t.Fatalf("expected no active session (failed), got %+v", sess)
	}
}
