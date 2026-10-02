package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedBulkTrack inserts a track with the given origin, last updated `age` ago.
func seedBulkTrack(t *testing.T, d *DB, text, origin string, age time.Duration) int {
	t.Helper()
	id, err := d.UpsertTrack(Track{Text: text})
	require.NoError(t, err)
	stamp := isoUTC(time.Now().Add(-age))
	_, err = d.Exec(`UPDATE tracks SET origin = ?, updated_at = ?, created_at = ? WHERE id = ?`, origin, stamp, stamp, id)
	require.NoError(t, err)
	return int(id)
}

func dismissedAt(t *testing.T, d *DB, id int) string {
	t.Helper()
	tr, err := d.GetTrackByID(id)
	require.NoError(t, err)
	return tr.DismissedAt
}

func TestActiveTracksMatching_FiltersAndOrder(t *testing.T) {
	d := openTestDB(t)
	day := 24 * time.Hour
	fresh := seedBulkTrack(t, d, "fresh auto", "auto", time.Hour)
	old := seedBulkTrack(t, d, "old auto", "auto", 40*day)
	custom := seedBulkTrack(t, d, "custom", "custom", 50*day)
	gone := seedBulkTrack(t, d, "dismissed auto", "auto", 60*day)
	require.NoError(t, d.DismissTrack(gone))

	all, err := d.ActiveTracksMatching(TrackSelection{})
	require.NoError(t, err)
	require.Len(t, all, 3, "a dismissed track is never selected")
	assert.Equal(t, []int{fresh, old, custom}, []int{all[0].ID, all[1].ID, all[2].ID}, "newest update first")

	auto, err := d.ActiveTracksMatching(TrackSelection{Origin: "auto"})
	require.NoError(t, err)
	require.Len(t, auto, 2)

	stale, err := d.ActiveTracksMatching(TrackSelection{UpdatedBefore: isoUTC(time.Now().Add(-30 * day))})
	require.NoError(t, err)
	assert.Len(t, stale, 2)

	created, err := d.ActiveTracksMatching(TrackSelection{CreatedBefore: isoUTC(time.Now().Add(-45 * day))})
	require.NoError(t, err)
	require.Len(t, created, 1)
	assert.Equal(t, custom, created[0].ID)

	except, err := d.ActiveTracksMatching(TrackSelection{ExceptIDs: []int{fresh}})
	require.NoError(t, err)
	assert.Len(t, except, 2)
	for _, b := range except {
		assert.NotEqual(t, fresh, b.ID)
	}
}

func TestDismissTracks_StampsOnlyActiveRows(t *testing.T) {
	d := openTestDB(t)
	a := seedBulkTrack(t, d, "a", "auto", time.Hour)
	b := seedBulkTrack(t, d, "b", "auto", time.Hour)
	keep := seedBulkTrack(t, d, "keep", "auto", time.Hour)
	already := seedBulkTrack(t, d, "already", "auto", time.Hour)
	_, err := d.Exec(`UPDATE tracks SET dismissed_at = '2000-01-01T00:00:00Z' WHERE id = ?`, already)
	require.NoError(t, err)

	n, err := d.DismissTracks([]int{a, b, already, 999999})
	require.NoError(t, err)
	assert.Equal(t, 2, n, "only the two active rows count; missing and already-dismissed ids are skipped")
	assert.NotEmpty(t, dismissedAt(t, d, a))
	assert.NotEmpty(t, dismissedAt(t, d, b))
	assert.Empty(t, dismissedAt(t, d, keep))
	assert.Equal(t, "2000-01-01T00:00:00Z", dismissedAt(t, d, already), "an earlier dismissal keeps its stamp")

	again, err := d.DismissTracks([]int{a, b})
	require.NoError(t, err)
	assert.Zero(t, again, "a repeated dismiss is a no-op")

	// Reversible: the single-track restore brings a bulk-dismissed row back.
	require.NoError(t, d.RestoreTrack(a))
	assert.Empty(t, dismissedAt(t, d, a))
}

func TestDismissTracks_EmptyIsANoOp(t *testing.T) {
	d := openTestDB(t)
	n, err := d.DismissTracks(nil)
	require.NoError(t, err)
	assert.Zero(t, n)
}

func TestTrackBriefsByID_FlagsDismissed(t *testing.T) {
	d := openTestDB(t)
	a := seedBulkTrack(t, d, "a", "auto", time.Hour)
	b := seedBulkTrack(t, d, "b", "custom", time.Hour)
	require.NoError(t, d.DismissTrack(b))

	got, err := d.TrackBriefsByID([]int{a, b, 999999})
	require.NoError(t, err)
	require.Len(t, got, 2)
	none, err := d.TrackBriefsByID(nil)
	require.NoError(t, err)
	assert.Empty(t, none)
	byID := map[int]TrackBrief{}
	for _, g := range got {
		byID[g.ID] = g
	}
	assert.False(t, byID[a].Dismissed)
	assert.True(t, byID[b].Dismissed)
	assert.Equal(t, "custom", byID[b].Origin)
}

func TestCountTracks_Groups(t *testing.T) {
	d := openTestDB(t)
	day := 24 * time.Hour
	newest := seedBulkTrack(t, d, "newest", "auto", time.Hour)
	seedBulkTrack(t, d, "week", "auto", 10*day)
	seedBulkTrack(t, d, "quarter", "custom", 60*day)
	seedBulkTrack(t, d, "ancient", "auto", 200*day)
	gone := seedBulkTrack(t, d, "gone", "auto", 2*day)
	require.NoError(t, d.DismissTrack(gone))

	c, err := d.CountTracks(TrackSelection{}, time.Now())
	require.NoError(t, err)
	assert.Equal(t, 4, c.Active)
	assert.Equal(t, 1, c.Dismissed)
	assert.Equal(t, map[string]int{"auto": 3, "custom": 1}, c.ByOrigin)
	assert.Equal(t, map[string]int{"mine": 4}, c.ByOwnership)
	assert.Equal(t, map[string]int{"medium": 4}, c.ByPriority)
	assert.Equal(t, map[string]int{"7d": 1, "30d": 1, "90d": 1, "older": 1}, c.ByLastUpdate)
	require.Len(t, c.Newest, 3)
	assert.Equal(t, newest, c.Newest[0].ID)

	auto, err := d.CountTracks(TrackSelection{Origin: "auto"}, time.Now())
	require.NoError(t, err)
	assert.Equal(t, 3, auto.Active)
	assert.Equal(t, 1, auto.Dismissed)

	empty, err := d.CountTracks(TrackSelection{Origin: "custom", ExceptIDs: []int{newest}, UpdatedBefore: isoUTC(time.Now().Add(-365 * day))}, time.Now())
	require.NoError(t, err)
	assert.Zero(t, empty.Active)
	assert.NotNil(t, empty.Newest, "an empty count still marshals newest as []")
}
