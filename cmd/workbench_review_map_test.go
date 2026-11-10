package cmd

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Board #1025: `workbench review map` — the instant map of a round or a
// session — and the head_sha every round stores for its lane walk.

// writeRepoFile writes name (parents made) in repo.
func writeRepoFile(t *testing.T, repo, name, text string) {
	t.Helper()
	path := filepath.Join(repo, filepath.FromSlash(name))
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o644))
}

// laneBranch makes branch from main with one commit per file set, then
// returns to the branch the folder was on.
func laneBranch(t *testing.T, repo, branch string, commits ...[]string) {
	t.Helper()
	back := reviewGit(t, repo, "symbolic-ref", "--short", "HEAD")
	reviewGit(t, repo, "checkout", "-q", "-b", branch, "main")
	for i, files := range commits {
		for _, f := range files {
			writeRepoFile(t, repo, f, fmt.Sprintf("%s %s %d\n", branch, f, i))
		}
		reviewGit(t, repo, "add", "-A")
		reviewGit(t, repo, "commit", "-q", "-m", fmt.Sprintf("%s step %d", branch, i))
	}
	reviewGit(t, repo, "checkout", "-q", back)
}

// mapFixture: the folder on branch feature (main's api/api.go in its base),
// which merged two lanes —
// ABC-1-login (a synced Jira issue) and task-b (a board target's
// branch; it touches shared.go twice, the Jira lane once) — plus
// uncommitted work: a new migration, a noise file, a deleted README and
// api.go's exported func removed. The
// session's agent named one chapter.
func mapFixture(t *testing.T) (database *db.DB, wb, session int64, repo string, boardTarget int64) {
	t.Helper()
	database, wb, session, repo = reviewFixture(t)
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.example.com", SiteName: "acme"})
	require.NoError(t, err)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: acct, Key: "ABC-1", ID: "10001", ProjectKey: "ABC", Summary: "Login with a passkey",
		Status: "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
		CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z",
	}))
	require.NoError(t, database.UpdateJiraSyncState(acct, "ABC", "2026-01-01T00:00:00Z", 1))
	boardTarget = db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Payments lane")
	_, err = database.Exec(`UPDATE targets SET branch = 'task-b' WHERE id = ?`, boardTarget)
	require.NoError(t, err)

	writeRepoFile(t, repo, "api/api.go", "package api\n\nfunc Exported() {}\n")
	reviewGit(t, repo, "add", "-A")
	reviewGit(t, repo, "commit", "-q", "-m", "api")
	laneBranch(t, repo, "ABC-1-login", []string{"login/auth.go", "shared.go"})
	laneBranch(t, repo, "task-b", []string{"pay/pay.go", "shared.go"}, []string{"shared.go", "docs/notes.md"})
	reviewGit(t, repo, "checkout", "-q", "feature")
	reviewGit(t, repo, "merge", "-q", "--ff-only", "main")
	reviewGit(t, repo, "merge", "-q", "--no-ff", "--no-edit", "ABC-1-login")
	reviewGit(t, repo, "merge", "-q", "--no-ff", "--no-edit", "-X", "theirs", "task-b")
	writeRepoFile(t, repo, "internal/db/migrations/00001_init.sql", "-- +goose Up\n")
	writeRepoFile(t, repo, "testdata/golden.json", "{}\n")
	writeRepoFile(t, repo, "api/api.go", "package api\n")
	require.NoError(t, os.Remove(filepath.Join(repo, "README.md")))
	require.NoError(t, database.ReplaceReviewNotes(wb, session, "", []db.ReviewNote{
		{Kind: "chapter", Text: "Docs first", Paths: []string{"docs/notes.md"}},
	}))
	return database, wb, session, repo, boardTarget
}

func reviewMap(t *testing.T, wb int64, args ...string) (map[string]any, string) {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"review", "map", "--workbench", itoa(wb), "--json"}, args...)...)
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	require.Equal(t, true, m["ok"], out)
	return m["map"].(map[string]any), out
}

func chapterKeys(m map[string]any) []string {
	var keys []string
	for _, c := range m["chapters"].([]any) {
		keys = append(keys, c.(map[string]any)["key"].(string))
	}
	return keys
}

// roundHead is review round id's stored head_sha.
func roundHead(t *testing.T, database *db.DB, id any) string {
	t.Helper()
	var head string
	require.NoError(t, database.QueryRow(`SELECT head_sha FROM review_rounds WHERE id = ?`, id).Scan(&head))
	return head
}

// tableCounts is every table's row count.
func tableCounts(t *testing.T, database *db.DB) map[string]int {
	t.Helper()
	rows, err := database.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	require.NoError(t, rows.Close()) // before the counts: one connection
	counts := map[string]int{}
	for _, n := range names {
		var c int
		require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM "`+n+`"`).Scan(&c))
		counts[n] = c
	}
	return counts
}

// TestReviewMap_GoldenKeysAndWritesNothing pins the map's JSON (the Desktop
// decodes testdata/review-map.golden.json) and checks the command writes no row.
func TestReviewMap_GoldenKeysAndWritesNothing(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)

	before := tableCounts(t, database)
	m, out := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, before, tableCounts(t, database), "review map wrote a row")

	assert.Equal(t, false, m["lanes_partial"])
	golden := filepath.Join("testdata", "review-map.golden.json")
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(golden, []byte(out), 0o644))
	}
	want, err := os.ReadFile(golden)
	require.NoError(t, err)
	assert.Equal(t, string(want), out, "the map's JSON changed: re-run with -update and update the Desktop fixture")

	// Every pinned key is present (the golden's own keys).
	var env struct {
		Map struct {
			Chapters []map[string]json.RawMessage `json:"chapters"`
			Files    []map[string]json.RawMessage `json:"files"`
			Lanes    []map[string]json.RawMessage `json:"lanes"`
		} `json:"map"`
	}
	require.NoError(t, json.Unmarshal(want, &env))
	keysOf := func(rows []map[string]json.RawMessage) map[string]bool {
		seen := map[string]bool{}
		for _, row := range rows {
			for k := range row {
				seen[k] = true
			}
		}
		return seen
	}
	for _, k := range []string{"key", "title", "level", "core", "paths", "changed_lines", "lane", "target_id", "jira_key", "signals_summary"} {
		assert.True(t, keysOf(env.Map.Chapters)[k], "golden chapters lack %q", k)
	}
	for _, k := range []string{"path", "chapter", "level", "signals", "lane", "also"} {
		assert.True(t, keysOf(env.Map.Files)[k], "golden files lack %q", k)
	}
	for _, k := range []string{"name", "title", "target_id", "jira_key"} {
		assert.True(t, keysOf(env.Map.Lanes)[k], "golden lanes lack %q", k)
	}
	for _, k := range []string{"chapters", "files", "lanes", "lanes_partial", "diff_truncated", "notes"} {
		assert.Contains(t, m, k)
	}
}

func TestReviewMap_SessionFormMatchesTheRound(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	byRound, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	before := tableCounts(t, database)
	bySession, _ := reviewMap(t, wb, "--session", itoa(s))
	assert.Equal(t, before, tableCounts(t, database), "review map wrote a row")
	assert.Equal(t, byRound, bySession)
}

func TestReviewMap_RoundWithoutHeadHasNoLanes(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	_, err := database.Exec(`UPDATE review_rounds SET head_sha = '' WHERE id = ?`, r["id"])
	require.NoError(t, err)

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["lanes_partial"])
	keys := chapterKeys(m)
	assert.Contains(t, keys, "dir:login")
	for _, k := range keys {
		assert.False(t, strings.HasPrefix(k, "lane:"), "a round without head_sha got lane %q", k)
	}
}

func TestReviewMap_BudgetOutFallsBackToPackages(t *testing.T) {
	_, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	old := reviewMapBudget
	reviewMapBudget = time.Nanosecond
	t.Cleanup(func() { reviewMapBudget = old })

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["lanes_partial"])
	for _, k := range chapterKeys(m) {
		assert.False(t, strings.HasPrefix(k, "lane:"), "lane chapter %q past the budget", k)
	}
}

func TestReviewMap_UnreadableHeadIsPartialWithANote(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	_, err := database.Exec(`UPDATE review_rounds SET head_sha = ? WHERE id = ?`, strings.Repeat("0", 40), r["id"])
	require.NoError(t, err)

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["lanes_partial"])
	assert.Contains(t, m["notes"], lanesUnreadNote)
}

// TestReviewMap_UnreadableTitlesArePartialWithANote: a title source that
// fails (here a missing jira_issues table) keeps the lanes, named by
// branch, and says why the map is partial.
func TestReviewMap_UnreadableTitlesArePartialWithANote(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	_, err := database.Exec(`DROP TABLE jira_issues`)
	require.NoError(t, err)

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["lanes_partial"])
	assert.Contains(t, m["notes"], laneTitlesUnreadNote)
	assert.NotContains(t, m["notes"], lanesUnreadNote)
	assert.Contains(t, chapterKeys(m), "lane:task-b")
}

// TestReviewMap_NoDefaultBranchIsPartialWithANote: with no origin HEAD,
// main or master the lanes stay, but base syncs cannot be told from them,
// so the map is partial and says why.
func TestReviewMap_NoDefaultBranchIsPartialWithANote(t *testing.T) {
	_, wb, s, repo, _ := mapFixture(t)
	r := startRound(t, wb, s)
	reviewGit(t, repo, "branch", "-m", "main", "trunk")
	require.Empty(t, reviewGit(t, repo, "branch", "--list", "main", "master"))

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["lanes_partial"])
	assert.Contains(t, m["notes"], laneBaseUnknownNote)
	assert.NotContains(t, m["notes"], lanesUnreadNote)
	assert.Contains(t, chapterKeys(m), "lane:task-b")
}

func TestReviewMap_BranchTipRoundTakesLanesFromTheTip(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	laneBranch(t, repo, "lane-x", []string{"x/x.go"})
	reviewGit(t, repo, "checkout", "-q", "feature")
	reviewGit(t, repo, "merge", "-q", "--no-ff", "--no-edit", "lane-x")
	reviewGit(t, repo, "checkout", "-q", "main")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	writeRepoFile(t, repo, "README.md", "uncommitted on main\n")

	r := startRound(t, wb, s)
	require.Equal(t, db.ReviewSourceBranch, r["source"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature"), roundHead(t, database, r["id"]), "a tip round stores the tip it read")

	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, false, m["lanes_partial"])
	assert.Equal(t, []string{"lane:lane-x"}, chapterKeys(m))
}

func TestReviewMap_DiffTruncatedPastTheCap(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	body := strings.Repeat("x\n", 4900)
	for i := range 11 {
		writeRepoFile(t, repo, fmt.Sprintf("big/f%02d.txt", i), body)
	}
	r := startRound(t, wb, s)
	m, _ := reviewMap(t, wb, "--round", itoa(int64(r["id"].(float64))))
	assert.Equal(t, true, m["diff_truncated"])
}

func TestReviewMap_NeedsExactlyOneOfRoundAndSession(t *testing.T) {
	_, wb, _, _ := reviewFixture(t)
	_, _, err := runWorkbench(t, "review", "map", "--workbench", itoa(wb), "--json")
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.Error(t, err)
	_, _, err = runWorkbench(t, "review", "map", "--workbench", itoa(wb), "--json", "--round", "1", "--session", "2")
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.Error(t, err)
}

// TestWorkbenchReview_StartRefreshAndRepointStoreHead: start stores the
// folder's HEAD, Refresh the new one, a move to the task branch's tip the
// tip's commit.
func TestWorkbenchReview_StartRefreshAndRepointStoreHead(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	writeRepoFile(t, repo, "README.md", "edited\n")
	r := startRound(t, wb, s)
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "HEAD"), roundHead(t, database, r["id"]))

	writeRepoFile(t, repo, "later.txt", "later\n")
	reviewGit(t, repo, "add", "later.txt")
	reviewGit(t, repo, "commit", "-q", "-m", "later")
	ref := startRound(t, wb, s, "--refresh")
	require.Equal(t, r["id"], ref["id"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "HEAD"), roundHead(t, database, r["id"]), "refresh stores the new head")

	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	moved := startRound(t, wb, s)
	require.Equal(t, r["id"], moved["id"])
	require.Equal(t, db.ReviewSourceBranch, moved["source"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature"), roundHead(t, database, r["id"]), "a move stores the tip's commit")
}
