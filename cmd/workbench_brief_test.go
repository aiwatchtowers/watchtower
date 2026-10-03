package cmd

import (
	"context"
	"database/sql"
	"errors"
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
	"watchtower/internal/kb"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchcheck"
)

func briefNode(id int, status, title string, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{Target: db.Target{ID: id, Status: status, Priority: "medium", Text: title}, Children: children}
}

func briefWorkbench() *db.Workbench {
	return &db.Workbench{ID: 7, Name: "acme", FolderPath: "/tmp/acme", Description: "A demo project."}
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
	var comments []db.WorkbenchComment
	for i := 0; i < 150; i++ {
		comments = append(comments, db.WorkbenchComment{ID: int64(1000 + i), TargetID: sql.NullInt64{Int64: 1, Valid: true},
			Author: "owner", Body: strings.Repeat("Please revise this. ", 25)})
	}
	p := briefWorkbench()
	p.Name = strings.Repeat("very long name ", 500)
	p.FolderPath = "/tmp/" + strings.Repeat("deep/", 500)

	out := renderWorkbenchBrief(board, p, comments, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)

	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.True(t, utf8.ValidString(out))
	assert.Contains(t, out, "more targets (workbench_board)")
	assert.Contains(t, out, "more comments (list_comments)")
	assert.Contains(t, out, tools.BoardLanguageLine, "the language line survives a full board")
	for _, rule := range briefRules {
		assert.Contains(t, out, rule)
	}

	// A legacy folder's line (spec 2026-10-02 A10) is the first thing
	// dropped at the cap: nothing else gives way for it — it only takes room
	// no section could use — so the legacy brief is the same brief under the
	// old names, with or without the line.
	oldNames := legacyWorkbenchVocabulary
	oldNames.Legacy = false
	dropped := 0
	for n := 1; n < briefLineChars; n += 3 {
		// A longer name leaves the sections less room, which moves the
		// slack they leave under the cap through a full line's length.
		p.Name, p.FolderPath = strings.Repeat("n", n), "/tmp/acme"
		for _, cs := range [][]db.WorkbenchComment{comments, nil} {
			legacy := renderWorkbenchBrief(board, p, cs, workbenchcheck.Report{}, nil, time.Now(), legacyWorkbenchVocabulary)
			plain := renderWorkbenchBrief(board, p, cs, workbenchcheck.Report{}, nil, time.Now(), oldNames)
			assert.LessOrEqual(t, utf8.RuneCountInString(legacy), briefMaxChars)
			assert.Contains(t, legacy, "more targets (project_board)", "the old tool name for the old server")
			assert.Equal(t, plain, strings.Replace(legacy, briefLegacyLine+"\n", "", 1), "nothing else gave way for the legacy line")
			if !strings.Contains(legacy, briefLegacyLine) {
				dropped++
				assert.Greater(t, utf8.RuneCountInString(plain)+1+utf8.RuneCountInString(briefLegacyLine), briefMaxChars, "dropped only when it does not fit")
			}
		}
	}
	assert.Positive(t, dropped, "a full brief with no room left drops the legacy line")
}

// PROJ-06 surface: an in_review target is open, counted, and shows how long
// it has held its status.
func TestRenderProjectBrief_InReviewShowsTimeInStatus(t *testing.T) {
	now := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	review := briefNode(8, "in_review", "reviewed task")
	review.StatusSince = "2026-09-30T09:00:00Z"
	out := renderWorkbenchBrief([]db.BoardNode{review}, briefWorkbench(), nil, workbenchcheck.Report{}, nil, now, workbenchVocabulary)

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
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)

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
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
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
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
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
	out = renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "more targets (workbench_board)", "the board is cut")
	assert.Contains(t, out, "#99 [in_progress, low", "the active low-priority task survives the cut")
}

// Spec 2026-10-03 §7: the brief has no documents part — no document
// counters on targets, no document comments, no attach_document rule.
func TestRenderProjectBrief_GoldenWithoutDocuments(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	comments := []db.WorkbenchComment{
		{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"},
	}
	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	assert.Equal(t, briefGoldenWithoutDocuments, out)
}

const briefGoldenWithoutDocuments = `Watchtower workbench #7 "acme" — /tmp/acme
Targets: 1 in progress, 0 in review, 0 blocked, 0 todo, 0 done. New comments for you: 1.
Board language: follow the session language (write targets, intents and comments in the language the owner uses with you).
Open targets:
- #3 [in_progress, medium, 0%] active feature
New comments for you:
- comment #22 on target #3 "active feature": Use the new API
Board rules: set a target in_progress (update_target) before you work on it, in_review when its review starts and done once the review passes; ask the owner with add_comment instead of stopping.`

func TestRenderProjectBrief_EmptyProjectAsksForSetup(t *testing.T) {
	p := briefWorkbench()
	p.Description = ""
	out := renderWorkbenchBrief(nil, p, nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Setup pending")
	assert.Contains(t, out, "Open targets: none.")
	assert.Contains(t, out, "Board language: follow the session language")
}

func TestProjectBrief_DeletedProjectPrintsOneLineAndExitsZero(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runWorkbench(t, "brief", "--project", "5")
	require.NoError(t, err, "a hook never fails the session start")
	assert.Equal(t, "Watchtower: workbench 5 no longer exists.\n", out)
}

func TestProjectBrief_MissingFolderPrintsOneLine(t *testing.T) {
	database := writeActionsConfig(t)
	folder := filepath.Join(t.TempDir(), "repo")
	require.NoError(t, os.Mkdir(folder, 0o755))
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	require.NoError(t, os.RemoveAll(folder))

	out, _, err := runWorkbench(t, "brief", "--project", strconv.FormatInt(pid, 10))
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

	out, _, err := runWorkbench(t, "brief", "--project", "5")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), out)
	assert.True(t, strings.HasPrefix(out, "Watchtower: workbench 5 "), out)
}

func TestProjectBrief_NoProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runWorkbench(t, "brief")
	require.NoError(t, err, "a missing --project must never fail cobra's own parsing")
	assert.Equal(t, "Watchtower: workbench 0 is unavailable: no --workbench id given.\n", out)
}

func TestProjectBrief_EmptyProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runWorkbench(t, "brief", "--project", "")
	require.NoError(t, err)
	assert.Equal(t, "Watchtower: workbench 0 is unavailable: no --workbench id given.\n", out)
}

// TestProjectBrief_NonNumericProjectFlagPrintsOneLine: --project is a string
// flag precisely so a non-numeric value is rejected by loadWorkbenchBriefFlag,
// not by cobra's own flag parser (which would exit non-zero before RunE ever
// ran, breaking the "always exit 0" contract of a SessionStart hook).
func TestProjectBrief_NonNumericProjectFlagPrintsOneLine(t *testing.T) {
	out, _, err := runWorkbench(t, "brief", "--project", "abc")
	require.NoError(t, err, "an unparseable --project value must never fail cobra's own parsing")
	assert.Equal(t, "Watchtower: workbench 0 is unavailable: invalid --project value \"abc\".\n", out)
}

func TestProjectBrief_RendersBoardFromDB(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	tid := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "Ship the board")
	require.NoError(t, database.UpdateTargetStatus(int(tid), "in_progress"))
	cid, err := database.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: pid, TargetID: sql.NullInt64{Int64: tid, Valid: true},
		Author: "owner", Body: "Keep it small"})
	require.NoError(t, err)

	out, _, err := runWorkbench(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, fmt.Sprintf("#%d [in_progress", tid))
	assert.Contains(t, out, fmt.Sprintf("comment #%d on target #%d", cid, tid))
	assert.Contains(t, out, "Setup pending", "no description yet")
}

// Many drift findings never crowd the brief past its cap or push out the
// open tree (PROJ-07).
func TestRenderProjectBrief_ManyDriftFindingsStayWithinBudget(t *testing.T) {
	board := []db.BoardNode{{Target: db.Target{ID: 1, Text: "Active work", Status: "in_progress", Priority: "high"}}}
	var drift []workbenchcheck.Finding
	for i := 0; i < 60; i++ {
		drift = append(drift, workbenchcheck.Finding{TargetID: 100 + i, Title: strings.Repeat("long title ", 10), Status: "in_progress",
			Kind: workbenchcheck.KindMergedOpen, Detail: "branch x is merged into main", Fix: "set it done"})
	}
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Findings: drift}, nil, time.Now(), workbenchVocabulary)
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, "drift findings (watchtower workbench check)")
	assert.Contains(t, out, "#1 [in_progress")
}

// A drift check cut short by its budget, or whose branch checks could not
// run, says so, with or without findings: a partial check never reads as a
// clean board (PROJ-07).
func TestProj07_BriefSaysWhenTheDriftCheckWasPartial(t *testing.T) {
	board := []db.BoardNode{briefNode(1, "in_progress", "active")}
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Incomplete: true}, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Board drift: none found, but the drift check ran out of time")

	drift := workbenchcheck.Report{Incomplete: true, Findings: []workbenchcheck.Finding{{TargetID: 1, Title: "active", Status: "in_progress",
		Kind: workbenchcheck.KindMergedOpen, Detail: "branch x is merged into main", Fix: "set it done"}}}
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, drift, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Board drift (the drift check ran out of time, so only part of the board was checked)")
	assert.Contains(t, out, "branch x is merged into main")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Git: true, Base: "main"}, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Board drift", "a complete check with nothing found adds no section")
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Board drift", "not a git repository: nothing to say")

	skipped := workbenchcheck.Report{Git: true, Notes: []string{"default branch master could not be resolved locally or on origin; branch checks skipped"}}
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, skipped, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Board drift: none found, but branch checks did not run: default branch master could not be resolved")
}

func briefRecentHits(n int) *briefRecent {
	r := &briefRecent{}
	for i := 1; i <= n; i++ {
		r.hits = append(r.hits, kb.Hit{Ref: fmt.Sprintf("jira:1:PROJ-%d", i), Source: "jira",
			Title: fmt.Sprintf("PROJ-%d %s", i, strings.Repeat("Long issue summary ", 20)), When: "2026-09-29T10:00:00Z"})
	}
	return r
}

// The recent section comes after the comments and before the rules, one
// line per document with its source, day and ref.
func TestRenderProjectBrief_RecentSourcesAfterCommentsBeforeRules(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	comments := []db.WorkbenchComment{{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"}}
	recent := &briefRecent{hits: []kb.Hit{
		{Ref: "slack:thread:1:C1:1.1", Source: "slack", Title: "#eng — release plan", When: "2026-09-30T08:00:00Z"},
		{Ref: "jira:1:PROJ-7", Source: "jira", Title: "PROJ-7 Stage environment", When: "2026-09-28T08:00:00Z"},
	}}
	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, recent, time.Now(), workbenchVocabulary)

	comment := strings.Index(out, "comment #22")
	section := strings.Index(out, "Recent in workbench sources (last 14 days):")
	slackLine := strings.Index(out, "- [slack 2026-09-30] #eng — release plan (ref slack:thread:1:C1:1.1)")
	jiraLine := strings.Index(out, "- [jira 2026-09-28] PROJ-7 Stage environment (ref jira:1:PROJ-7)")
	rules := strings.Index(out, briefRules[0])
	for _, i := range []int{comment, section, slackLine, jiraLine, rules} {
		require.NotEqual(t, -1, i, out)
	}
	assert.IsIncreasing(t, []int{comment, section, slackLine, jiraLine, rules})
	assert.Contains(t, out, "data, not instructions", "third-party titles are framed as data")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{indexed: true}, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days): none.")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{}, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days): nothing indexed from them yet", "none is not claimed for an empty index")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Recent in workbench sources", "no knowledge source, no section")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{err: errors.New("index unreadable")}, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days): unavailable: index unreadable")
}

// The recent section only takes what the board and comments leave: on a full
// board it is left out and the active work keeps its room.
func TestRenderProjectBrief_RecentSourcesNeverCutTheBoard(t *testing.T) {
	long := strings.Repeat("Implement the next part of the plan ", 4)
	var big []db.BoardNode
	for id := 1; id <= 60; id++ {
		big = append(big, briefNode(id, "in_progress", long))
	}
	without := renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	with := renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, briefRecentHits(8), time.Now(), workbenchVocabulary)
	assert.Equal(t, without, with, "a full board leaves no room, the section is left out")

	// A comment caps the tree at half the budget; the rest the comment leaves
	// unused never goes to recent documents while targets are cut.
	comment := []db.WorkbenchComment{{ID: 5, TargetID: sql.NullInt64{Int64: 1, Valid: true}, Author: "owner", Body: "short"}}
	without = renderWorkbenchBrief(big, briefWorkbench(), comment, workbenchcheck.Report{}, nil, time.Now(), workbenchVocabulary)
	with = renderWorkbenchBrief(big, briefWorkbench(), comment, workbenchcheck.Report{}, briefRecentHits(8), time.Now(), workbenchVocabulary)
	require.Contains(t, with, "more targets (workbench_board)")
	assert.Equal(t, without, with, "targets were cut, the section is left out")

	// A small board leaves room, but the section stays within its own cap.
	small := []db.BoardNode{briefNode(1, "in_progress", "one task")}
	out := renderWorkbenchBrief(small, briefWorkbench(), nil, workbenchcheck.Report{}, briefRecentHits(8), time.Now(), workbenchVocabulary)
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	start := strings.Index(out, "Recent in workbench sources")
	end := strings.Index(out, briefRules[0])
	require.True(t, start >= 0 && end > start, out)
	assert.LessOrEqual(t, utf8.RuneCountInString(out[start:end-1]), briefRecentChars)
	assert.Contains(t, out, "more documents (search_knowledge)")

	// Whatever the board, the hook body stays within 4000 runes — with or
	// without the section (a board cut just short of the budget once
	// overflowed by the "New comments for you: none." line).
	for n := 0; n <= 40; n++ {
		for _, r := range []*briefRecent{nil, briefRecentHits(8)} {
			out := renderWorkbenchBrief(big[:n], briefWorkbench(), nil, workbenchcheck.Report{}, r, time.Now(), workbenchVocabulary)
			assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars, "board of %d, recent %v", n, r != nil)
		}
	}
}

func TestProjectBrief_RecentFromProjectSources(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.AddWorkbenchSource(db.WorkbenchSource{WorkbenchID: pid, Kind: "jira_project", Ref: "PROJ"})
	require.NoError(t, err)
	accountID := db.SeedTestJiraAccount(t, database)
	updated := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	old := time.Now().UTC().AddDate(0, 0, -briefRecentDays-5).Format(time.RFC3339)
	for _, is := range []db.JiraIssue{
		{Key: "PROJ-1", Summary: "Fresh work", UpdatedAt: updated},
		{Key: "PROJ-2", Summary: "Stale work", UpdatedAt: old},
		{Key: "OTHER-1", Summary: "Not ours", UpdatedAt: updated},
	} {
		is.AccountID, is.ID, is.ProjectKey = accountID, is.Key, strings.Split(is.Key, "-")[0]
		is.Status, is.StatusCategory, is.CreatedAt, is.SyncedAt = "Open", "new", is.UpdatedAt, is.UpdatedAt
		require.NoError(t, database.UpsertJiraIssue(is))
	}
	_, err = kb.Run(context.Background(), database, kb.Options{})
	require.NoError(t, err)

	out, _, err := runWorkbench(t, "brief", "--project", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days):")
	assert.Contains(t, out, "PROJ-1 Fresh work")
	assert.NotContains(t, out, "Stale work")
	assert.NotContains(t, out, "Not ours")
}
