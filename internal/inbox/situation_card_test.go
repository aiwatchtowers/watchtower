package inbox

import (
	"context"
	"fmt"
	"log"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRunSituationCards_GeneratesAndPersists(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "prod incident", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "prod is down"})
	require.NoError(t, err)
	sig := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "prod down"})
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig)}))

	gen.responses = []string{`{"summary":"Prod has been down since 10am.","why_matters":"CEO cares about uptime.","chronology":"U2 — reported prod down."}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "ready", s.CardStatus)
	assert.Equal(t, "Prod has been down since 10am.", s.Summary)
	assert.Equal(t, "CEO cares about uptime.", s.WhyMatters)
	assert.Equal(t, "U2 — reported prod down.", s.Chronology)
}

func TestDash02_CardFailureMarksFailedAndContinues(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	sit1, err := d.CreateSituation(db.DashboardSituation{Title: "first situation", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason 1"})
	require.NoError(t, err)
	sit2, err := d.CreateSituation(db.DashboardSituation{Title: "second situation", Kind: "external", Priority: "medium", Rank: 0.5, AIReason: "reason 2"})
	require.NoError(t, err)
	// ListSituationsNeedingCards orders by rank DESC, so sit1 (rank 0.9) is
	// processed before sit2 (rank 0.5), making the failure order deterministic.

	gen.responses = []string{"", `{"summary":"all clear now","why_matters":"resolved","chronology":"U2 — fixed it."}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	s1, err := d.GetSituation(int(sit1))
	require.NoError(t, err)
	assert.Equal(t, "failed", s1.CardStatus)

	s2, err := d.GetSituation(int(sit2))
	require.NoError(t, err)
	assert.Equal(t, "ready", s2.CardStatus)
}

func TestRunSituationCards_EmptySummaryMarksFailed(t *testing.T) {
	d, p, gen := newComposePipeline(t)
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "quiet situation", Kind: "external", Priority: "low", Rank: 0.2, AIReason: "reason"})
	require.NoError(t, err)

	gen.responses = []string{`{"summary":"","why_matters":"something","chronology":"something"}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, n)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "failed", s.CardStatus)
}

func TestRunSituationCards_CapsToNewestMembers(t *testing.T) {
	// 22 member signals, cap 20: keep-newest must KEEP the 2 newest and DROP
	// the 2 oldest, so a stale card can't omit a recent resolution. This pins
	// keep-newest specifically: flipping the slice back to head truncation
	// (members[:cap], keep-oldest) drops sigbody-21/22 and makes this RED.
	//
	// message_ts is a TEXT column and ListSituationSignals orders by it
	// lexicographically, so the timestamps and snippet tokens are zero-padded
	// to width 2 — lexicographic order then equals numeric order (01<02<…<22).
	d, p, gen := newComposePipeline(t)
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "long thread", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason"})
	require.NoError(t, err)
	ids := make([]int, 0, 22)
	for i := 1; i <= 22; i++ {
		id := mustCreateInboxItem(t, d, db.InboxItem{
			ChannelID:    "C1",
			MessageTS:    fmt.Sprintf("%02d", i),
			SenderUserID: "U2",
			TriggerType:  "stream",
			Snippet:      fmt.Sprintf("sigbody-%02d", i),
		})
		ids = append(ids, int(id))
	}
	require.NoError(t, d.AddSituationSignals(int(sitID), ids))

	gen.responses = []string{`{"summary":"s","why_matters":"w","chronology":"c"}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	require.Len(t, gen.prompts, 1)
	prompt := gen.prompts[0]
	// sigbody-22 is the newest signal — kept only by keep-newest (head
	// truncation would drop it).
	assert.Contains(t, prompt, "sigbody-22", "newest signal must survive the cap")
	// sigbody-01 is the oldest — dropped only by keep-newest (head truncation
	// would keep it).
	assert.NotContains(t, prompt, "sigbody-01", "oldest signal must be dropped by the newest-first cap")
	assert.Contains(t, prompt, "…and 2 more")
}

func TestRunSituationCards_ResolvesSenderNames(t *testing.T) {
	// The signals block must feed the sender's display name, not the raw Slack
	// user ID — otherwise the AI echoes IDs like "U010F2S53JM" straight into the
	// chronology. A sender with no matching users row falls back to the raw ID
	// (UserNameByID's contract), which is correct for non-Slack senders (Jira
	// issue keys, "watchtower").
	d, p, gen := newComposePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U2", Name: "alice", DisplayName: "Alice Anderson"}))
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "prod incident", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason"})
	require.NoError(t, err)
	sig := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "prod down"})
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig)}))

	gen.responses = []string{`{"summary":"s","why_matters":"w","chronology":"c"}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	require.Len(t, gen.prompts, 1)
	prompt := gen.prompts[0]
	assert.Contains(t, prompt, "from=Alice Anderson", "sender must render as display name")
	assert.NotContains(t, prompt, "from=U2", "raw sender ID must not leak into the prompt")
}

func TestRunSituationCards_SnippetResolvesMention(t *testing.T) {
	// Raw `<@U…>` mentions surviving in stored snippets must resolve to names
	// in the card prompt instead of being dropped.
	d, p, gen := newComposePipeline(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "prod incident", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason"})
	require.NoError(t, err)
	sig := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "<@U3> escalated this"})
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sig)}))

	gen.responses = []string{`{"summary":"s","why_matters":"w","chronology":"c"}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	require.Len(t, gen.prompts, 1)
	assert.Contains(t, gen.prompts[0], "@Bob Brown escalated this")
}

func TestRunSituationCards_EmailSignalIncludesFullBody(t *testing.T) {
	// Spec "AI-обработка писем" #3: situation cards (the strong tier) must see
	// the full gmail body_text, not just the subject+preview Snippet triage
	// judges on. message_ts on an email inbox item is the Gmail message id.
	d, p, gen := newComposePipeline(t)
	acctID, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", Label: "Me"})
	require.NoError(t, err)
	require.NoError(t, d.UpsertGmailMessage(acctID, db.GmailMessage{
		ID: "gm1", ThreadID: "thr1", FromEmail: "a@x.com",
		ToJSON: `["me@x.com"]`, CcJSON: `[]`, Subject: "Contract renewal",
		Snippet: "preview only", BodyText: "The full contract terms are attached, please review by Friday.",
		InternalDate: "2026-07-09T10:00:00Z", SyncedAt: "2026-07-09T10:00:01Z",
	}))

	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "contract renewal", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason"})
	require.NoError(t, err)
	emailSig := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "thr1", MessageTS: "gm1", SenderUserID: "a@x.com", TriggerType: "email_received", Snippet: "Contract renewal — preview only"})
	streamSig := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream", Snippet: "prod down"})
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(emailSig), int(streamSig)}))

	gen.responses = []string{`{"summary":"s","why_matters":"w","chronology":"c"}`}

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	require.Len(t, gen.prompts, 1)
	prompt := gen.prompts[0]
	assert.Contains(t, prompt, "The full contract terms are attached, please review by Friday.", "email signal must carry the full gmail body_text")
	// Non-email signal format is unchanged: no body= line for it.
	assert.NotContains(t, prompt, "body=prod down")
}

func TestTargetTitle_ResolvesMention(t *testing.T) {
	d := newTestDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES (?, '2026-07-01', '2026-07-31')`, "sync with <@U3> weekly")
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)

	assert.Equal(t, "sync with @Bob Brown weekly", targetTitle(d, int(id)))
}

func TestRunSituationCards_NilGeneratorSkips(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	p := New(d, testConfig(), nil, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "needs card", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "reason"})
	require.NoError(t, err)

	n, err := p.runSituationCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, n)

	s, err := d.GetSituation(int(sitID))
	require.NoError(t, err)
	assert.Equal(t, "none", s.CardStatus, "nil generator must leave situations untouched for a later cycle")
}
