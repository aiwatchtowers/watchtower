package coach

import (
	"database/sql"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
)

// addSuggestion stores an open suggestion last seen at `at` and returns its id.
func addSuggestion(t *testing.T, d *db.DB, text string, f db.InstructionField, wb int64, sessions int, at time.Time) int64 {
	t.Helper()
	s := db.InstructionSuggestion{Text: text, Field: f, SessionCount: sessions, WorkbenchCount: 1, Fingerprint: "fp:" + text}
	if wb != 0 {
		s.WorkbenchID = sql.NullInt64{Int64: wb, Valid: true}
	}
	require.NoError(t, d.UpsertInstructionSuggestion(s, at))
	var id int64
	require.NoError(t, d.QueryRow(`SELECT id FROM instruction_suggestions WHERE fingerprint = ?`, s.Fingerprint).Scan(&id))
	return id
}

func movedTo(t *testing.T, d *db.DB, id int64) sql.NullInt64 {
	t.Helper()
	s, err := d.GetInstructionSuggestion(id)
	require.NoError(t, err)
	return s.MovedTo
}

func TestImportSuggestions_CarriesNewestIntoFreeSlots(t *testing.T) {
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Keep commits small."))
	_, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: "busy", Kind: "add", Destination: DestPromptAdd,
		PromptID: "review.spec", Title: "t", Why: "w", Metric: "review_findings", AfterText: "x", Sources: 3}, sigNow)
	require.NoError(t, err)

	oldest := addSuggestion(t, d.DB, "Answer briefly", db.InstructionChat, 0, 3, sigNow.Add(-4*time.Hour))
	newest := addSuggestion(t, d.DB, "Run the linter first", db.InstructionSession, 0, 5, sigNow.Add(-time.Hour))
	second := addSuggestion(t, d.DB, "Update the changelog", db.InstructionProcedure, wb, 4, sigNow.Add(-2*time.Hour))
	third := addSuggestion(t, d.DB, "Write a test first", db.InstructionProcedure, 0, 3, sigNow.Add(-3*time.Hour))

	n, err := ImportSuggestions(d.DB, "", sigNow)
	require.NoError(t, err)
	assert.Equal(t, 2, n, "two free slots")

	open, err := d.ListCoachProposals("open") // newest id first
	require.NoError(t, err)
	require.Len(t, open, 3)
	carried, next := open[1], open[0]
	assert.Equal(t, sql.NullInt64{Int64: carried.ID, Valid: true}, movedTo(t, d.DB, newest))
	assert.Equal(t, sql.NullInt64{Int64: next.ID, Valid: true}, movedTo(t, d.DB, second))
	assert.Equal(t, sql.NullInt64{Int64: -1, Valid: true}, movedTo(t, d.DB, third))
	assert.Equal(t, sql.NullInt64{Int64: -1, Valid: true}, movedTo(t, d.DB, oldest))

	assert.Equal(t, db.CoachProposal{ID: carried.ID, Fingerprint: carried.Fingerprint, Kind: "add", Destination: DestSession,
		Title: "Run the linter first", Why: "You said this in 5 sessions", Metric: "owner_loop",
		BeforeText: "Keep commits small.", AfterText: "Keep commits small.\nRun the linter first",
		Evidence: []db.CoachEvidence{{Kind: "suggestion", Ref: "sg:" + strconv.FormatInt(newest, 10)}},
		Sources:  5, Status: "open", CreatedAt: carried.CreatedAt}, carried)
	assert.Equal(t, DestProcedure, next.Destination)
	assert.Equal(t, wb, next.WorkbenchID)
	assert.Equal(t, "", next.BeforeText)
	assert.Equal(t, "Update the changelog", next.AfterText)
	assert.Equal(t, 4, next.Sources)

	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Keep commits small.", g.Session, "the fold changes no text")
}

func TestImportSuggestions_OneShot(t *testing.T) {
	d := openDBs(t)
	a := addSuggestion(t, d.DB, "Run the linter first", db.InstructionSession, 0, 3, sigNow)
	n, err := ImportSuggestions(d.DB, "", sigNow)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	before, err := d.ListCoachProposals()
	require.NoError(t, err)

	// A declined proposal frees a slot; the fold still never runs again.
	require.NoError(t, d.DecideCoachProposal(before[0].ID, "open", "declined", sigNow))
	n, err = ImportSuggestions(d.DB, "", sigNow.Add(time.Hour))
	require.NoError(t, err)
	assert.Zero(t, n)
	after, err := d.ListCoachProposals()
	require.NoError(t, err)
	assert.Len(t, after, 1)
	assert.Equal(t, sql.NullInt64{Int64: before[0].ID, Valid: true}, movedTo(t, d.DB, a))
}

func TestImportSuggestions_InvalidRowRetired(t *testing.T) {
	d := openDBs(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, strings.Repeat("a", instructions.MaxRunes-5)))
	over := addSuggestion(t, d.DB, "Run the linter first", db.InstructionSession, 0, 3, sigNow)
	valid := addSuggestion(t, d.DB, "Write a test first", db.InstructionProcedure, 0, 3, sigNow.Add(-time.Hour))
	for i := 0; i < 2; i++ { // fill two of the three slots
		_, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: "busy" + strconv.Itoa(i), Kind: "add",
			Destination: DestPromptAdd, PromptID: "p" + strconv.Itoa(i), Title: "t", Why: "w", Metric: "owner_loop",
			AfterText: "x", Sources: 3}, sigNow)
		require.NoError(t, err)
	}

	n, err := ImportSuggestions(d.DB, "", sigNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, sql.NullInt64{Int64: -1, Valid: true}, movedTo(t, d.DB, over), "over the budget: retired")
	m := movedTo(t, d.DB, valid)
	require.True(t, m.Valid)
	p, err := d.GetCoachProposal(m.Int64)
	require.NoError(t, err)
	assert.Equal(t, "Write a test first", p.AfterText, "the next valid row takes the slot")
}

func TestImportSuggestions_WhyInLanguage(t *testing.T) {
	for _, tc := range []struct {
		lang string
		n    int
		want string
	}{
		{"", 3, "You said this in 3 sessions"},
		{"English", 4, "You said this in 4 sessions"},
		{"Russian", 3, "Ты говорил это в 3 сессиях"},
		{"ru", 21, "Ты говорил это в 21 сессии"},
		{"русский", 11, "Ты говорил это в 11 сессиях"},
	} {
		d := openDBs(t)
		addSuggestion(t, d.DB, "Run the linter first", db.InstructionSession, 0, tc.n, sigNow)
		_, err := ImportSuggestions(d.DB, tc.lang, sigNow)
		require.NoError(t, err)
		open, err := d.ListCoachProposals("open")
		require.NoError(t, err)
		require.Len(t, open, 1)
		assert.Equal(t, tc.want, open[0].Why, tc.lang)
	}
}
