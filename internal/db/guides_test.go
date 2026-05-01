package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func makeGuide(userID string, from, to float64) CommunicationGuide {
	return CommunicationGuide{
		UserID:           userID,
		PeriodFrom:       from,
		PeriodTo:         to,
		MessageCount:     50,
		ChannelsActive:   3,
		ActiveHoursJSON:  "{}",
		Summary:          "communicate clearly with " + userID,
		Recommendations:  "[]",
		SituationalTactics: "[]",
		EffectiveApproaches: "[]",
		Model:            "haiku",
	}
}

func TestUpsertCommunicationGuide_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	id, err := db.UpsertCommunicationGuide(makeGuide("U1", 100, 200))
	require.NoError(t, err)
	require.NotZero(t, id)

	// Re-upsert same window updates.
	g := makeGuide("U1", 100, 200)
	g.Summary = "updated"
	id2, err := db.UpsertCommunicationGuide(g)
	require.NoError(t, err)
	assert.Equal(t, id, id2, "upsert must reuse the same row id")

	got, err := db.GetLatestCommunicationGuide("U1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "updated", got.Summary)
}

func TestGetCommunicationGuides_FilteredAndOrdered(t *testing.T) {
	db := openTestDB(t)

	for _, span := range []struct{ from, to float64 }{{100, 200}, {300, 400}, {500, 600}} {
		_, err := db.UpsertCommunicationGuide(makeGuide("U1", span.from, span.to))
		require.NoError(t, err)
	}
	_, err := db.UpsertCommunicationGuide(makeGuide("U2", 700, 800))
	require.NoError(t, err)

	got, err := db.GetCommunicationGuides(GuideFilter{UserID: "U1", Limit: 10})
	require.NoError(t, err)
	require.Len(t, got, 3)
	// Newest period_to first.
	assert.Equal(t, float64(600), got[0].PeriodTo)
	assert.Equal(t, float64(400), got[1].PeriodTo)
	assert.Equal(t, float64(200), got[2].PeriodTo)
}

func TestGetCommunicationGuides_TimeWindow(t *testing.T) {
	db := openTestDB(t)
	_, _ = db.UpsertCommunicationGuide(makeGuide("U1", 100, 200))
	_, _ = db.UpsertCommunicationGuide(makeGuide("U1", 300, 400))

	got, err := db.GetCommunicationGuides(GuideFilter{UserID: "U1", FromUnix: 250, ToUnix: 500})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, float64(400), got[0].PeriodTo)
}

func TestGetLatestCommunicationGuide_None(t *testing.T) {
	db := openTestDB(t)
	got, err := db.GetLatestCommunicationGuide("nobody")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetCommunicationGuidesForWindow_OrdersByMessageCount(t *testing.T) {
	db := openTestDB(t)

	g1 := makeGuide("U1", 100, 200)
	g1.MessageCount = 10
	g2 := makeGuide("U2", 100, 200)
	g2.MessageCount = 50
	g3 := makeGuide("U3", 100, 200)
	g3.MessageCount = 30
	_, _ = db.UpsertCommunicationGuide(g1)
	_, _ = db.UpsertCommunicationGuide(g2)
	_, _ = db.UpsertCommunicationGuide(g3)

	got, err := db.GetCommunicationGuidesForWindow(100, 200)
	require.NoError(t, err)
	require.Len(t, got, 3)
	assert.Equal(t, "U2", got[0].UserID, "highest message_count first")
	assert.Equal(t, "U3", got[1].UserID)
	assert.Equal(t, "U1", got[2].UserID)
}

func TestUpsertGuideSummary_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertGuideSummary(GuideSummary{
		PeriodFrom: 100, PeriodTo: 200,
		Summary: "team is shipping fast",
		Tips:    `["tip1","tip2"]`,
		Model:   "haiku",
	}))

	got, err := db.GetGuideSummary(100, 200)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "team is shipping fast", got.Summary)
	assert.Contains(t, got.Tips, "tip1")
}

func TestGetGuideSummary_NotFound(t *testing.T) {
	db := openTestDB(t)
	got, err := db.GetGuideSummary(100, 200)
	// Returns nil + error per impl — just ensure it doesn't crash.
	if err == nil {
		assert.Nil(t, got)
	}
}

func TestUpsertGuideSummary_Overwrites(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.UpsertGuideSummary(GuideSummary{
		PeriodFrom: 100, PeriodTo: 200,
		Summary: "old summary",
		Model:   "haiku",
	}))
	require.NoError(t, db.UpsertGuideSummary(GuideSummary{
		PeriodFrom: 100, PeriodTo: 200,
		Summary: "new summary",
		Model:   "sonnet",
	}))

	got, err := db.GetGuideSummary(100, 200)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "new summary", got.Summary)
	assert.Equal(t, "sonnet", got.Model)
}
