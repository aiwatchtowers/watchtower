package guide

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// outcomeBatchReply is a batch-shaped AI reply naming U1, so a run stores a
// real AI card (only an AI card covers the window).
const outcomeBatchReply = `[{"user_id":"U1","summary":"s","communication_style":"","decision_role":"","red_flags":[],"highlights":[],"accomplishments":[],"communication_guide":"","decision_style":"","tactics":[]}]`

// outcomeWindow is a 7-day window ending at the start of today.
func outcomeWindow() (from, to float64) {
	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	return float64(dayStart.AddDate(0, 0, -DefaultWindowDays).Unix()), float64(dayStart.Unix())
}

// seedOutcomeUser seeds U1 with enough messages inside the window to count as
// an active user.
func seedOutcomeUser(t *testing.T, database *db.DB, from float64) {
	t.Helper()
	seedUser(t, database, "U1", "alice")
	seedChannel(t, database, "C1", "general")
	for i := range DefaultMinMessages + 1 {
		seedMessage(t, database, "C1", fmt.Sprintf("%.6f", from+86400+float64(i*60)), "U1", "msg")
	}
}

// seedOutcomeSituation seeds a channel digest with one situation for U1.
func seedOutcomeSituation(t *testing.T, database *db.DB, from, to float64) {
	t.Helper()
	seedDigestWithSituations(t, database, "C1", from, to, `[]`,
		`[{"topic":"X","type":"collaboration","participants":[{"user_id":"U1","role":"lead"}],"dynamic":"d","outcome":"o","red_flags":[],"observations":[],"message_refs":[]}]`)
}

func TestRunForWindow_NoActiveUsersReportsNoData(t *testing.T) {
	database := db.OpenTestDB(t)
	gen := &mockGenerator{response: outcomeBatchReply}
	pipe := New(database, testConfig(), gen, testLogger())
	from, to := outcomeWindow()

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, OutcomeNoData, pipe.LastOutcome())
}

func TestRunForWindow_NoSituationsReportsNoData(t *testing.T) {
	database := db.OpenTestDB(t)
	from, to := outcomeWindow()
	seedOutcomeUser(t, database, from)
	gen := &mockGenerator{response: outcomeBatchReply}
	pipe := New(database, testConfig(), gen, testLogger())

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, OutcomeNoData, pipe.LastOutcome())
	assert.Equal(t, int32(0), gen.calls.Load(), "no situations must not reach the AI")
}

func TestRunForWindow_AllCoveredReportsCovered(t *testing.T) {
	database := db.OpenTestDB(t)
	from, to := outcomeWindow()
	seedOutcomeUser(t, database, from)
	seedOutcomeSituation(t, database, from, to)
	gen := &mockGenerator{response: outcomeBatchReply}

	first := New(database, testConfig(), gen, testLogger())
	_, err := first.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	require.Equal(t, OutcomeGenerated, first.LastOutcome())

	second := New(database, testConfig(), gen, testLogger())
	n, err := second.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, OutcomeCovered, second.LastOutcome())
}

func TestRunForWindow_GeneratesReportsGenerated(t *testing.T) {
	database := db.OpenTestDB(t)
	from, to := outcomeWindow()
	seedOutcomeUser(t, database, from)
	seedOutcomeSituation(t, database, from, to)
	gen := &mockGenerator{response: outcomeBatchReply}
	pipe := New(database, testConfig(), gen, testLogger())

	n, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.GreaterOrEqual(t, n, 1)
	assert.Equal(t, OutcomeGenerated, pipe.LastOutcome())
}

func TestRunForWindow_ForceRegenerateIgnoresNoSituations(t *testing.T) {
	database := db.OpenTestDB(t)
	from, to := outcomeWindow()
	seedOutcomeUser(t, database, from)
	gen := &mockGenerator{response: outcomeBatchReply}
	pipe := New(database, testConfig(), gen, testLogger())
	pipe.ForceRegenerate = true

	_, err := pipe.RunForWindow(context.Background(), from, to)
	require.NoError(t, err)
	assert.GreaterOrEqual(t, int(gen.calls.Load()), 1, "the CLI's forced run still reaches the AI")
	assert.Equal(t, OutcomeGenerated, pipe.LastOutcome())
}

// HasData is the negation of RunForWindow's OutcomeNoData over Run's window.
func TestHasData_MatchesNoDataOutcome(t *testing.T) {
	database := db.OpenTestDB(t)
	pipe := New(database, testConfig(), &mockGenerator{response: outcomeBatchReply}, testLogger())
	from, to := outcomeWindow()

	has, err := pipe.HasData()
	require.NoError(t, err)
	assert.False(t, has, "no active users")

	seedOutcomeUser(t, database, from)
	has, err = pipe.HasData()
	require.NoError(t, err)
	assert.False(t, has, "active users but no situations")

	pipe.ForceRegenerate = true
	has, err = pipe.HasData()
	require.NoError(t, err)
	assert.True(t, has, "a forced run does not need situations")
	pipe.ForceRegenerate = false

	seedOutcomeSituation(t, database, from, to)
	has, err = pipe.HasData()
	require.NoError(t, err)
	assert.True(t, has, "users and situations")
}
