package cmd

import (
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchcheck"
	"watchtower/internal/workbenchmethod"
)

// Board columns in the brief (spec 2026-10-16 §5, PROJ-19).

func briefColumnsFixture() db.BoardColumns {
	return db.BoardColumns{Columns: []db.BoardColumn{
		{ID: 1, Status: "todo", Title: "Backlog", Description: "not yet looked at"},
		{ID: 2, Status: "todo", Title: "Ready", Description: "spec agreed, can start"},
		{ID: 3, Status: "in_progress", Title: "Spec", Description: "writing the design"},
		{ID: 4, Status: "in_progress", Title: "Code", Description: "building it"},
		{ID: 5, Status: "done", Title: "Done"},
	}, Hidden: []string{"in_review"}}
}

func TestBriefColumns_Section(t *testing.T) {
	assert.Equal(t, `Board columns (the owner's; move a card with update_target column when its description fits):
- To Do: Backlog — not yet looked at | Ready — spec agreed, can start
- In Progress: Spec — writing the design | Code — building it
- Done: Done
Turned off: in_review (go straight to done once the review passes).`, briefColumnsSection(briefColumnsFixture()))

	both := db.BoardColumns{Columns: []db.BoardColumn{}, Hidden: []string{"in_review", "blocked"}}
	assert.Equal(t, "Turned off: in_review (go straight to done once the review passes); "+
		"blocked (leave it in_progress; the open ask already shows the owner what waits).", briefColumnsSection(both))
}

func TestBriefColumns_LongFallsBackToOneLine(t *testing.T) {
	def := db.BoardColumns{Columns: []db.BoardColumn{}, Hidden: []string{"blocked"}}
	statuses := []string{"todo", "in_progress", "done", "dismissed"} // a hidden status has no columns
	for i := range 20 {
		def.Columns = append(def.Columns, db.BoardColumn{ID: int64(i + 1), Status: statuses[i%len(statuses)],
			Title: fmt.Sprintf("Column %02d", i), Description: strings.Repeat("d", 100)})
	}
	out := briefColumnsSection(def)
	assert.Equal(t, "Board columns: 20 columns defined — read them with workbench_info before you move a card.\n"+
		"Turned off: blocked (leave it in_progress; the open ask already shows the owner what waits).", out)
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefColumnsChars)
}

func TestBriefColumns_TargetLineShowsColumn(t *testing.T) {
	now := time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)
	n := briefNode(3, "in_progress", "active feature")
	n.StatusSince = now.Add(-2 * time.Hour).Format(time.RFC3339)
	n.Target.Progress = 0.4
	assert.Equal(t, "- #3 [in_progress 2h, medium, 40%] active feature", briefTargetLine(n, 0, now))
	n.Column = "Code"
	assert.Equal(t, "- #3 [Code 2h, medium, 40%] active feature", briefTargetLine(n, 0, now))
	n.StatusSince = ""
	assert.Equal(t, "- #3 [Code, medium, 40%] active feature", briefTargetLine(n, 0, now))
}

// PROJ-19 anti-goal: no definition, no change to the brief.
func TestBriefColumns_NoneLeavesBriefUnchanged(t *testing.T) {
	assert.Empty(t, briefColumnsSection(db.BoardColumns{Columns: []db.BoardColumn{}, Hidden: []string{}}))

	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "Alpha feature")
	unsetTerminalEnv(t)
	before, _ := runBriefHook(t, pid, "")
	assert.NotContains(t, before, "Board columns")

	def := briefColumnsFixture()
	for i := range def.Columns {
		def.Columns[i].ID = 0 // new columns of this workbench
	}
	_, err = database.ReplaceBoardColumns(pid, def)
	require.NoError(t, err)
	with, _ := runBriefHook(t, pid, "")
	assert.Contains(t, with, briefColumnsSection(def))
	assert.Regexp(t, `#\d+ \[Backlog[^,]*, medium, 0%\] Alpha feature`, with)

	_, err = database.ReplaceBoardColumns(pid, db.BoardColumns{})
	require.NoError(t, err)
	after, _ := runBriefHook(t, pid, "")
	assert.Equal(t, before, after)
}

// The columns share the reserved rules slot with the folder rules: with both
// at their caps and a full board, the brief still fits briefMaxChars, keeps
// both whole and the board gives way.
func TestBriefColumns_MaximalRulesStayWithinTheBrief(t *testing.T) {
	body := strings.Repeat("я", briefFolderRulesInline)
	e := workbenchmethod.Combine(db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardOff, FinishCheck: workbenchmethod.FinishOff},
		methodFile(body))
	def := db.BoardColumns{Hidden: []string{"in_review", "blocked"}}
	for i := range 8 {
		def.Columns = append(def.Columns, db.BoardColumn{ID: int64(i + 1), Status: []string{"todo", "in_progress", "done"}[i%3],
			Title: fmt.Sprintf("Column %d", i)})
	}
	// Grow the descriptions to the last length that still renders in full.
	columns := briefColumnsSection(def)
	for n := 1; ; n++ {
		for i := range def.Columns {
			def.Columns[i].Description = strings.Repeat("d", n)
		}
		next := briefColumnsSection(def)
		if strings.HasPrefix(next, "Board columns: ") {
			break
		}
		columns = next
	}
	require.Greater(t, utf8.RuneCountInString(columns), briefColumnsChars-40, "the section is near its cap")

	var board []db.BoardNode
	for i := 1; i <= 200; i++ {
		board = append(board, briefNode(i, "todo", strings.Repeat("Implement the next part of the plan ", 8)))
	}
	method := joinBriefLines(briefMethodSection(e, ""), columns)
	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules,
		method, "Cleanup: /usr/local/bin/watchtower workbench cleanup --session 3")

	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, body)
	assert.Contains(t, out, columns)
	assert.Contains(t, out, "\nBoard columns (the owner's;")
	assert.Contains(t, out, "\nTurned off: in_review (")
	assert.Contains(t, out, "more targets (workbench_board)", "the board is what gives way")
}
