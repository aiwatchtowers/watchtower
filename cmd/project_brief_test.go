package cmd

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func briefNode(id int, status, title string, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{Target: db.Target{ID: id, Status: status, Text: title}, Children: children}
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
	p.Name = strings.Repeat("very long name ", 500)
	p.FolderPath = "/tmp/" + strings.Repeat("deep/", 500)

	out := renderProjectBrief(board, p, comments, docs)

	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.True(t, utf8.ValidString(out))
	assert.Contains(t, out, "more targets (project_board)")
	assert.Contains(t, out, "more comments (list_comments)")
	for _, rule := range briefRules {
		assert.Contains(t, out, rule)
	}
}

func TestRenderProjectBrief_OpenTreeInProgressFirstDoneOmitted(t *testing.T) {
	board := []db.BoardNode{
		briefNode(3, "in_progress", "active feature", briefNode(4, "todo", "open task")),
		briefNode(1, "todo", "later feature"),
		briefNode(2, "done", "shipped feature", briefNode(5, "todo", "leftover task")),
	}
	out := renderProjectBrief(board, briefProject(), nil, nil)

	assert.Contains(t, out, "Targets: 1 in progress, 0 blocked, 3 todo, 1 done.")
	active := strings.Index(out, "#3 [in_progress")
	later := strings.Index(out, "#1 [todo")
	require.NotEqual(t, -1, active)
	require.NotEqual(t, -1, later)
	assert.Less(t, active, later, "in progress first")
	assert.Contains(t, out, "\n  - #4 [todo 0%] open task", "children are indented under their parent")
	assert.NotContains(t, out, "shipped feature", "done is omitted")
	assert.Contains(t, out, "\n- #5 [todo 0%] leftover task", "an open child of a done target stays listed")
	assert.Contains(t, out, "New comments for you: none.")
}

func TestRenderProjectBrief_CommentsTargetsFirstThenDocumentsWithHeadingAndQuote(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	docs := map[int64]db.ProjectDocument{9: {ID: 9, RelPath: "docs/plan.md"}}
	comments := []db.ProjectComment{
		{ID: 21, DocumentID: sql.NullInt64{Int64: 9, Valid: true}, Author: "owner", Body: "Split task 3",
			AnchorHeading: "Task 3", AnchorQuote: "one big step"},
		{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"},
	}
	out := renderProjectBrief(board, briefProject(), comments, docs)

	onTarget := strings.Index(out, `comment #22 on target #3 "active feature": Use the new API`)
	onDoc := strings.Index(out, `comment #21 on document #9 docs/plan.md § Task 3 on "one big step": Split task 3`)
	require.NotEqual(t, -1, onTarget, out)
	require.NotEqual(t, -1, onDoc, out)
	assert.Less(t, onTarget, onDoc, "target comments come before document comments")
}

func TestRenderProjectBrief_EmptyProjectAsksForSetup(t *testing.T) {
	p := briefProject()
	p.Description = ""
	out := renderProjectBrief(nil, p, nil, nil)
	assert.Contains(t, out, "Setup pending")
	assert.Contains(t, out, "Open targets: none.")
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
	require.NoError(t, err)
	assert.Equal(t, "Watchtower: project 0 is unavailable: no --project id given.\n", out)
}

func TestProjectBrief_RendersBoardFromDB(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	tid, err := database.CreateProjectTarget(pid, sql.NullInt64{}, "Ship the board", "")
	require.NoError(t, err)
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
