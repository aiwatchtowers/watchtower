package inbox

import (
	"context"
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
