package guide

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// recordingGenerator answers batch calls with batchResponse (or batchErr),
// records every batch prompt, and runs onBatch (if set) before answering.
type recordingGenerator struct {
	mu            sync.Mutex
	batchResponse string
	batchErr      error
	batchPrompts  []string
	onBatch       func()
}

func (g *recordingGenerator) Generate(_ context.Context, sys, user, _ string) (string, *digest.Usage, string, error) {
	combined := sys + user
	if strings.Contains(combined, "=== USERS ===") {
		g.mu.Lock()
		g.batchPrompts = append(g.batchPrompts, combined)
		g.mu.Unlock()
		if g.onBatch != nil {
			g.onBatch()
		}
		return g.batchResponse, &digest.Usage{}, "", g.batchErr
	}
	return `{"summary":"team","attention":[],"tips":[]}`, &digest.Usage{}, "", nil
}

func batchCardJSON(userIDs ...string) string {
	parts := make([]string, 0, len(userIDs))
	for _, id := range userIDs {
		parts = append(parts, fmt.Sprintf(`{"user_id":%q,"summary":"card for %s","communication_style":"driver","decision_role":"contributor","red_flags":[],"highlights":[],"accomplishments":[],"communication_guide":"","decision_style":"","tactics":[]}`, id, id))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// seedLowDataUsers seeds two low-data users (batch tier) plus a digest with a
// situation so the daemon-mode "no situations yet" skip does not fire.
func seedLowDataUsers(t *testing.T, database *db.DB) (float64, float64) {
	t.Helper()
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}))
	seedUser(t, database, "U1", "alice")
	seedUser(t, database, "U2", "bob")
	seedChannel(t, database, "C1", "general")
	now := time.Now()
	from := float64(now.Add(-7 * 24 * time.Hour).Unix())
	to := float64(now.Unix())
	base := from + 86400
	for i := range 4 {
		seedMessage(t, database, "C1", fmt.Sprintf("%.6f", base+float64(i*60)), "U1", "msg "+string(rune('a'+i)))
		seedMessage(t, database, "C1", fmt.Sprintf("%.6f", base+float64((i+10)*60)), "U2", "msg "+string(rune('a'+i)))
	}
	seedDigestWithSituations(t, database, "C1", from, to, `[]`,
		`[{"topic":"Topic X","type":"collaboration","participants":[{"user_id":"U3","role":"lead"}],"dynamic":"unrelated","outcome":"done","red_flags":[],"observations":[],"message_refs":[]}]`)
	return from, to
}

func cardStatus(t *testing.T, database *db.DB, userID string) string {
	t.Helper()
	card, err := database.GetLatestPeopleCard(userID)
	require.NoError(t, err)
	require.NotNil(t, card, "no card for %s", userID)
	return card.Status
}

// A total AI failure leaves fallback insufficient_data cards behind; they must
// not count as window completion, so the next (non-forced) run retries every
// user instead of skipping the window as "already has N cards".
func TestPipeline_FallbackCardsDoNotCompleteWindow(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	cfg := testConfig()
	cfg.AI.Workers = 1

	failing := &recordingGenerator{batchErr: fmt.Errorf("AI overloaded")}
	_, err := New(database, cfg, failing, testLogger()).RunForWindow(context.Background(), from, to)
	require.Error(t, err)
	require.Equal(t, "insufficient_data", cardStatus(t, database, "U1"))

	ok := &recordingGenerator{batchResponse: batchCardJSON("U1", "U2")}
	n, err := New(database, cfg, ok, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 2, n, "both fallback users are retried")
	require.Len(t, ok.batchPrompts, 1)
	assert.Equal(t, "active", cardStatus(t, database, "U1"))
	assert.Equal(t, "active", cardStatus(t, database, "U2"))
}

// A partial run is a success, and the next run over the same window resends
// only the user whose card fell back — never the one the AI already covered.
func TestPipeline_RerunCoversOnlyUsersWithoutAICard(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	cfg := testConfig()
	cfg.AI.Workers = 1

	partial := &recordingGenerator{batchResponse: batchCardJSON("U1")} // U2 missing from the reply
	n, err := New(database, cfg, partial, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err, "a partial run stays a success")
	assert.Equal(t, 2, n)
	require.Equal(t, "active", cardStatus(t, database, "U1"))
	require.Equal(t, "insufficient_data", cardStatus(t, database, "U2"))

	retry := &recordingGenerator{batchResponse: batchCardJSON("U2")}
	n, err = New(database, cfg, retry, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	require.Len(t, retry.batchPrompts, 1)
	assert.Contains(t, retry.batchPrompts[0], "(user_id: U2)")
	assert.NotContains(t, retry.batchPrompts[0], "(user_id: U1)", "a user with an AI card is not re-sent")
	assert.Equal(t, "active", cardStatus(t, database, "U2"))

	// Everyone covered now: the window is complete and costs no AI call.
	done := &recordingGenerator{}
	n, err = New(database, cfg, done, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Empty(t, done.batchPrompts)
}

// A shutdown mid-run is reported (so the daemon does not stamp the window as
// done) and is attributed to the cancellation, not to the AI.
func TestPipeline_ShutdownMidRunIsReported(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	cfg := testConfig()
	cfg.AI.Workers = 1

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gen := &recordingGenerator{batchResponse: batchCardJSON("U1", "U2"), onBatch: cancel}
	_, err := New(database, cfg, gen, testLogger()).RunForWindow(ctx, from, to)
	require.Error(t, err)
	assert.ErrorIs(t, err, context.Canceled)
	assert.NotContains(t, err.Error(), "no people card produced by AI")
}

// A resumed window (two users already covered by AI cards) still computes team
// norms over the whole active population, not just the user left to process —
// or that user would be compared against themselves.
func TestPipeline_ResumedWindowKeepsFullTeamNorms(t *testing.T) {
	database := testDB(t)
	from, to := seedLowDataUsers(t, database)
	seedUser(t, database, "U3", "carol")
	base := from + 86400
	for i := range 4 {
		seedMessage(t, database, "C1", fmt.Sprintf("%.6f", base+float64((i+20)*60)), "U3", "msg "+string(rune('a'+i)))
	}
	cfg := testConfig()
	cfg.AI.Workers = 1

	first := &recordingGenerator{batchResponse: batchCardJSON("U1", "U2")} // U3 falls back
	_, err := New(database, cfg, first, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	require.Len(t, first.batchPrompts, 1)
	require.Contains(t, first.batchPrompts[0], "Team averages (3 people)")

	resumed := &recordingGenerator{batchResponse: batchCardJSON("U3")}
	_, err = New(database, cfg, resumed, testLogger()).RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	require.Len(t, resumed.batchPrompts, 1)
	assert.Contains(t, resumed.batchPrompts[0], "(user_id: U3)")
	assert.NotContains(t, resumed.batchPrompts[0], "(user_id: U1)")
	assert.Contains(t, resumed.batchPrompts[0], "Team averages (3 people)", "norms cover the whole team, not the remaining user")
}
