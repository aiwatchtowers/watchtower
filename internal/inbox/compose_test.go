package inbox

import (
	"context"
	"log"
	"strconv"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newComposePipeline creates a test DB seeded with a workspace + current user
// "U1", wired to a Pipeline backed by a seqGenerator, with Dashboard config
// set (mirrors newTriagePipeline).
func newComposePipeline(t *testing.T) (*db.DB, *Pipeline, *seqGenerator) {
	t.Helper()
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	cfg := testConfig()
	cfg.Dashboard.StaleAfterDays = config.DefaultDashboardStaleAfterDays
	cfg.Dashboard.MaxComposeSignals = config.DefaultDashboardMaxComposeSignals
	gen := &seqGenerator{}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")
	return d, p, gen
}

func TestCompose_CreatesSituationFromSignals(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "prod down")
	insertMessage(t, d, "C1", "2.1", "U2", "still down")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "prod down"})
	sig2 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "still down"})

	gen.responses = []string{`{"ops":[
		{"op":"create","title":"prod incident","kind":"external","priority":"high","rank":0.9,"reason":"prod is down","signals":["sig:` + strconv.FormatInt(sig1, 10) + `","sig:` + strconv.FormatInt(sig2, 10) + `"]}
	]}`}

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	assert.Equal(t, 0, merged)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1)
	s := open[0]
	assert.Equal(t, "prod incident", s.Title)
	assert.Equal(t, "external", s.Kind)
	assert.Equal(t, "high", s.Priority)
	assert.Equal(t, 0.9, s.Rank)
	assert.Equal(t, "prod is down", s.AIReason)

	members, err := d.ListSituationSignals(s.ID)
	require.NoError(t, err)
	assert.Len(t, members, 2)

	it1, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	it2, err := d.GetInboxItem(sig2)
	require.NoError(t, err)
	assert.NotEmpty(t, it1.ComposedAt)
	assert.NotEmpty(t, it2.ComposedAt)

	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	assert.Greater(t, ts, 0.0)
	_ = gen
}

func TestDash01_MergeIntoOpenSituation(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "release blocked")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release blocked"})
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig1)}))
	require.NoError(t, d.MarkSignalsComposed([]int{int(sig1)}))

	insertMessage(t, d, "C1", "2.1", "U2", "release still blocked")
	sig2 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release still blocked"})

	gen.responses = []string{`{"ops":[
		{"op":"merge","situation_id":` + strconv.FormatInt(sitID, 10) + `,"signals":["sig:` + strconv.FormatInt(sig2, 10) + `"],"rerank":0.8,"reason":"escalated"}
	]}`}

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 1, merged)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1, "must not create a duplicate situation")
	s := open[0]
	assert.Equal(t, int(sitID), s.ID)
	assert.Equal(t, "none", s.CardStatus, "card must be reset on merge")
	assert.Equal(t, 0.8, s.Rank)
	assert.Equal(t, "escalated", s.AIReason)

	members, err := d.ListSituationSignals(s.ID)
	require.NoError(t, err)
	assert.Len(t, members, 2)
}

func TestDash02_AIFailureTouchesNothing(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "release blocked")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release blocked"})

	gen.responses = []string{""} // simulates AI error

	_, _, err = p.runCompose(context.Background(), "U1")
	require.Error(t, err)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, 0.5, s.Rank)
	assert.Equal(t, "open", s.Status)
	assert.Equal(t, "none", s.CardStatus)

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.Empty(t, it.ComposedAt)

	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	assert.Equal(t, 0.0, ts)
}

func TestDash02_InvalidJSONTouchesNothing(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "release blocked")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release blocked"})

	gen.responses = []string{"not json"}

	_, _, err = p.runCompose(context.Background(), "U1")
	require.Error(t, err)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, 0.5, s.Rank)
	assert.Equal(t, "none", s.CardStatus)

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.Empty(t, it.ComposedAt)

	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	assert.Equal(t, 0.0, ts)
}

func TestCompose_EmptyInputSkipsAI(t *testing.T) {
	_, p, gen := newComposePipeline(t)

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 0, merged)
	assert.Equal(t, 0, gen.calls)
}

func TestCompose_HallucinatedKeysSkipped(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "some noise")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "some noise"})

	// Op references only a hallucinated signal id (9999); the real sig1 isn't
	// referenced by any op at all (AI chose not to use it), but its presence
	// in the input is what makes this cycle non-empty and still gets marked
	// composed once the pass succeeds.
	gen.responses = []string{`{"ops":[
		{"op":"create","title":"phantom theme","kind":"external","priority":"medium","rank":0.4,"reason":"ghost","signals":["sig:9999"]}
	]}`}

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	assert.Equal(t, 0, merged)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1)
	members, err := d.ListSituationSignals(open[0].ID)
	require.NoError(t, err)
	assert.Empty(t, members, "hallucinated sig id must not become a member link")

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.NotEmpty(t, it.ComposedAt, "the real signal was still sent this cycle and must be marked composed")
	_ = gen
}

func TestCompose_AutoClosePreStep(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "release blocked")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release blocked"})
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig1)}))
	require.NoError(t, d.MarkSignalsComposed([]int{int(sig1)}))
	// Resolve the only member signal so the situation qualifies for auto-close.
	require.NoError(t, d.ResolveInboxItem(int(sig1), "handled"))

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 0, merged)
	assert.Equal(t, 0, gen.calls, "auto-close is deterministic, no AI call needed")

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "done", s.Status)
	assert.Equal(t, "signals_resolved", s.ResolvedReason)
}

func TestCompose_MutedSignalsExcludedButMarked(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "muted noise")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "muted noise"})
	require.NoError(t, d.UpsertLearnedRule(db.InboxLearnedRule{
		Source:   "user_rule",
		RuleType: "source_mute",
		ScopeKey: "channel:C1",
		Weight:   -1.0,
	}))

	created, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 0, merged)
	assert.Equal(t, 0, gen.calls)

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.NotEmpty(t, it.ComposedAt, "muted signals must still be marked composed so they don't pile up")
}
