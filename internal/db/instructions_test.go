package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOwnerInstructions_RoundTripAndClear(t *testing.T) {
	d := openTestDB(t)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{}, got)

	require.NoError(t, d.SetOwnerInstruction(InstructionSession, "be terse"))
	require.NoError(t, d.SetOwnerInstruction(InstructionProcedure, "tests first"))
	require.NoError(t, d.SetOwnerInstruction(InstructionSession, "be very terse"))
	got, err = d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{Session: "be very terse", Procedure: "tests first"}, got)

	require.NoError(t, d.SetOwnerInstruction(InstructionSession, ""))
	got, err = d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{Procedure: "tests first"}, got)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM owner_instructions`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestWorkbenchInstructions_RoundTripNullWhenEmpty(t *testing.T) {
	d := openTestDB(t)
	id := newTestWorkbench(t, d)
	got, err := d.GetWorkbenchInstructions(id)
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{}, got)

	require.NoError(t, d.SetWorkbenchInstruction(id, InstructionSession, "s"))
	require.NoError(t, d.SetWorkbenchInstruction(id, InstructionProcedure, "p"))
	got, err = d.GetWorkbenchInstructions(id)
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{Session: "s", Procedure: "p"}, got)

	require.NoError(t, d.SetWorkbenchInstruction(id, InstructionSession, ""))
	var s, p sql.NullString
	require.NoError(t, d.QueryRow(`SELECT session_instructions, target_procedure FROM projects WHERE id = ?`, id).Scan(&s, &p))
	assert.False(t, s.Valid)
	assert.True(t, p.Valid)

	_, err = d.GetWorkbenchInstructions(9999)
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
	assert.ErrorIs(t, d.SetWorkbenchInstruction(9999, InstructionSession, "x"), ErrWorkbenchNotFound)
}

func sugg(fp string) InstructionSuggestion {
	return InstructionSuggestion{Text: "run lint", Field: InstructionSession, SessionCount: 3, WorkbenchCount: 1, Fingerprint: fp}
}

func TestInstructionSuggestion_UpsertRefreshesOpenOnly(t *testing.T) {
	d := openTestDB(t)
	t1 := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	t2 := t1.Add(24 * time.Hour)
	require.NoError(t, d.UpsertInstructionSuggestion(sugg("fp1"), t1))
	s := sugg("fp1")
	s.Text, s.SessionCount, s.WorkbenchCount = "run lint always", 5, 2
	require.NoError(t, d.UpsertInstructionSuggestion(s, t2))

	open, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "run lint always", open[0].Text)
	assert.Equal(t, 5, open[0].SessionCount)
	assert.Equal(t, 2, open[0].WorkbenchCount)
	assert.Equal(t, "open", open[0].Status)
	assert.Equal(t, "2026-10-01T09:00:00Z", open[0].FirstSeenAt)
	assert.Equal(t, "2026-10-02T09:00:00Z", open[0].LastSeenAt)

	require.NoError(t, d.DecideInstructionSuggestion(open[0].ID, "dismissed", t2))
	s.Text, s.SessionCount = "other", 9
	require.NoError(t, d.UpsertInstructionSuggestion(s, t2.Add(time.Hour)))
	got, err := d.GetInstructionSuggestion(open[0].ID)
	require.NoError(t, err)
	assert.Equal(t, "dismissed", got.Status)
	assert.Equal(t, "run lint always", got.Text)
	assert.Equal(t, 5, got.SessionCount)
	assert.Equal(t, "2026-10-02T09:00:00Z", got.LastSeenAt)

	fps, err := d.ListInstructionSuggestionFingerprints()
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"fp1": "dismissed"}, fps)
	open, err = d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	assert.Empty(t, open)
}

func TestInstructionSuggestion_ListNewestFirst(t *testing.T) {
	d := openTestDB(t)
	t1 := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertInstructionSuggestion(sugg("a"), t1))
	require.NoError(t, d.UpsertInstructionSuggestion(sugg("b"), t1.Add(time.Hour)))
	open, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	require.Len(t, open, 2)
	assert.Equal(t, "b", open[0].Fingerprint)
}

func TestInstructionSuggestion_DecideOnlyFromOpen(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertInstructionSuggestion(sugg("fp"), now))
	open, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	id := open[0].ID
	require.NoError(t, d.DecideInstructionSuggestion(id, "added", now))
	assert.Error(t, d.DecideInstructionSuggestion(id, "dismissed", now))
	assert.Error(t, d.DecideInstructionSuggestion(id, "open", now))
	assert.Error(t, d.DecideInstructionSuggestion(9999, "added", now))
	got, err := d.GetInstructionSuggestion(id)
	require.NoError(t, err)
	assert.Equal(t, "added", got.Status)
}

func TestAddInstructionSuggestion_WritesTextAndMarksAtomically(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)

	g := sugg("global")
	g.Field = InstructionProcedure
	require.NoError(t, d.UpsertInstructionSuggestion(g, now))
	wb := newTestWorkbench(t, d)
	w := sugg("wb")
	w.WorkbenchID = nullID(wb)
	require.NoError(t, d.UpsertInstructionSuggestion(w, now))
	open, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	require.Len(t, open, 2)
	ids := map[string]int64{}
	for _, o := range open {
		ids[o.Fingerprint] = o.ID
	}

	require.NoError(t, d.AddInstructionSuggestion(ids["global"], "global body", now))
	oi, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{Procedure: "global body"}, oi)

	require.NoError(t, d.AddInstructionSuggestion(ids["wb"], "wb body", now))
	wi, err := d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Equal(t, OwnerInstructions{Session: "wb body"}, wi)

	for _, id := range ids {
		got, err := d.GetInstructionSuggestion(id)
		require.NoError(t, err)
		assert.Equal(t, "added", got.Status)
	}

	// Not open any more: error, and the instruction is not overwritten.
	assert.Error(t, d.AddInstructionSuggestion(ids["wb"], "again", now))
	wi, err = d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Equal(t, "wb body", wi.Session)
}
