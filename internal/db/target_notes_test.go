package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedTargetJSON creates a target whose notes/sub_items are the given JSON
// and whose updated_at is in the past, so a write's bump is visible.
func seedTargetJSON(t *testing.T, d *DB, notes, subItems string) int {
	t.Helper()
	id, err := d.CreateTarget(Target{Text: "Ship the billing migration", Status: "todo", Priority: "medium",
		Ownership: "mine", SourceType: "manual", Notes: notes, SubItems: subItems})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	return int(id)
}

func targetColumns(t *testing.T, d *DB, id int) (notes, subItems, updatedAt string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT notes, sub_items, updated_at FROM targets WHERE id = ?`, id).
		Scan(&notes, &subItems, &updatedAt))
	return notes, subItems, updatedAt
}

func TestAppendTargetNote_AppendsWithCreatedAt(t *testing.T) {
	d := openTestDB(t)
	id := seedTargetJSON(t, d, `[{"text":"a","created_at":"2026-10-01T09:00:00Z"}]`, "[]")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.AppendTargetNoteTx(tx, id, "b", "2026-10-22T10:00:00Z")
	}))

	notes, _, updatedAt := targetColumns(t, d, id)
	// The keys are the Swift TargetNote CodingKeys (text, created_at): a
	// Go↔Swift dual path, so decode into exactly those keys.
	var got []map[string]any
	require.NoError(t, json.Unmarshal([]byte(notes), &got))
	assert.Equal(t, []map[string]any{
		{"text": "a", "created_at": "2026-10-01T09:00:00Z"},
		{"text": "b", "created_at": "2026-10-22T10:00:00Z"},
	}, got)
	assert.NotEqual(t, "2000-01-01T00:00:00Z", updatedAt, "updated_at moved, as the Desktop's notes write does")
}

func TestAppendTargetSubItem_AppendsNotDone(t *testing.T) {
	d := openTestDB(t)
	id := seedTargetJSON(t, d, "[]", "[]")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.AppendTargetSubItemTx(tx, id, "x")
	}))

	_, subItems, updatedAt := targetColumns(t, d, id)
	// The Swift TargetSubItem CodingKeys (text, done; due_date only when set).
	var got []map[string]any
	require.NoError(t, json.Unmarshal([]byte(subItems), &got))
	assert.Equal(t, []map[string]any{{"text": "x", "done": false}}, got)
	assert.NotEqual(t, "2000-01-01T00:00:00Z", updatedAt)
}

// An existing entry keeps every key it carries (a sub-item's due_date, a key
// a later Desktop version adds): the append never re-encodes the old entries.
func TestAppendTargetSubItem_KeepsExistingEntriesVerbatim(t *testing.T) {
	d := openTestDB(t)
	id := seedTargetJSON(t, d, "[]", `[{"text":"old","done":true,"due_date":"2026-11-01","extra":7}]`)

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.AppendTargetSubItemTx(tx, id, "new")
	}))

	_, subItems, _ := targetColumns(t, d, id)
	var got []map[string]any
	require.NoError(t, json.Unmarshal([]byte(subItems), &got))
	assert.Equal(t, []map[string]any{
		{"text": "old", "done": true, "due_date": "2026-11-01", "extra": float64(7)},
		{"text": "new", "done": false},
	}, got)
}

func TestAppendTarget_MissingTargetIsNotFound(t *testing.T) {
	d := openTestDB(t)
	err := d.WithTx(func(tx *sql.Tx) error { return d.AppendTargetNoteTx(tx, 999, "b", "2026-10-22T10:00:00Z") })
	assert.True(t, errors.Is(err, sql.ErrNoRows), "got %v", err)
	err = d.WithTx(func(tx *sql.Tx) error { return d.AppendTargetSubItemTx(tx, 999, "x") })
	assert.True(t, errors.Is(err, sql.ErrNoRows), "got %v", err)
}

// A column that does not hold a JSON array is never overwritten: the write
// fails and the stored text stays as it was.
func TestAppendTarget_MalformedColumnIsRefused(t *testing.T) {
	d := openTestDB(t)
	id := seedTargetJSON(t, d, "not json", "[]")
	err := d.WithTx(func(tx *sql.Tx) error { return d.AppendTargetNoteTx(tx, id, "b", "2026-10-22T10:00:00Z") })
	require.Error(t, err)
	notes, _, _ := targetColumns(t, d, id)
	assert.Equal(t, "not json", notes)
}

func TestTrackEvent_GetAndClaim(t *testing.T) {
	d := openTestDB(t)
	trackID, err := d.CreateCustomTrack(Track{Text: "Billing migration"})
	require.NoError(t, err)
	evID, err := d.InsertTrackEvent(TrackEvent{TrackID: int(trackID), Summary: "Rollout finished",
		ProposedAction: `{"type":"update_status","status":"done"}`, ActionStatus: "pending"})
	require.NoError(t, err)

	e, err := d.GetTrackEvent(evID)
	require.NoError(t, err)
	assert.Equal(t, int(trackID), e.TrackID)
	assert.Equal(t, "pending", e.ActionStatus)

	_, err = d.GetTrackEvent(evID + 100)
	assert.True(t, errors.Is(err, sql.ErrNoRows), "a missing event is sql.ErrNoRows wrapped, got %v", err)

	claim := func() bool {
		var ok bool
		require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
			var err error
			ok, err = d.ClaimTrackEventActionTx(tx, evID)
			return err
		}))
		return ok
	}
	assert.True(t, claim(), "pending → applied")
	assert.False(t, claim(), "only one claim wins")
	e, err = d.GetTrackEvent(evID)
	require.NoError(t, err)
	assert.Equal(t, "applied", e.ActionStatus)
}
