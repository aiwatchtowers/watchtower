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

	out := renderWorkbenchBrief(board, p, comments, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)

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
			legacy := renderWorkbenchBrief(board, p, cs, workbenchcheck.Report{}, nil, nil, time.Now(), legacyWorkbenchVocabulary)
			plain := renderWorkbenchBrief(board, p, cs, workbenchcheck.Report{}, nil, nil, time.Now(), oldNames)
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
	out := renderWorkbenchBrief([]db.BoardNode{review}, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, now, workbenchVocabulary)

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
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)

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
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
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
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
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
	out = renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
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
	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
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
	out := renderWorkbenchBrief(nil, p, nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
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
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Findings: drift}, nil, nil, time.Now(), workbenchVocabulary)
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, "drift findings (watchtower workbench check)")
	assert.Contains(t, out, "#1 [in_progress")
}

// A drift check cut short by its budget, or whose branch checks could not
// run, says so, with or without findings: a partial check never reads as a
// clean board (PROJ-07).
func TestProj07_BriefSaysWhenTheDriftCheckWasPartial(t *testing.T) {
	board := []db.BoardNode{briefNode(1, "in_progress", "active")}
	out := renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Incomplete: true}, nil, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Board drift: none found, but the drift check ran out of time")

	drift := workbenchcheck.Report{Incomplete: true, Findings: []workbenchcheck.Finding{{TargetID: 1, Title: "active", Status: "in_progress",
		Kind: workbenchcheck.KindMergedOpen, Detail: "branch x is merged into main", Fix: "set it done"}}}
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, drift, nil, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Board drift (the drift check ran out of time, so only part of the board was checked)")
	assert.Contains(t, out, "branch x is merged into main")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{Git: true, Base: "main"}, nil, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Board drift", "a complete check with nothing found adds no section")
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Board drift", "not a git repository: nothing to say")

	skipped := workbenchcheck.Report{Git: true, Notes: []string{"default branch master could not be resolved locally or on origin; branch checks skipped"}}
	out = renderWorkbenchBrief(board, briefWorkbench(), nil, skipped, nil, nil, time.Now(), workbenchVocabulary)
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
	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, recent, nil, time.Now(), workbenchVocabulary)

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

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{indexed: true}, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days): none.")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{}, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Recent in workbench sources (last 14 days): nothing indexed from them yet", "none is not claimed for an empty index")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	assert.NotContains(t, out, "Recent in workbench sources", "no knowledge source, no section")

	out = renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, &briefRecent{err: errors.New("index unreadable")}, nil, time.Now(), workbenchVocabulary)
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
	without := renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	with := renderWorkbenchBrief(big, briefWorkbench(), nil, workbenchcheck.Report{}, briefRecentHits(8), nil, time.Now(), workbenchVocabulary)
	assert.Equal(t, without, with, "a full board leaves no room, the section is left out")

	// A comment caps the tree at half the budget; the rest the comment leaves
	// unused never goes to recent documents while targets are cut.
	comment := []db.WorkbenchComment{{ID: 5, TargetID: sql.NullInt64{Int64: 1, Valid: true}, Author: "owner", Body: "short"}}
	without = renderWorkbenchBrief(big, briefWorkbench(), comment, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	with = renderWorkbenchBrief(big, briefWorkbench(), comment, workbenchcheck.Report{}, briefRecentHits(8), nil, time.Now(), workbenchVocabulary)
	require.Contains(t, with, "more targets (workbench_board)")
	assert.Equal(t, without, with, "targets were cut, the section is left out")

	// A small board leaves room, but the section stays within its own cap.
	small := []db.BoardNode{briefNode(1, "in_progress", "one task")}
	out := renderWorkbenchBrief(small, briefWorkbench(), nil, workbenchcheck.Report{}, briefRecentHits(8), nil, time.Now(), workbenchVocabulary)
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
			out := renderWorkbenchBrief(big[:n], briefWorkbench(), nil, workbenchcheck.Report{}, r, nil, time.Now(), workbenchVocabulary)
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

func briefAnswered(id int64, kind, title string, answeredAgo time.Duration) db.OwnerAsk {
	return db.OwnerAsk{ID: id, Kind: kind, Title: title, Status: "answered",
		AnsweredAt: time.Now().UTC().Add(-answeredAgo).Format(time.RFC3339)}
}

// Spec 2026-10-03 Part 5: the answered asks come right after the new
// comments, one line each, then the count of other sessions' answers.
func TestRenderProjectBrief_GoldenAnsweredAsks(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	comments := []db.WorkbenchComment{
		{ID: 22, TargetID: sql.NullInt64{Int64: 3, Valid: true}, Author: "owner", Body: "Use the new API"},
	}
	answered := &briefAsks{list: []db.OwnerAsk{
		briefAnswered(4, "review", "Design doc\nround 2\x1b[31m", 3*time.Hour),
		briefAnswered(9, "question", "Which API?", 30*time.Second),
		{ID: 11, Kind: "check", Title: "Smoke test", Status: "answered"}, // no time: no age
	}, others: 2}
	recent := &briefRecent{indexed: true}

	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, recent, answered, time.Now(), workbenchVocabulary)

	assert.Equal(t, briefGoldenAnsweredAsks, out)
}

const briefGoldenAnsweredAsks = `Watchtower workbench #7 "acme" — /tmp/acme
Targets: 1 in progress, 0 in review, 0 blocked, 0 todo, 0 done. New comments for you: 1.
Board language: follow the session language (write targets, intents and comments in the language the owner uses with you).
Open targets:
- #3 [in_progress, medium, 0%] active feature
New comments for you:
- comment #22 on target #3 "active feature": Use the new API
Answered asks for you:
#4 review — Design doc round 2 [31m (answered 3h) → get_ask 4
#9 question — Which API? (answered <1m) → get_ask 9
#11 check — Smoke test (answered) → get_ask 11
2 more answered for other sessions of this workbench — leave them to those sessions.
Recent in workbench sources (last 14 days): none.
Board rules: set a target in_progress (update_target) before you work on it, in_review when its review starts and done once the review passes; ask the owner with add_comment instead of stopping.`

// No answered ask at all leaves the section out; only other sessions'
// answers still say so; a read failure is one line, the brief stays.
func TestRenderProjectBrief_AnsweredAsksAbsentCountOnlyAndError(t *testing.T) {
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}
	render := func(a *briefAsks) string {
		return renderWorkbenchBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, a, time.Now(), workbenchVocabulary)
	}
	without := render(nil)
	assert.NotContains(t, without, briefAsksTitle)
	assert.Equal(t, without, render(&briefAsks{}), "no answered asks: no section")

	out := render(&briefAsks{others: 1})
	assert.Contains(t, out, "New comments for you: none.\nAnswered asks for you: none.\n1 more answered for other sessions of this workbench")

	out = render(&briefAsks{err: errors.New("database is locked")})
	assert.Contains(t, out, "Answered asks for you: unavailable: database is locked")
	assert.Contains(t, out, "#3 [in_progress")
}

// An ask reaches its session through the brief (spec 2026-10-03 Part 5): on
// a board and comments far past the 4000-rune cap the answered asks still
// show a row and the get_ask pointer, and the body stays within the cap.
func TestRenderProjectBrief_AnsweredAskSurvivesAFullBoard(t *testing.T) {
	long := strings.Repeat("Implement the next part of the plan ", 6)
	var big []db.BoardNode
	for id := 1; id <= 80; id++ {
		big = append(big, briefNode(id, "in_progress", long))
	}
	var comments []db.WorkbenchComment
	for i := 0; i < 60; i++ {
		comments = append(comments, db.WorkbenchComment{ID: int64(1000 + i), TargetID: sql.NullInt64{Int64: 1, Valid: true},
			Author: "owner", Body: strings.Repeat("Please revise this. ", 10)})
	}
	var list []db.OwnerAsk
	for i := int64(1); i <= 40; i++ {
		list = append(list, briefAnswered(100+i, "review", strings.Repeat("Ünïcödé review title ", 10), time.Hour))
	}
	for _, cs := range [][]db.WorkbenchComment{nil, comments} {
		out := renderWorkbenchBrief(big, briefWorkbench(), cs, workbenchcheck.Report{}, briefRecentHits(8), &briefAsks{list: list, others: 3}, time.Now(), workbenchVocabulary)

		assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
		assert.Contains(t, out, "more targets (workbench_board)", "the board is cut")
		assert.Contains(t, out, "\n#101 review — ", "the oldest answer keeps its row")
		assert.Contains(t, out, "→ get_ask 101\n")
		assert.Contains(t, out, "more answered asks (list_asks)")
		assert.Contains(t, out, "3 more answered for other sessions")
		assert.NotContains(t, out, "Recent in workbench sources", "cut asks leave no room for recent documents")
		assert.True(t, strings.HasSuffix(out, briefRules[0]))
	}

	// Whatever the board, the body stays within the cap with asks shown.
	for n := 0; n <= 80; n += 4 {
		out := renderWorkbenchBrief(big[:n], briefWorkbench(), comments[:n%7], workbenchcheck.Report{}, briefRecentHits(8), &briefAsks{list: list[:1+n%5], others: n % 3}, time.Now(), workbenchVocabulary)
		assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars, "board of %d", n)
		assert.Contains(t, out, "→ get_ask 101", "board of %d", n)
	}
}

// End to end: the brief of session S lists S's answered asks and the
// unbound or gone-session ones, counts the other session's, never lists an
// open or delivered ask, and leaves every ask's status alone (only get_ask
// delivers). Without the env var only the unbound ones are listed.
func TestProjectBrief_AnsweredAsksForItsSession(t *testing.T) {
	database, pid, mine := briefSessionFixture(t)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 't', '/tmp/acme')`, pid)
	require.NoError(t, err)
	theirs, err := res.LastInsertId()
	require.NoError(t, err)
	answeredAt := time.Now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	insert := func(session any, status, title string) int64 {
		t.Helper()
		answer, at := `{"note":"ok"}`, answeredAt
		if status == "open" {
			answer, at = "", ""
		}
		res, err := database.Exec(`INSERT INTO owner_asks (project_id, session_id, kind, title, status, answer, answered_at)
			VALUES (?, ?, 'question', ?, ?, ?, ?)`, pid, session, title, status, answer, at)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	own := insert(mine, "answered", "own answer")
	unbound := insert(nil, "answered", "unbound answer")
	insert(theirs, "answered", "their answer")
	insert(mine, "delivered", "already read")
	insert(mine, "open", "still waiting")
	statuses := func() map[int64]string {
		rows, err := database.Query(`SELECT id, status FROM owner_asks`)
		require.NoError(t, err)
		defer rows.Close()
		m := map[int64]string{}
		for rows.Next() {
			var id int64
			var s string
			require.NoError(t, rows.Scan(&id, &s))
			m[id] = s
		}
		require.NoError(t, rows.Err())
		return m
	}
	before := statuses()

	t.Setenv(terminalSessionEnv, strconv.FormatInt(mine, 10))
	out, errOut := runBriefHook(t, pid, "")
	assert.Empty(t, errOut)
	assert.Contains(t, out, fmt.Sprintf("Answered asks for you:\n#%d question — own answer (answered 2h) → get_ask %d\n#%d question — unbound answer (answered 2h) → get_ask %d\n1 more answered for other sessions",
		own, own, unbound, unbound))
	assert.NotContains(t, out, "their answer")
	assert.NotContains(t, out, "already read")
	assert.NotContains(t, out, "still waiting")
	assert.Equal(t, before, statuses(), "the brief never delivers an ask")

	for _, env := range []string{"row-x", ""} {
		t.Setenv(terminalSessionEnv, env)
		if env == "" {
			require.NoError(t, os.Unsetenv(terminalSessionEnv))
		}
		out, _ = runBriefHook(t, pid, "")
		assert.Contains(t, out, fmt.Sprintf("Answered asks for you:\n#%d question — unbound answer (answered 2h) → get_ask %d\n2 more answered for other sessions", unbound, unbound), "env %q: no own session", env)
		assert.NotContains(t, out, "own answer")
	}
}
