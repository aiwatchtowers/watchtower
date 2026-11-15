package db

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ensureChannels creates minimal channel records for FK compliance.
func ensureChannels(t *testing.T, db *DB, ids ...string) {
	t.Helper()
	for _, id := range ids {
		require.NoError(t, db.UpsertChannel(Channel{ID: id, Name: id, Type: "public"}))
	}
}

func TestToggleMuteForLLM(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	// First toggle: sets to true (creates row)
	val, err := db.ToggleMuteForLLM("C1")
	require.NoError(t, err)
	assert.True(t, val)

	// Second toggle: sets to false
	val, err = db.ToggleMuteForLLM("C1")
	require.NoError(t, err)
	assert.False(t, val)

	// Third toggle: back to true
	val, err = db.ToggleMuteForLLM("C1")
	require.NoError(t, err)
	assert.True(t, val)
}

func TestToggleFavorite(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	val, err := db.ToggleFavorite("C1")
	require.NoError(t, err)
	assert.True(t, val)

	val, err = db.ToggleFavorite("C1")
	require.NoError(t, err)
	assert.False(t, val)
}

func TestSetMuteForLLM(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	require.NoError(t, db.SetMuteForLLM("C1", true))
	cs, err := db.GetChannelSettings("C1")
	require.NoError(t, err)
	require.NotNil(t, cs)
	assert.True(t, cs.IsMutedForLLM)

	require.NoError(t, db.SetMuteForLLM("C1", false))
	cs, err = db.GetChannelSettings("C1")
	require.NoError(t, err)
	require.NotNil(t, cs)
	assert.False(t, cs.IsMutedForLLM)
}

func TestSetFavorite(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	require.NoError(t, db.SetFavorite("C1", true))
	cs, err := db.GetChannelSettings("C1")
	require.NoError(t, err)
	require.NotNil(t, cs)
	assert.True(t, cs.IsFavorite)

	require.NoError(t, db.SetFavorite("C1", false))
	cs, err = db.GetChannelSettings("C1")
	require.NoError(t, err)
	assert.False(t, cs.IsFavorite)
}

func TestGetChannelSettings_NotFound(t *testing.T) {
	db := openTestDB(t)

	cs, err := db.GetChannelSettings("NONEXISTENT")
	require.NoError(t, err)
	assert.Nil(t, cs)
}

func TestGetAllChannelSettings(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1", "C2")

	require.NoError(t, db.SetMuteForLLM("C1", true))
	require.NoError(t, db.SetFavorite("C2", true))

	all, err := db.GetAllChannelSettings()
	require.NoError(t, err)
	assert.Len(t, all, 2)
}

func TestGetMutedChannelIDs(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1", "C2", "C3")

	// No muted channels
	ids, err := db.GetMutedChannelIDs()
	require.NoError(t, err)
	assert.Empty(t, ids)

	// Mute some channels
	require.NoError(t, db.SetMuteForLLM("C1", true))
	require.NoError(t, db.SetMuteForLLM("C2", true))
	require.NoError(t, db.SetFavorite("C3", true)) // not muted, just favorite

	ids, err = db.GetMutedChannelIDs()
	require.NoError(t, err)
	assert.Len(t, ids, 2)
	assert.Contains(t, ids, "C1")
	assert.Contains(t, ids, "C2")
}

func TestToggleMutePreservesFavorite(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	// Set favorite first
	require.NoError(t, db.SetFavorite("C1", true))

	// Toggle mute should not affect favorite
	_, err := db.ToggleMuteForLLM("C1")
	require.NoError(t, err)

	cs, err := db.GetChannelSettings("C1")
	require.NoError(t, err)
	require.NotNil(t, cs)
	assert.True(t, cs.IsMutedForLLM)
	assert.True(t, cs.IsFavorite) // preserved
}

func TestToggleFavoritePreservesMute(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "C1")

	require.NoError(t, db.SetMuteForLLM("C1", true))

	_, err := db.ToggleFavorite("C1")
	require.NoError(t, err)

	cs, err := db.GetChannelSettings("C1")
	require.NoError(t, err)
	require.NotNil(t, cs)
	assert.True(t, cs.IsFavorite)
	assert.True(t, cs.IsMutedForLLM) // preserved
}

var (
	exclDay1  = time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	exclDay10 = time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	exclDay11 = time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC)
)

func mustSettings(t *testing.T, db *DB, id string) *ChannelSettings {
	t.Helper()
	cs, err := db.GetChannelSettings(id)
	require.NoError(t, err)
	require.NotNil(t, cs)
	return cs
}

func TestSetSyncExcluded_AlsoMutes(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0JUNK")

	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	cs := mustSettings(t, db, "1:C0JUNK")
	assert.True(t, cs.SyncExcluded)
	assert.Equal(t, "2026-11-01T09:00:00Z", cs.ExcludedAt)
	assert.True(t, cs.IsMutedForLLM)
	assert.True(t, cs.MutedByExclusion)
	assert.Equal(t, "2026-11-01T09:00:00Z", cs.MutedAt)
	assert.False(t, cs.CatchupFrom.Valid)
	assert.False(t, cs.CatchupTo.Valid)

	// Excluding again keeps the original start.
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay10))
	assert.Equal(t, "2026-11-01T09:00:00Z", mustSettings(t, db, "1:C0JUNK").ExcludedAt)
}

func TestSyncAgain_UnmutesOnlyIfStopSyncingMuted(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0MUTED", "1:C0JUNK")

	// Muted by the user before Stop syncing: stays muted after Sync again.
	require.NoError(t, db.SetMuteForLLM("1:C0MUTED", true))
	mutedAt := mustSettings(t, db, "1:C0MUTED").MutedAt
	require.NoError(t, db.SetSyncExcluded("1:C0MUTED", true, exclDay1))
	cs := mustSettings(t, db, "1:C0MUTED")
	assert.False(t, cs.MutedByExclusion)
	assert.Equal(t, mutedAt, cs.MutedAt)
	require.NoError(t, db.SetSyncExcluded("1:C0MUTED", false, exclDay10))
	cs = mustSettings(t, db, "1:C0MUTED")
	assert.False(t, cs.SyncExcluded)
	assert.True(t, cs.IsMutedForLLM, "a mute the user set stays")
	assert.Equal(t, mutedAt, cs.MutedAt)

	// Not muted before: Sync again lifts the mute Stop syncing set.
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay10))
	cs = mustSettings(t, db, "1:C0JUNK")
	assert.False(t, cs.SyncExcluded)
	assert.False(t, cs.IsMutedForLLM)
	assert.False(t, cs.MutedByExclusion)
	assert.Empty(t, cs.MutedAt)
	require.True(t, cs.CatchupFrom.Valid)
	require.True(t, cs.CatchupTo.Valid)
	assert.Equal(t, float64(exclDay1.Add(-SyncAgainOverlap).Unix()), cs.CatchupFrom.Float64,
		"the catch-up starts the search overlap before Stop syncing")
	assert.Equal(t, float64(exclDay10.Unix()), cs.CatchupTo.Float64)
}

func TestSyncAgain_ManualMuteAfterStopSyncingSurvives(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0JUNK")
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	require.NoError(t, db.SetMuteForLLM("1:C0JUNK", true)) // the user takes the mute over
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay10))
	assert.True(t, mustSettings(t, db, "1:C0JUNK").IsMutedForLLM)
}

func TestSetSyncExcluded_IncludeWhenNotExcludedIsANoOp(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C1")
	require.NoError(t, db.SetSyncExcluded("1:C1", false, exclDay10))
	cs, err := db.GetChannelSettings("1:C1")
	require.NoError(t, err)
	if cs != nil {
		assert.False(t, cs.CatchupFrom.Valid, "no catch-up without an exclusion")
	}
	pending, err := db.PendingCatchups(1)
	require.NoError(t, err)
	assert.Empty(t, pending)
}

func TestCatchups_PendingAdvanceFinish(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0A", "1:C0B", "2:C0C")
	require.NoError(t, db.SetSyncExcluded("1:C0B", true, exclDay1))
	require.NoError(t, db.SetSyncExcluded("1:C0A", true, exclDay1.Add(time.Hour)))
	require.NoError(t, db.SetSyncExcluded("2:C0C", true, exclDay1))
	for _, id := range []string{"1:C0A", "1:C0B", "2:C0C"} {
		require.NoError(t, db.SetSyncExcluded(id, false, exclDay10))
	}

	pending, err := db.PendingCatchups(1)
	require.NoError(t, err)
	require.Len(t, pending, 2, "another account's catch-up is not listed")
	assert.Equal(t, Catchup{ChannelID: "1:C0B", From: float64(exclDay1.Add(-SyncAgainOverlap).Unix()), To: float64(exclDay10.Unix())}, pending[0], "the oldest first")
	assert.Equal(t, "1:C0A", pending[1].ChannelID)

	mid := float64(exclDay1.Add(48 * time.Hour).Unix())
	c := pending[0]
	applied, err := db.AdvanceCatchup(c, mid)
	require.NoError(t, err)
	assert.True(t, applied)
	applied, err = db.AdvanceCatchup(c, mid-60)
	require.NoError(t, err)
	assert.False(t, applied, "a stale bound (c.To is no longer the stored one) changes nothing")
	c.To = mid
	applied, err = db.AdvanceCatchup(c, mid+3600)
	require.NoError(t, err)
	assert.False(t, applied, "an advance only moves down")
	assert.Equal(t, mid, mustSettings(t, db, "1:C0B").CatchupTo.Float64)

	applied, err = db.FinishCatchup(Catchup{ChannelID: "1:C0B", From: c.From, To: c.To + 1})
	require.NoError(t, err)
	assert.False(t, applied, "a stale finish changes nothing")
	applied, err = db.FinishCatchup(c)
	require.NoError(t, err)
	assert.True(t, applied)
	cs := mustSettings(t, db, "1:C0B")
	assert.False(t, cs.CatchupFrom.Valid)
	assert.False(t, cs.CatchupTo.Valid)
	pending, err = db.PendingCatchups(1)
	require.NoError(t, err)
	require.Len(t, pending, 1)
	assert.Equal(t, "1:C0A", pending[0].ChannelID)
}

// A Stop syncing during an unfinished catch-up clears it, keeps the
// catch-up's start as the exclusion's, and a late advance changes nothing.
func TestSetSyncExcluded_DuringCatchupKeepsItsStart(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0JUNK")
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay10))
	pending, err := db.PendingCatchups(1)
	require.NoError(t, err)
	require.Len(t, pending, 1)
	walk := pending[0]
	applied, err := db.AdvanceCatchup(walk, float64(exclDay1.Add(72*time.Hour).Unix()))
	require.NoError(t, err)
	require.True(t, applied)
	walk.To = float64(exclDay1.Add(72 * time.Hour).Unix())

	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay11))
	cs := mustSettings(t, db, "1:C0JUNK")
	assert.Equal(t, "2026-11-01T09:00:00Z", cs.ExcludedAt)
	assert.False(t, cs.CatchupFrom.Valid)
	assert.False(t, cs.CatchupTo.Valid)

	applied, err = db.AdvanceCatchup(walk, float64(exclDay1.Add(24*time.Hour).Unix()))
	require.NoError(t, err)
	assert.False(t, applied)
	cs = mustSettings(t, db, "1:C0JUNK")
	assert.False(t, cs.CatchupTo.Valid, "a late advance cannot revive a catch-up of an excluded channel")

	// ABA: Sync again starts a catch-up with the same start; the old walk's
	// advance and finish must not touch it.
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay11.Add(time.Hour)))
	cs = mustSettings(t, db, "1:C0JUNK")
	require.Equal(t, walk.From, cs.CatchupFrom.Float64, "same start as the old walk")
	applied, err = db.AdvanceCatchup(walk, float64(exclDay1.Add(24*time.Hour).Unix()))
	require.NoError(t, err)
	assert.False(t, applied)
	applied, err = db.FinishCatchup(walk)
	require.NoError(t, err)
	assert.False(t, applied)
	cs = mustSettings(t, db, "1:C0JUNK")
	assert.Equal(t, float64(exclDay11.Add(time.Hour).Unix()), cs.CatchupTo.Float64, "the new catch-up is intact")
}

func TestSyncExcludedChannelIDs(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C0JUNK", "1:C0OK", "2:C0JUNK")
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	require.NoError(t, db.SetSyncExcluded("2:C0JUNK", true, exclDay1))
	require.NoError(t, db.SetMuteForLLM("1:C0OK", true))

	got, err := db.SyncExcludedChannelIDs(1)
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"1:C0JUNK": true}, got)
}

func TestMutedAt_SetOnMuteClearedOnUnmute(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C1")

	require.NoError(t, db.SetMuteForLLM("1:C1", true))
	first := mustSettings(t, db, "1:C1").MutedAt
	assert.NotEmpty(t, first)
	_, err := time.Parse(time.RFC3339, first)
	require.NoError(t, err)

	require.NoError(t, db.SetMuteForLLM("1:C1", false))
	assert.Empty(t, mustSettings(t, db, "1:C1").MutedAt)

	muted, err := db.ToggleMuteForLLM("1:C1")
	require.NoError(t, err)
	require.True(t, muted)
	assert.NotEmpty(t, mustSettings(t, db, "1:C1").MutedAt)
	muted, err = db.ToggleMuteForLLM("1:C1")
	require.NoError(t, err)
	require.False(t, muted)
	assert.Empty(t, mustSettings(t, db, "1:C1").MutedAt)

	// A toggle clears the Stop syncing ownership of the mute too.
	require.NoError(t, db.SetSyncExcluded("1:C1", true, exclDay1))
	_, err = db.ToggleMuteForLLM("1:C1")
	require.NoError(t, err)
	_, err = db.ToggleMuteForLLM("1:C1")
	require.NoError(t, err)
	cs := mustSettings(t, db, "1:C1")
	assert.True(t, cs.IsMutedForLLM)
	assert.False(t, cs.MutedByExclusion)
}

func TestMutedAt_FavoriteToggleDoesNotReset(t *testing.T) {
	db := openTestDB(t)
	ensureChannels(t, db, "1:C1")
	require.NoError(t, db.SetSyncExcluded("1:C1", true, exclDay1))

	_, err := db.ToggleFavorite("1:C1")
	require.NoError(t, err)
	require.NoError(t, db.SetFavorite("1:C1", false))

	cs := mustSettings(t, db, "1:C1")
	assert.Equal(t, "2026-11-01T09:00:00Z", cs.MutedAt)
	assert.True(t, cs.MutedByExclusion)
	assert.True(t, cs.IsMutedForLLM)
}

// muteCase is one entry of testdata/channel_mute_cases.json.
type muteCase struct {
	Name   string   `json:"name"`
	Before *muteRow `json:"before"`
	Action string   `json:"action"`
	After  muteRow  `json:"after"`
}

type muteRow struct {
	IsMutedForLLM    int    `json:"is_muted_for_llm"`
	MutedAt          string `json:"muted_at"`
	MutedByExclusion int    `json:"muted_by_exclusion"`
	UpdatedAt        string `json:"updated_at"`
}

// muteCaseSeededUpdatedAt is updated_at of a mute case's before row.
const muteCaseSeededUpdatedAt = "2020-01-01T00:00:00Z"

// TestMuteCases pins the manual mute writer's muted_at/muted_by_exclusion
// rule; the Swift twin reads the same cases.
func TestMuteCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/channel_mute_cases.json")
	require.NoError(t, err)
	var file struct {
		Cases []muteCase `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &file))
	require.NotEmpty(t, file.Cases)

	for _, c := range file.Cases {
		t.Run(c.Name, func(t *testing.T) {
			db := openTestDB(t)
			ensureChannels(t, db, "1:C1")
			if c.Before != nil {
				_, err := db.Exec(`INSERT INTO channel_settings (channel_id, is_muted_for_llm, muted_at, muted_by_exclusion, updated_at)
					VALUES ('1:C1', ?, ?, ?, ?)`, c.Before.IsMutedForLLM, c.Before.MutedAt, c.Before.MutedByExclusion, muteCaseSeededUpdatedAt)
				require.NoError(t, err)
			}
			require.Contains(t, []string{"mute", "unmute"}, c.Action)
			require.NoError(t, db.SetMuteForLLM("1:C1", c.Action == "mute"))

			var got muteRow
			require.NoError(t, db.QueryRow(`SELECT is_muted_for_llm, muted_at, muted_by_exclusion, updated_at
				FROM channel_settings WHERE channel_id = '1:C1'`).Scan(&got.IsMutedForLLM, &got.MutedAt, &got.MutedByExclusion, &got.UpdatedAt))
			assert.Equal(t, c.After.IsMutedForLLM, got.IsMutedForLLM)
			if c.After.UpdatedAt == "$now" {
				assert.NotEmpty(t, got.UpdatedAt)
				assert.NotEqual(t, muteCaseSeededUpdatedAt, got.UpdatedAt)
			}
			assert.Equal(t, c.After.MutedByExclusion, got.MutedByExclusion)
			if c.After.MutedAt == "$now" {
				assert.NotEmpty(t, got.MutedAt)
				if c.Before != nil {
					assert.NotEqual(t, c.Before.MutedAt, got.MutedAt)
				}
			} else {
				assert.Equal(t, c.After.MutedAt, got.MutedAt)
			}
		})
	}
}

// TestSyncAgain_UserMuteFromDesktopSurvives: the Desktop's mute toggle
// (Swift toggleMuteForLLM, pinned by the shared case below) takes over the
// mute Stop syncing set, so neither this Sync again nor a later Stop
// syncing / Sync again round lifts it.
func TestSyncAgain_UserMuteFromDesktopSurvives(t *testing.T) {
	raw, err := os.ReadFile("testdata/channel_mute_cases.json")
	require.NoError(t, err)
	var file struct {
		Cases []muteCase `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &file))
	var takeOver *muteCase
	for i := range file.Cases {
		if file.Cases[i].Name == "muted by Stop syncing, mute takes it over" {
			takeOver = &file.Cases[i]
		}
	}
	require.NotNil(t, takeOver)

	db := openTestDB(t)
	ensureChannels(t, db, "1:C0JUNK")
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay1))
	require.True(t, mustSettings(t, db, "1:C0JUNK").MutedByExclusion)

	// The Desktop writer leaves the case's after row (it keeps the
	// mute's start, so muted_at is a fixed value, not "$now").
	after := takeOver.After
	require.NotEqual(t, "$now", after.MutedAt)
	_, err = db.Exec(`UPDATE channel_settings SET is_muted_for_llm = ?, muted_at = ?, muted_by_exclusion = ?
		WHERE channel_id = '1:C0JUNK'`, after.IsMutedForLLM, after.MutedAt, after.MutedByExclusion)
	require.NoError(t, err)

	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay10))
	assert.True(t, mustSettings(t, db, "1:C0JUNK").IsMutedForLLM, "Sync again lifted the user's mute")
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", true, exclDay10.Add(24*time.Hour)))
	require.NoError(t, db.SetSyncExcluded("1:C0JUNK", false, exclDay10.Add(48*time.Hour)))
	cs := mustSettings(t, db, "1:C0JUNK")
	assert.True(t, cs.IsMutedForLLM, "a second round lifted the user's mute")
	assert.False(t, cs.MutedByExclusion)
	assert.Equal(t, after.MutedAt, cs.MutedAt, "the user's mute keeps its start")
}
