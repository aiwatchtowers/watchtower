package inbox

import (
	"context"
	"log"
	"strconv"
	"testing"
	"time"

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

// Thread-follow: a signal already composed into a situation gets a thread
// update (fold clears composed_at) → the next compose cycle re-feeds it and
// the AI's merge back into the SAME situation is idempotent: no duplicate
// situation_signals row, card invalidated, updated_at bumped.
func TestDash01_ThreadFollowRefeedMergesIdempotently(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "release blocked")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "release blocked"})
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig1)}))
	require.NoError(t, d.MarkSignalsComposed([]int{int(sig1)}))

	// Thread-fold: a newer message in the same thread updates the existing
	// item and clears composed_at, re-entering the composer's queue.
	require.NoError(t, d.UpdateInboxItemSnippet(int(sig1), "1.2", "U2", "release still blocked", "", "release still blocked", ""))

	gen.responses = []string{`{"ops":[
		{"op":"merge","situation_id":` + strconv.FormatInt(sitID, 10) + `,"signals":["sig:` + strconv.FormatInt(sig1, 10) + `"],"reason":"thread update"}
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
	assert.Equal(t, "none", s.CardStatus, "card must be invalidated on re-merge")
	assert.Equal(t, "thread update", s.AIReason)

	var linkCount int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM situation_signals WHERE situation_id = ? AND inbox_item_id = ?`, sitID, sig1).Scan(&linkCount))
	assert.Equal(t, 1, linkCount, "re-linking the same signal must be a no-op (INSERT OR IGNORE), not a duplicate")

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.NotEmpty(t, it.ComposedAt, "re-fed signal must be marked composed again")
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

func TestCompose_PromptResolvesSenderName(t *testing.T) {
	// The new-material block must feed the sender's display name, not the raw
	// Slack user ID — the composer copies IDs straight into situation titles
	// and reasons otherwise.
	d, p, gen := newComposePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U2", Name: "anton", DisplayName: "Anton Makarenko"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "prod down")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "prod down"})
	gen.responses = []string{`{"ops":[]}`}

	_, _, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	require.Len(t, gen.prompts, 1)
	assert.Contains(t, gen.prompts[0], "from=Anton Makarenko")
	assert.NotContains(t, gen.prompts[0], "from=U2")
}

func TestCompose_PromptResolvesMentionInSignalSnippet(t *testing.T) {
	// Snippets stored before enrichment (or from paths that kept raw markup)
	// may still carry `<@U…>` mentions — the prompt build must resolve them
	// via the DB instead of dropping them.
	d, p, gen := newComposePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "see <@U3> for status")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "see <@U3> for status"})
	gen.responses = []string{`{"ops":[]}`}

	_, _, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	require.Len(t, gen.prompts, 1)
	assert.Contains(t, gen.prompts[0], "see @Bob Brown for status")
}

func TestCompose_OpenSituationSnippetResolvesMention(t *testing.T) {
	// The open-situations block renders member snippets — raw mentions there
	// must resolve to names too.
	d, p, gen := newComposePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "<@U3> escalated this")
	member := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "<@U3> escalated this"})
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "escalation", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "reason"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(member)}))
	require.NoError(t, d.MarkSignalsComposed([]int{int(member)}))
	// A fresh pending signal makes the cycle non-empty so the AI is invoked.
	insertMessage(t, d, "C1", "2.1", "U2", "new signal")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "new signal"})
	gen.responses = []string{`{"ops":[]}`}

	_, _, err = p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	require.Len(t, gen.prompts, 1)
	assert.Contains(t, gen.prompts[0], "@Bob Brown escalated this")
}

func TestTrackTitle_ResolvesMention(t *testing.T) {
	d := newTestDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	res, err := d.Exec(`INSERT INTO tracks (text) VALUES (?)`, "review <@U3> proposal")
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)

	assert.Equal(t, "review @Bob Brown proposal", trackTitle(d, int(id)))
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

// TestDash02_PartialApplyRollsBackEverything pins DASH-02's all-or-nothing
// contract at the point where it was previously violated: a genuine DB error
// partway through the apply loop, after at least one earlier op has already
// written to the DB. Before the fix, applyComposeOps ran each op as its own
// auto-committed write, so the first "create" would survive even though the
// second failed — leaving a half-composed pass (a persisted situation, plus
// signals/watermark still frozen because the failure happened before
// MarkSignalsComposed/SetComposeLastRunTS). applyComposeAndAdvance now wraps
// the whole block in one transaction, so nothing from a failed pass survives.
//
// The second op's signal id (99999) is a fabricated entry in validSigIDs that
// doesn't correspond to a real inbox_items row — real compose cycles can
// never construct such a map (validSigIDs is always built from rows that were
// actually fetched), but injecting it here is the deterministic way to force
// a genuine DB-layer failure (a foreign key violation on situation_signals)
// partway through the loop, exactly where an arbitrary DB error would land
// in production.
func TestDash02_PartialApplyRollsBackEverything(t *testing.T) {
	d, _, _ := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "real signal")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "real signal"})

	baselineID, err := d.CreateSituation(db.DashboardSituation{Title: "pre-existing baseline", Kind: "external", Priority: "medium", Rank: 0.3})
	require.NoError(t, err)

	ops := []composeOp{
		{Op: "create", Title: "first op succeeds in-tx", Kind: "external", Priority: "high", Rank: 0.7, Reason: "x",
			Signals: []string{"sig:" + strconv.FormatInt(sig1, 10)}},
		{Op: "create", Title: "second op fails mid-apply", Kind: "external", Priority: "medium", Rank: 0.5, Reason: "y",
			Signals: []string{"sig:99999"}}, // 99999: fabricated, no backing inbox_items row (see doc comment above)
	}
	validSigIDs := map[int]bool{int(sig1): true, 99999: true}
	openByID := map[int]db.DashboardSituation{}
	allIDs := []int{int(sig1)}

	_, _, err = applyComposeAndAdvance(d, ops, validSigIDs, openByID, allIDs, float64(time.Now().Unix()))
	require.Error(t, err, "the fabricated FK violation on the second op must surface as a genuine DB error")

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1, "only the pre-existing baseline situation must remain — neither op's situation may survive")
	assert.Equal(t, int(baselineID), open[0].ID)

	it, err := d.GetInboxItem(sig1)
	require.NoError(t, err)
	assert.Empty(t, it.ComposedAt, "the real signal must not be marked composed after a rolled-back pass")

	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	assert.Equal(t, 0.0, ts, "the watermark must stay frozen after a rolled-back pass")
}

// TestCompose_FreshWatermarkUsesLookbackFloor guards the first compose pass on
// an existing DB: runCompose used to derive sinceISO straight from the raw
// compose watermark (GetComposeLastRunTS), which returns 0 on a fresh
// install/first run. time.Unix(0,0) is the 1970 epoch, so ListTrackEventsSince
// and ListTargetsUpdatedSince would return the entire backfilled history
// instead of only recent material — the same bug class as the inbox/triage
// fresh-watermark issue (see TestTriage_FreshWatermarkUsesLookbackFloor). This
// seeds one track event far outside the lookback window and one inside it,
// and asserts the compose prompt only ever contains the recent one.
func TestCompose_FreshWatermarkUsesLookbackFloor(t *testing.T) {
	d, p, gen := newComposePipeline(t)

	trackID, err := d.UpsertTrack(db.Track{Text: "ongoing track", Priority: "medium"})
	require.NoError(t, err)

	// Old event inserted via raw SQL with an explicit past created_at, since
	// InsertTrackEvent always defaults created_at=now (mirrors
	// TestListTrackEventsSince_OnlyNewAndNonDismissed in internal/db).
	oldTS := time.Now().AddDate(0, 0, -30).UTC().Format("2006-01-02T15:04:05Z")
	_, err = d.Exec(`INSERT INTO track_events (track_id, summary, source_type, source_id, created_at)
		VALUES (?, ?, ?, ?, ?)`, trackID, "ancient track event from a month ago", "test", "1", oldTS)
	require.NoError(t, err)

	_, err = d.InsertTrackEvent(db.TrackEvent{TrackID: int(trackID), Summary: "recent track event needs a look", SourceType: "test", SourceID: "2"})
	require.NoError(t, err)

	gen.responses = []string{`{"ops":[]}`}

	_, _, err = p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	require.Len(t, gen.prompts, 1, "expected exactly one compose AI call for this small fixture")
	prompt := gen.prompts[0]
	assert.Contains(t, prompt, "recent track event needs a look",
		"the recent track event must be inside the lookback-floored compose window")
	assert.NotContains(t, prompt, "ancient track event from a month ago",
		"a fresh compose watermark must be floored to now-lookbackDays, not pull the entire backfilled history")
}

// DASH-07: suggest_resolve sets the mark and reason but NEVER changes status.
func TestDash07_SuggestResolveSetsMarkNeverStatus(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)

	insertMessage(t, d, "C1", "1.1", "U2", "thread answered")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "thread answered"})

	gen.responses = []string{`{"ops":[
		{"op":"merge","situation_id":` + strconv.FormatInt(sitID, 10) + `,"signals":["sig:` + strconv.FormatInt(sig1, 10) + `"]},
		{"op":"suggest_resolve","situation_id":` + strconv.FormatInt(sitID, 10) + `,"reason":"answered in thread"}
	]}`}

	_, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, merged)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "answered in thread", s.SuggestedResolution)
	assert.Equal(t, "open", s.Status)
}

// DASH-07 freshness: a later merge WITHOUT a re-suggest clears a stale mark.
func TestDash07_MergeWithoutResuggestClearsStaleMark(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)

	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetSuggestedResolutionTx(tx, int(sitID), "thought it was done"))
	require.NoError(t, tx.Commit())

	insertMessage(t, d, "C1", "1.1", "U2", "actually still blocked")
	sig1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "actually still blocked"})

	gen.responses = []string{`{"ops":[
		{"op":"merge","situation_id":` + strconv.FormatInt(sitID, 10) + `,"signals":["sig:` + strconv.FormatInt(sig1, 10) + `"]}
	]}`}

	_, merged, err := p.runCompose(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, merged)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "", s.SuggestedResolution, "a merge with new material and no re-suggest must clear the stale mark")
}

// A rerank alone does NOT clear the mark (only merges represent new material).
func TestDash07_RerankAloneKeepsMark(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)

	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetSuggestedResolutionTx(tx, int(sitID), "thought it was done"))
	require.NoError(t, tx.Commit())

	// A fresh pending signal makes the cycle non-empty so the AI is invoked;
	// the op below doesn't reference it, mirroring TestCompose_HallucinatedKeysSkipped.
	insertMessage(t, d, "C1", "1.1", "U2", "unrelated noise")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "unrelated noise"})

	gen.responses = []string{`{"ops":[
		{"op":"rerank","situation_id":` + strconv.FormatInt(sitID, 10) + `,"rank":0.8,"reason":"escalated"}
	]}`}

	_, _, err = p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "thought it was done", s.SuggestedResolution, "a bare rerank must not touch the suggestion mark")
}

// Hallucinated/malformed suggest ops are skipped like other bad ops.
func TestDash07_SuggestResolveSkipsHallucinatedAndEmptyReason(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	insertChannel(t, d, "C1", "public")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.5, AIReason: "old reason"})
	require.NoError(t, err)

	insertMessage(t, d, "C1", "1.1", "U2", "unrelated noise")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "unrelated noise"})

	gen.responses = []string{`{"ops":[
		{"op":"suggest_resolve","situation_id":9999,"reason":"phantom"},
		{"op":"suggest_resolve","situation_id":` + strconv.FormatInt(sitID, 10) + `,"reason":""}
	]}`}

	_, _, err = p.runCompose(context.Background(), "U1")
	require.NoError(t, err)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "", s.SuggestedResolution, "hallucinated id and empty reason must both be skipped")
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
