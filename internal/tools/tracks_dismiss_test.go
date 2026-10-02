package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedTrack inserts a track with the given origin, last updated `age` ago.
func seedTrack(t *testing.T, d *db.DB, text, origin string, age time.Duration) int {
	t.Helper()
	id, err := d.UpsertTrack(db.Track{Text: text})
	require.NoError(t, err)
	stamp := time.Now().Add(-age).UTC().Format("2006-01-02T15:04:05Z")
	_, err = d.Exec(`UPDATE tracks SET origin = ?, updated_at = ?, created_at = ? WHERE id = ?`, origin, stamp, stamp, id)
	require.NoError(t, err)
	return int(id)
}

func isDismissed(t *testing.T, d *db.DB, id int) bool {
	t.Helper()
	tr, err := d.GetTrackByID(id)
	require.NoError(t, err)
	return tr.DismissedAt != ""
}

func dismissRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewDismissTracks()))
	require.NoError(t, reg.Register(NewGetTrackCounts()))
	return reg
}

func storedDismissArgs(t *testing.T, d *db.DB, actionID int64) dismissTracksArgs {
	t.Helper()
	row, err := d.GetAgentAction(actionID)
	require.NoError(t, err)
	var a dismissTracksArgs
	require.NoError(t, json.Unmarshal([]byte(row.ArgsJSON), &a))
	return a
}

func TestDismissTracks_Registration(t *testing.T) {
	tool := NewDismissTracks()
	assert.Equal(t, AccessWrite, tool.Access)
	assert.False(t, tool.External, "a local soft dismiss never leaves the machine")
	assert.True(t, tool.AlwaysAsk, "a bulk dismiss never auto-executes")
	assert.Equal(t, []string{"main"}, tool.Surfaces, "main chat only — never target, reaction or project")
}

func TestDismissTracks_ValidateRejectsBadInput(t *testing.T) {
	d := openDB(t)
	reg := dismissRegistry(t, d)
	cases := map[string]string{
		"neither":         `{"reason":"r"}`,
		"both":            `{"ids":[1],"filter":{},"reason":"r"}`,
		"bad origin":      `{"filter":{"origin":"manual"},"reason":"r"}`,
		"bad date":        `{"filter":{"updated_before":"last week"},"reason":"r"}`,
		"zero id":         `{"ids":[0],"reason":"r"}`,
		"unknown field":   `{"ids":[1],"reason":"r","all":true}`,
		"pinned by model": `{"ids":[1],"reason":"r","resolved_ids":[1,2,3]}`,
		"unknown id":      `{"ids":[424242],"reason":"r"}`,
		"zero except id":  `{"filter":{"except_ids":[0]},"reason":"r"}`,
		"unknown except":  `{"filter":{"except_ids":[424242]},"reason":"r"}`,
	}
	for name, raw := range cases {
		_, err := reg.Propose(context.Background(), "dismiss_tracks", json.RawMessage(raw), Binding{Surface: "main"})
		var verr *ValidationError
		assert.ErrorAs(t, err, &verr, name)
	}
	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows, "a refused call writes no row")
}

// The owner's ask: "dismiss every track except the newest one".
func TestDismissTracks_FilterPinsIdsAtProposeAndApplyDismissesExactlyThem(t *testing.T) {
	d := openDB(t)
	day := 24 * time.Hour
	newest := seedTrack(t, d, "newest", "auto", time.Hour)
	second := seedTrack(t, d, "second", "auto", 2*day)
	custom := seedTrack(t, d, "owner's custom", "custom", 3*day)
	reg := dismissRegistry(t, d)

	args := `{"filter":{"except_ids":[` + strconv.Itoa(newest) + `]},"reason":"owner wants a clean slate"}`
	rc, err := reg.Propose(context.Background(), "dismiss_tracks", json.RawMessage(args), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.False(t, isDismissed(t, d, second), "propose never writes (AGENT-01)")

	stored := storedDismissArgs(t, d, rc.ActionID)
	assert.Equal(t, []int{second, custom}, stored.ResolvedIDs, "newest update first, newest kept")
	assert.Equal(t, "Dismiss 2 tracks (keeping #"+strconv.Itoa(newest)+")", stored.Summary)
	assert.Equal(t, []string{"second", "owner's custom"}, stored.SampleTitles)

	// A track appearing after the proposal is not swept up by the approval.
	late := seedTrack(t, d, "late", "auto", 0)

	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status)
	assert.JSONEq(t, `{"dismissed":2,"skipped":0}`, applied.ResultJSON)

	assert.True(t, isDismissed(t, d, second))
	assert.True(t, isDismissed(t, d, custom))
	assert.False(t, isDismissed(t, d, newest))
	assert.False(t, isDismissed(t, d, late), "only the ids the card counted are dismissed")

	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition, "applied is terminal (AGENT-05)")
}

func TestDismissTracks_FilterByOriginAndAge(t *testing.T) {
	d := openDB(t)
	day := 24 * time.Hour
	seedTrack(t, d, "fresh auto", "auto", time.Hour)
	stale := seedTrack(t, d, "stale auto", "auto", 60*day)
	seedTrack(t, d, "stale custom", "custom", 60*day)
	reg := dismissRegistry(t, d)

	cutoff := time.Now().Add(-30 * day).UTC().Format("2006-01-02")
	rc, err := reg.Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"filter":{"origin":"auto","updated_before":"`+cutoff+`"},"reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	stored := storedDismissArgs(t, d, rc.ActionID)
	assert.Equal(t, []int{stale}, stored.ResolvedIDs)
	assert.Equal(t, "Dismiss 1 track (auto tracks only; no update since "+cutoff+")", stored.Summary)
}

func TestDismissTracks_IdsDropAlreadyDismissedAndSkipLaterDismissals(t *testing.T) {
	d := openDB(t)
	a := seedTrack(t, d, "a", "auto", time.Hour)
	b := seedTrack(t, d, "b", "auto", 2*time.Hour)
	gone := seedTrack(t, d, "gone", "auto", 3*time.Hour)
	require.NoError(t, d.DismissTrack(gone))
	reg := dismissRegistry(t, d)

	rc, err := reg.Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"ids":[`+strconv.Itoa(b)+`,`+strconv.Itoa(a)+`,`+strconv.Itoa(gone)+`,`+strconv.Itoa(a)+`],"reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	stored := storedDismissArgs(t, d, rc.ActionID)
	assert.Equal(t, []int{a, b}, stored.ResolvedIDs)
	assert.Equal(t, "Dismiss 2 tracks (1 already dismissed)", stored.Summary)

	// Dismissed by hand in the Tracks tab before the owner approves.
	require.NoError(t, d.DismissTrack(b))
	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.JSONEq(t, `{"dismissed":1,"skipped":1,"warning":"1 of 2 tracks were already dismissed or deleted since the proposal"}`,
		applied.ResultJSON, "the card says the approved count no longer held")
}

func TestDismissTracks_AllAlreadyDismissedSaysSo(t *testing.T) {
	d := openDB(t)
	gone := seedTrack(t, d, "gone", "auto", time.Hour)
	require.NoError(t, d.DismissTrack(gone))
	_, err := dismissRegistry(t, d).Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"ids":[`+strconv.Itoa(gone)+`],"reason":"r"}`), Binding{Surface: "main"})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "already dismissed")
}

func TestDismissTracks_NothingMatchesIsRefused(t *testing.T) {
	d := openDB(t)
	only := seedTrack(t, d, "only", "auto", time.Hour)
	reg := dismissRegistry(t, d)
	_, err := reg.Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"filter":{"except_ids":[`+strconv.Itoa(only)+`]},"reason":"r"}`), Binding{Surface: "main"})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "nothing to dismiss")
}

func TestDismissTracks_NeverExecutesWithoutApproval(t *testing.T) {
	d := openDB(t)
	id := seedTrack(t, d, "t", "auto", time.Hour)
	reg := dismissRegistry(t, d)

	assert.ErrorIs(t, reg.SetTrust("dismiss_tracks", TrustExecute), ErrAlwaysAsk)
	// A trust row written behind the registry's back is not honoured either.
	require.NoError(t, d.SetToolTrust("dismiss_tracks", "execute"))
	rc, err := reg.Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"ids":[`+strconv.Itoa(id)+`],"reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.False(t, isDismissed(t, d, id))

	// Nor does a direct-apply session run it inline.
	_, err = reg.Propose(context.Background(), "dismiss_tracks",
		json.RawMessage(`{"ids":[`+strconv.Itoa(id)+`],"reason":"r"}`), Binding{Surface: "main", DirectApply: true})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.False(t, isDismissed(t, d, id))
}

func TestDismissTracks_ExecuteRefusesUnpinnedArgs(t *testing.T) {
	d := openDB(t)
	_, err := NewDismissTracks().Execute(context.Background(), d, Call{Args: json.RawMessage(`{"ids":[1],"reason":"r"}`)})
	assert.Error(t, err)
}

func TestGetTrackCounts_GroupsAndFilters(t *testing.T) {
	d := openDB(t)
	day := 24 * time.Hour
	seedTrack(t, d, "fresh", "auto", time.Hour)
	seedTrack(t, d, "old", "auto", 100*day)
	seedTrack(t, d, "custom", "custom", 10*day)
	reg := dismissRegistry(t, d)

	got, err := reg.CallRead(context.Background(), "get_track_counts", nil, Binding{})
	require.NoError(t, err)
	c := got.(db.TrackCounts)
	assert.Equal(t, 3, c.Active)
	assert.Equal(t, map[string]int{"auto": 2, "custom": 1}, c.ByOrigin)
	assert.Equal(t, map[string]int{"7d": 1, "30d": 1, "older": 1}, c.ByLastUpdate)

	got, err = reg.CallRead(context.Background(), "get_track_counts", json.RawMessage(`{"origin":"auto"}`), Binding{})
	require.NoError(t, err)
	assert.Equal(t, 2, got.(db.TrackCounts).Active)

	_, err = reg.CallRead(context.Background(), "get_track_counts", json.RawMessage(`{"origin":"bogus"}`), Binding{})
	var verr *ValidationError
	assert.ErrorAs(t, err, &verr)
	_, err = reg.CallRead(context.Background(), "get_track_counts", json.RawMessage(`{"created_before":"yesterday"}`), Binding{})
	assert.ErrorAs(t, err, &verr)
}
