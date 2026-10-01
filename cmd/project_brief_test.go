package cmd

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/projectcheck"
)

func briefNode(id int, status, title string, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{Target: db.Target{ID: id, Status: status, Priority: "medium", Text: title}, Children: children}
}

func briefProject() *db.Project {
	return &db.Project{ID: 7, Name: "acme", FolderPath: "/tmp/acme", Description: "A demo project."}
}

// TestRenderProjectBrief_LargeBoardStaysWithinBudget: whatever the board
// holds, the hook body fits 4000 runes, keeps the rules and says what it cut.
func TestRenderProjectBrief_LargeBoardStaysWithinBudget(t *testing.T) {
	long := strings.Repeat("Implement the next part of the plan ", 8)
	var board []db.BoardNode
	id := 1
	for r := 0; r < 40; r++ {
		root := briefNode(id, "in_progress", long)
		id++
		for c := 0; c < 15; c++ {
			root.Children = append(root.Children, briefNode(id, "todo", "Ünïcödé "+long))
			id++
		}
		board = append(board, root)
	}
	docs := map[int64]db.ProjectDocument{1: {ID: 1, RelPath: "docs/plan.md"}}
	var comments []db.ProjectComment
	for i := 0; i < 150; i++ {
		c := db.ProjectComment{ID: int64(1000 + i), Author: "owner", Body: strings.Repeat("Please revise this. ", 25)}
		if i%2 == 0 {
			c.DocumentID = sql.NullInt64{Int64: 1, Valid: true}
			c.AnchorHeading = strings.Repeat("Heading ", 20)
			c.AnchorQuote = strings.Repeat("quoted text ", 20)
		} else {
			c.TargetID = sql.NullInt64{Int64: 1, Valid: true}
		}
		comments = append(comments, c)
	}
	p := briefProject()
	p.BoardLanguage = strings.Repeat("я", 40)
	p.Name = strings.Repeat("very long name ", 500)
	p.FolderPath = "/tmp/" + strings.Repeat("deep/", 500)

	out := renderProjectBrief(board, p, comments, docs, nil, time.Now())

	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.True(t, utf8.ValidString(out))
	assert.Contains(t, out, "more targets (project_board)")
	assert.Contains(t, out, "more comments (list_comments)")
	assert.Contains(t, out, "Board language: "+p.BoardLanguage, "the language line survives a full board")
	for _, rule := range briefRules {
		assert.Contains(t, out, rule)
	}
}

// PROJ-06 surface: an in_review target is open, counted, and shows how long
// it has held its status.
func TestRenderProjectBrief_InReviewShowsTimeInStatus(t *testing.T) {
	now := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	review := briefNode(8, "in_review", "reviewed task")
	review.StatusSince = "2026-09-30T09:00:00Z"
	out := renderProjectBrief([]db.BoardNode{review}, briefProject(), nil, nil, nil, now)

	assert.Contains(t, out, "Targets: 0 in progress, 1 in review, 0 blocked, 0 todo, 0 done.")
	assert.Contains(t, out, "- #8 [in_review 3h, medium, 0%] reviewed task")
	assert.Contains(t, out, "in_review when its review starts")
}

func TestStatusAge(t *testing.T) {
	now := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	for since, want := range map[string]string{
		"":                     "",
		"not a time":           "",
		"2026-09-30T11:59:30Z": "<1m",
		"2026-09-30T11:48:00Z": "12m",
		"2026-09-30T07:00:00Z": "5h",
		"2026-09-27T11:00:00Z": "3d",
	} {
		assert.Equal(t, want, statusAge(since, now), since)
	}
}

func TestRenderProjectBrief_OpenTreeInProgressFirstDoneOmitted(t *testing.T) {
	board := []db.BoardNode{
		briefNode(3, "in_progress", "active feature", briefNode(4, "todo", "open task")),
		briefNode(1, "todo", "later feature"),
		briefNode(2, "done", "shipped feature", briefNode(5, "todo", "leftover task")),
	}
	out := renderProjectBrief(board, briefProject(), nil, nil, nil, time.Now())

	assert.Contains(t, out, "Targets: 1 in progress, 0 in review, 0 blocked, 3 todo, 1 done.")
	active := strings.Index(out, "#3 [in_progress")
	later := strings.Index(out, "#1 [todo")
	require.NotEqual(t, -1, active)
	require.NotEqual(t, -1, later)
	assert.Less(t, active, later, "in progress first")
	assert.Contains(t, out, "\n  - #4 [todo, medium, 0%] open task", "children are indented under their parent")
	assert.NotContains(t, out, "shipped feature", "done is omitted")
	assert.Contains(t, out, "\n- #5 [todo, medium, 0%] leftover task", "an open child of a done target stays listed")
	assert.Contains(t, out, "New comments for you: none.")
}

// The board sorts siblings by priority first; the brief puts in-progress and
// blocked work before todo whatever its priority, keeping priority order
// within a status, so a long board's active part is never cut off.
func TestRenderProjectBrief_ActiveWorkFirstWhateverItsPriority(t *testing.T) {
	node := func(id int, status, priority string, children ...db.BoardNode) db.BoardNode {
		n := briefNode(id, status, fmt.Sprintf("task %d", id), children...)
		n.Target.Priority = priority
		return n
	}
	// Board order (priority, then status): #4, #1, #2, #3.
	board := []db.BoardNode{node(4, "in_progress", "high"), node(1, "todo", "high"), node(2, "in_progress", "medium"), node(3, "blocked", "low")}
	out := renderProjectBrief(board, briefProject(), nil, nil, nil, time.Now())
	var order []int
	for _, id := range []int{4, 2, 3, 1} {
		i := strings.Index(out, fmt.Sprintf("#%d [", id))
		require.NotEqual(t, -1, i, out)
		order = append(order, i)
	}
	assert.IsIncreasing(t, order, "in progress (by priority), then blocked, then todo")

	// A todo feature whose task is in progress ranks as in progress, and so
	// does a done feature with an open task in progress.
	board = []db.BoardNode{
		node(1, "todo", "high"),
		node(2, "todo", "low", node(3, "in_progress", "medium")),
		node(4, "done", "low", node(5, "in_progress", "low")),
	}
	out = renderProjectBrief(board, briefProject(), nil, nil, nil, time.Now())
	order = nil
	for _, id := range []int{2, 3, 5, 1} {
		i := strings.Index(out, fmt.Sprintf("#%d [", id))
		require.NotEqual(t, -1, i, out)
		order = append(order, i)
	}
	assert.IsIncreasing(t, order, "subtrees with work in progress come first")

	long := strings.Repeat("Implement the next part of the plan ", 4)
	var big []db.BoardNode
	for id := 1; id <= 60; id++ {
		big = append(big, node(id, "todo", "high"))
		big[len(big)-1].Target.Text = long
	}
	big = append(big, node(99, "in_progress", "low"))
	out = renderProjectBrief(big, briefProject(), nil, nil, nil, time.Now())
	assert.Contains(t, out, "more targets (project_board)", "the board is cut")
	assert.Contains(t, out, "#99 [in_progress, low", "the active low-priority task survives the cut")
}

func TestRenderProjectBrief_CommentsTargetsFirstThenDocumentsWithHeadingAndQuote(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	docs := map[int64]db.ProjectDocument{9: {ID: 9, RelPath: "docs/plan.md"}}
	comments := []db.ProjectComment{
		{ID: 21, DocumentID: sql.NullInt64{Int64: 9, Valid: true}, Author: "owner", Body: "Split task 3",
			AnchorHeading: "Task 3", AnchorQuote: "one big step"},
		{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"},
	}
	out := renderProjectBrief(board, briefProject(), comments, docs, nil, time.Now())

	onTarget := strings.Index(out, `comment #22 on target #3 "active feature": Use the new API`)
	onDoc := strings.Index(out, `comment #21 on document #9 docs/plan.md § Task 3 on "one big step": Split task 3`)
	require.NotEqual(t, -1, onTarget, out)
	require.NotEqual(t, -1, onDoc, out)
	assert.Less(t, onTarget, onDoc, "target comments come before document comments")
}

func TestRenderProjectBrief_EmptyProjectAsksForSetup(t *testing.T) {
	p := briefProject()
	p.Description = ""
	out := renderProjectBrief(nil, p, nil, nil, nil, time.Now())
	assert.Contains(t, out, "Setup pending")
	assert.Contains(t, out, "Open targets: none.")
	assert.Contains(t, out, "Board language: follow the session language")
}

func TestRenderProjectBrief_NamesTheBoardLanguageOverride(t *testing.T) {
	p := briefProject()
	p.BoardLanguage = "Russian"
	out := renderProjectBrief(nil, p, nil, nil, nil, time.Now())
	assert.Contains(t, out, "Board language: Russian")
	assert.NotContains(t, out, "follow the session language")
}

func TestProjectBrief_DeletedProjectPrintsOneLineAndExitsZero(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runProject(t, "brief", "--project", "5")
	require.NoError(t, err, "a hook never fails the session start")
	assert.Equal(t, "Watchtower: project 5 no longer exists.\n", out)
}

func TestProjectBrief_MissingFolderPrintsOneLine(t *testing.T) {
	database := writeActionsConfig(t)
	folder := filepath.Join(t.TempDir(), "repo")
	require.NoError(t, os.Mkdir(folder, 0o755))
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	require.NoError(t, os.RemoveAll(folder))

	out, _, err := runProject(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), out)
	assert.Contains(t, out, "is missing")
	assert.Contains(t, out, folder)
}

func TestProjectBrief_UnreadableConfigPrintsOneLine(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: [unclosed\n"), 0o600))
	orig := flagConfig
	flagConfig = cfgPath
	t.Cleanup(func() { flagConfig = orig })

	out, _, err := runProject(t, "brief", "--project", "5")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), out)
	assert.True(t, strings.HasPrefix(out, "Watchtower: project 5 "), out)
}

func TestProjectBrief_NoProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runProject(t, "brief")
	require.NoError(t, err, "a missing --project must never fail cobra's own parsing")
	assert.Equal(t, "Watchtower: project 0 is unavailable: no --project id given.\n", out)
}

func TestProjectBrief_EmptyProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runProject(t, "brief", "--project", "")
	require.NoError(t, err)
	assert.Equal(t, "Watchtower: project 0 is unavailable: no --project id given.\n", out)
}

// TestProjectBrief_NonNumericProjectFlagPrintsOneLine: --project is a string
// flag precisely so a non-numeric value is rejected by loadProjectBriefFlag,
// not by cobra's own flag parser (which would exit non-zero before RunE ever
// ran, breaking the "always exit 0" contract of a SessionStart hook).
func TestProjectBrief_NonNumericProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runProject(t, "brief", "--project", "abc")
	require.NoError(t, err, "an unparseable --project value must never fail cobra's own parsing")
	assert.Equal(t, "Watchtower: project 0 is unavailable: invalid --project value \"abc\".\n", out)
}

func TestProjectBrief_RendersBoardFromDB(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	tid := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "Ship the board")
	require.NoError(t, database.UpdateTargetStatus(int(tid), "in_progress"))
	cid, err := database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: tid, Valid: true},
		Author: "owner", Body: "Keep it small"})
	require.NoError(t, err)

	out, _, err := runProject(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, fmt.Sprintf("#%d [in_progress", tid))
	assert.Contains(t, out, fmt.Sprintf("comment #%d on target #%d", cid, tid))
	assert.Contains(t, out, "Setup pending", "no description yet")
}

// Many drift findings never crowd the brief past its cap or push out the
// open tree (PROJ-07).
func TestRenderProjectBrief_ManyDriftFindingsStayWithinBudget(t *testing.T) {
	board := []db.BoardNode{{Target: db.Target{ID: 1, Text: "Active work", Status: "in_progress", Priority: "high"}}}
	var drift []projectcheck.Finding
	for i := 0; i < 60; i++ {
		drift = append(drift, projectcheck.Finding{TargetID: 100 + i, Title: strings.Repeat("long title ", 10), Status: "in_progress",
			Kind: projectcheck.KindMergedOpen, Detail: "branch x is merged into main", Fix: "set it done"})
	}
	out := renderProjectBrief(board, briefProject(), nil, nil, drift, time.Now())
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, "drift findings (watchtower project check)")
	assert.Contains(t, out, "#1 [in_progress")
}
