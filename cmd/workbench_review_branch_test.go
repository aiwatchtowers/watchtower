package cmd

import (
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// Board #1012: a review round reads the folder when it is on the task's
// branch, else the task branch's committed tip (read-only), and an open
// round follows the session when its place moves.

func reviewGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	require.True(t, ok)
	c := exec.Command(bin, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	require.NoError(t, err, "git %v: %s", args, out)
	return strings.TrimSpace(string(out))
}

// commitOnBranch adds file name on branch (from its current tip) without
// moving the folder off its own branch.
func commitOnBranch(t *testing.T, repo, branch, name string) {
	t.Helper()
	head := reviewGit(t, repo, "symbolic-ref", "--short", "HEAD")
	reviewGit(t, repo, "checkout", "-q", branch)
	require.NoError(t, os.WriteFile(filepath.Join(repo, name), []byte(name+"\n"), 0o644))
	reviewGit(t, repo, "add", name)
	reviewGit(t, repo, "commit", "-q", "-m", name)
	reviewGit(t, repo, "checkout", "-q", head)
}

// ticketTarget makes a target with branch (under parent when set) and binds
// it as the session's ticket (terminal_sessions.target_id) when bind.
func ticketTarget(t *testing.T, database *db.DB, wb, session, parent int64, branch string, bind bool) int64 {
	t.Helper()
	p := sql.NullInt64{Int64: parent, Valid: parent != 0}
	id := db.SeedTestWorkbenchTarget(t, database, wb, p, "T "+branch)
	_, err := database.Exec(`UPDATE targets SET branch = ? WHERE id = ?`, branch, id)
	require.NoError(t, err)
	if bind {
		_, err = database.Exec(`UPDATE terminal_sessions SET target_id = ? WHERE id = ?`, id, session)
		require.NoError(t, err)
	}
	return id
}

func startRound(t *testing.T, wb, s int64, args ...string) map[string]any {
	t.Helper()
	out := reviewJSON(t, wb, "start", append([]string{"--session", itoa(s)}, args...)...)
	require.Equal(t, true, out["ok"], "%v", out)
	return out["round"].(map[string]any)
}

func roundFiles(t *testing.T, wb int64, round map[string]any) []string {
	t.Helper()
	files, _ := reviewJSON(t, wb, "diff", "--round", itoa(int64(round["id"].(float64))))["diff"].(map[string]any)["files"].([]any)
	var out []string
	for _, f := range files {
		out = append(out, f.(map[string]any)["path"].(string))
	}
	return out
}

func TestWorkbenchReview_FolderOnMainReviewsTheTaskBranchTip(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("uncommitted on main\n"), 0o644))

	r := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceBranch, r["source"])
	assert.Equal(t, "feature", r["branch"])
	assert.Equal(t, "main", r["base_label"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "main"), r["base_sha"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature^{tree}"), r["tree_sha"])
	assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, r), "main's uncommitted edit is not the branch's work")

	// Refresh re-reads the branch: a new commit on it joins the round.
	commitOnBranch(t, repo, "feature", "more.txt")
	again := startRound(t, wb, s, "--refresh")
	assert.Equal(t, r["id"], again["id"])
	assert.Equal(t, []string{"feature.txt", "more.txt"}, roundFiles(t, wb, again))
}

func TestWorkbenchReview_FolderOnTheTaskBranchReviewsTheFolder(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "checkout", "-q", "feature")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("uncommitted\n"), 0o644))

	r := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceFolder, r["source"])
	assert.Equal(t, "", r["branch"])
	assert.Equal(t, []string{"README.md", "feature.txt"}, roundFiles(t, wb, r))
}

func TestWorkbenchReview_AncestorBranchAndItsBase(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "branch", "feature-sub", "feature")
	commitOnBranch(t, repo, "feature-sub", "sub.txt")
	group := ticketTarget(t, database, wb, s, 0, "feature", false)
	task := ticketTarget(t, database, wb, s, group, "feature-sub", false)
	leaf := ticketTarget(t, database, wb, s, task, "", true)
	require.NotZero(t, leaf)

	r := startRound(t, wb, s)
	assert.Equal(t, "feature-sub", r["branch"], "the leaf has no branch: its nearest ancestor's")
	assert.Equal(t, "feature", r["base_label"], "the base is the branch above it")
	assert.Equal(t, []string{"sub.txt"}, roundFiles(t, wb, r))
}

func TestWorkbenchReview_NoTaskBranchKeepsTheFolder(t *testing.T) {
	for name, branch := range map[string]string{"no branch anywhere": "", "branch found nowhere": "gone"} {
		t.Run(name, func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			ticketTarget(t, database, wb, s, 0, branch, true)
			require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("edit\n"), 0o644))
			r := startRound(t, wb, s)
			assert.Equal(t, db.ReviewSourceFolder, r["source"])
			assert.Equal(t, []string{"README.md"}, roundFiles(t, wb, r))
		})
	}
}

func TestWorkbenchReview_OriginOnlyTaskBranch(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	tip := reviewGit(t, repo, "rev-parse", "feature")
	reviewGit(t, repo, "update-ref", "refs/remotes/origin/pushed", tip)
	ticketTarget(t, database, wb, s, 0, "pushed", true)
	r := startRound(t, wb, s)
	assert.Equal(t, "pushed", r["branch"])
	assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, r))
}

// The owner's report: the open round stayed "On main" after the session's
// agent moved into the branch's worktree. Start follows the place, keeping
// the round, its comments and its previous-round link.
func TestWorkbenchReview_OpenRoundFollowsTheSessionsPlace(t *testing.T) {
	for _, refresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "start", true: "refresh"}[refresh], func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			commitOnBranch(t, repo, "feature", "feature.txt")
			first := startRound(t, wb, s)
			assert.Equal(t, db.ReviewSourceFolder, first["source"])
			assert.Empty(t, roundFiles(t, wb, first))
			rid := int64(first["id"].(float64))
			_, err := database.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body)
				VALUES (?, 'README.md', 1, 1, 'hello', 'keep me')`, rid)
			require.NoError(t, err)

			// The ticket gets its branch: the round moves to the branch tip.
			ticketTarget(t, database, wb, s, 0, "feature", true)
			args := map[bool][]string{true: {"--refresh"}}[refresh]
			onBranch := startRound(t, wb, s, args...)
			assert.Equal(t, first["id"], onBranch["id"])
			assert.Equal(t, db.ReviewSourceBranch, onBranch["source"])
			assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, onBranch))

			// The agent moves into the branch's worktree: the round reads it.
			wt := filepath.Join(t.TempDir(), "wt")
			reviewGit(t, repo, "worktree", "add", "-q", wt, "feature")
			wt, err = filepath.EvalSymlinks(wt)
			require.NoError(t, err)
			require.NoError(t, os.WriteFile(filepath.Join(wt, "wip.txt"), []byte("wip\n"), 0o644))
			_, err = database.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-16T10:00:00Z' WHERE id = ?`, wt, s)
			require.NoError(t, err)
			inWorktree := startRound(t, wb, s, args...)
			assert.Equal(t, first["id"], inWorktree["id"])
			assert.Equal(t, db.ReviewSourceFolder, inWorktree["source"])
			assert.Equal(t, wt, inWorktree["folder_root"])
			assert.Equal(t, []string{"feature.txt", "wip.txt"}, roundFiles(t, wb, inWorktree))

			cs, err := database.ReviewRoundComments(rid)
			require.NoError(t, err)
			require.Len(t, cs, 1)
			assert.Equal(t, "keep me", cs[0].Body)
			assert.Equal(t, 1, reviewRoundCount(t, database))
		})
	}
}

// B1: the owner's rule names a folder on the default branch. A session on
// any other branch — Watchtower's own wt/<slug> worktree branch, or a branch
// the owner checked out — keeps reviewing its folder, its own commits and
// uncommitted edits included, even when the ticket names a task branch.
func TestWorkbenchReview_FolderOnAnotherBranchKeepsTheFolder(t *testing.T) {
	t.Run("wt worktree branch", func(t *testing.T) {
		database, wb, s, repo := reviewFixture(t)
		commitOnBranch(t, repo, "feature", "feature.txt")
		ticketTarget(t, database, wb, s, 0, "feature", true)
		wt := filepath.Join(t.TempDir(), "wt-slug")
		reviewGit(t, repo, "worktree", "add", "-q", "-b", "wt/slug", wt, "main")
		wt, err := filepath.EvalSymlinks(wt)
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(filepath.Join(wt, "own.txt"), []byte("own\n"), 0o644))
		reviewGit(t, wt, "add", "own.txt")
		reviewGit(t, wt, "commit", "-q", "-m", "own")
		require.NoError(t, os.WriteFile(filepath.Join(wt, "wip.txt"), []byte("wip\n"), 0o644))
		_, err = database.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-16T10:00:00Z' WHERE id = ?`, wt, s)
		require.NoError(t, err)

		r := startRound(t, wb, s)
		assert.Equal(t, db.ReviewSourceFolder, r["source"])
		assert.Equal(t, wt, r["folder_root"])
		assert.Equal(t, []string{"own.txt", "wip.txt"}, roundFiles(t, wb, r))
	})
	t.Run("another branch in the folder", func(t *testing.T) {
		database, wb, s, repo := reviewFixture(t)
		commitOnBranch(t, repo, "feature", "feature.txt")
		ticketTarget(t, database, wb, s, 0, "feature", true)
		reviewGit(t, repo, "checkout", "-q", "-b", "mine")
		require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("mine\n"), 0o644))

		r := startRound(t, wb, s)
		assert.Equal(t, db.ReviewSourceFolder, r["source"])
		assert.Equal(t, []string{"README.md"}, roundFiles(t, wb, r))
	})
}

// A detached HEAD reads as "not on the task branch" too: the tip is reviewed.
func TestWorkbenchReview_DetachedFolderReviewsTheTip(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	reviewGit(t, repo, "checkout", "-q", "--detach")
	r := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceBranch, r["source"])
	assert.Equal(t, "feature", r["branch"])
}

// T-b: a plain start resumes an unmoved round as it is; --refresh re-reads it.
func TestWorkbenchReview_PlainStartKeepsAnUnmovedRound(t *testing.T) {
	t.Run("folder", func(t *testing.T) {
		_, wb, s, repo := reviewFixture(t)
		first := startRound(t, wb, s)
		require.NoError(t, os.WriteFile(filepath.Join(repo, "new.txt"), []byte("new\n"), 0o644))
		again := startRound(t, wb, s)
		assert.Equal(t, first["tree_sha"], again["tree_sha"])
		refreshed := startRound(t, wb, s, "--refresh")
		assert.NotEqual(t, first["tree_sha"], refreshed["tree_sha"])
		assert.Equal(t, []string{"new.txt"}, roundFiles(t, wb, refreshed))
	})
	t.Run("branch tip", func(t *testing.T) {
		database, wb, s, repo := reviewFixture(t)
		commitOnBranch(t, repo, "feature", "feature.txt")
		ticketTarget(t, database, wb, s, 0, "feature", true)
		first := startRound(t, wb, s)
		commitOnBranch(t, repo, "feature", "more.txt")
		again := startRound(t, wb, s)
		assert.Equal(t, first["tree_sha"], again["tree_sha"])
		assert.Equal(t, "feature", again["branch"])
		refreshed := startRound(t, wb, s, "--refresh")
		assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature^{tree}"), refreshed["tree_sha"])
	})
}

// m2 (F3): a folder on the task branch is measured against the branch above
// it, as the tip is, so a switch between the two keeps the base.
func TestWorkbenchReview_FolderOnTheTaskBranchUsesTheTipsBase(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "branch", "feature-sub", "feature")
	commitOnBranch(t, repo, "feature-sub", "sub.txt")
	group := ticketTarget(t, database, wb, s, 0, "feature", false)
	ticketTarget(t, database, wb, s, group, "feature-sub", true)

	reviewGit(t, repo, "checkout", "-q", "feature-sub")
	folder := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceFolder, folder["source"])
	assert.Equal(t, "feature", folder["base_label"])
	assert.Equal(t, []string{"sub.txt"}, roundFiles(t, wb, folder))

	reviewGit(t, repo, "checkout", "-q", "main")
	tip := startRound(t, wb, s)
	assert.Equal(t, folder["id"], tip["id"])
	assert.Equal(t, db.ReviewSourceBranch, tip["source"])
	assert.Equal(t, folder["base_sha"], tip["base_sha"], "the base does not move with the place")
	assert.Equal(t, folder["base_label"], tip["base_label"])
}

// sendRound sends round r as the owner's Desktop would.
func sendRound(t *testing.T, database *db.DB, r map[string]any) {
	t.Helper()
	_, err := database.Exec(`UPDATE review_rounds SET status = 'sent', sent_at = '2026-10-16T10:00:00Z' WHERE id = ?`,
		int64(r["id"].(float64)))
	require.NoError(t, err)
}

// REVIEW-03 across a place change (board #1012): a round always links to
// the session's last sent round, so its unresolved comments carry, but a
// previous round of another place has no tree to diff since — "Since round
// N" reads it as lost and shows all changes.
func TestWorkbenchReview_PreviousRoundOfAnotherPlace(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	folderRound := startRound(t, wb, s)
	sendRound(t, database, folderRound)

	// Same place: the next round follows the sent one up, Since included.
	second := startRound(t, wb, s)
	assert.Equal(t, folderRound["id"], second["prev_round_id"])
	assert.Equal(t, false, second["prev_tree_lost"])

	// The ticket gets a branch: the open round moves to the tip and keeps its link.
	ticketTarget(t, database, wb, s, 0, "feature", true)
	moved := startRound(t, wb, s)
	assert.Equal(t, second["id"], moved["id"])
	assert.Equal(t, db.ReviewSourceBranch, moved["source"])
	assert.Equal(t, folderRound["id"], moved["prev_round_id"], "the link stays: its comments carry")
	assert.Equal(t, true, moved["prev_tree_lost"], "another place's tree is no Since base")
	since := reviewJSON(t, wb, "diff", "--round", itoa(int64(moved["id"].(float64))), "--since")
	assert.Equal(t, true, since["previous_tree_lost"])
	assert.Equal(t, moved["base_sha"], since["from"], "all changes, from the base")

	// A new round on the tip links to the folder round's successor too.
	sendRound(t, database, moved)
	onTip := startRound(t, wb, s)
	assert.Equal(t, moved["id"], onTip["prev_round_id"])
	assert.Equal(t, false, onTip["prev_tree_lost"], "same place: Since works")
}

// M2: a removed worktree (#535 cleanup) is not a move: the open round stays
// where it was and the envelope says the place is gone. A new round for such
// a session reads the workbench folder, as before.
func TestWorkbenchReview_RemovedWorktreeKeepsTheOpenRound(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	wt := filepath.Join(t.TempDir(), "wt")
	reviewGit(t, repo, "worktree", "add", "-q", "-b", "wt/gone", wt, "main")
	wt, err := filepath.EvalSymlinks(wt)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(wt, "wip.txt"), []byte("wip\n"), 0o644))
	_, err = database.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-16T10:00:00Z' WHERE id = ?`, wt, s)
	require.NoError(t, err)
	first := startRound(t, wb, s)
	require.Equal(t, wt, first["folder_root"])

	reviewGit(t, repo, "worktree", "remove", "--force", wt)
	for _, args := range [][]string{nil, {"--refresh"}} {
		out := reviewJSON(t, wb, "start", append([]string{"--session", itoa(s)}, args...)...)
		require.Equal(t, true, out["ok"], "%v", out)
		assert.Equal(t, true, out["place_missing"])
		r := out["round"].(map[string]any)
		assert.Equal(t, first["id"], r["id"])
		assert.Equal(t, wt, r["folder_root"], "the round stays where it was")
		assert.Equal(t, first["tree_sha"], r["tree_sha"])
	}

	sendRound(t, database, first)
	next := reviewJSON(t, wb, "start", "--session", itoa(s))
	require.Equal(t, true, next["ok"], "%v", next)
	assert.Nil(t, next["place_missing"])
	assert.Equal(t, repo, next["round"].(map[string]any)["folder_root"], "a new round reads the workbench folder")
}

// M3: a git failure other than git's documented "no" fails the start; the
// open round is not moved on a guess. An unreadable refs/heads makes
// symbolic-ref HEAD exit 128 — before, that read as a detached HEAD and moved
// the folder round to the origin branch's tip.
func TestWorkbenchReview_GitFailureDoesNotMoveTheRound(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 directory")
	}
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "update-ref", "refs/remotes/origin/feature", reviewGit(t, repo, "rev-parse", "feature"))
	reviewGit(t, repo, "checkout", "-q", "feature")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	first := startRound(t, wb, s)
	require.Equal(t, db.ReviewSourceFolder, first["source"])

	heads := filepath.Join(repo, ".git", "refs", "heads")
	require.NoError(t, os.Chmod(heads, 0o000))
	t.Cleanup(func() { _ = os.Chmod(heads, 0o755) })
	out := reviewJSON(t, wb, "start", "--session", itoa(s))
	require.NoError(t, os.Chmod(heads, 0o755))
	assert.Equal(t, false, out["ok"], "%v", out)
	assert.Contains(t, out["error"], "exit 128")

	got, err := database.GetReviewRound(wb, int64(first["id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, db.ReviewSourceFolder, got.Source)
	assert.Equal(t, first["tree_sha"], got.TreeSHA)
}

func TestWorkbenchReviewRevertHunk_RefusedOnABranchRound(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	r := startRound(t, wb, s)
	require.Equal(t, db.ReviewSourceBranch, r["source"])
	rid := itoa(int64(r["id"].(float64)))
	files := reviewJSON(t, wb, "diff", "--round", rid)["diff"].(map[string]any)["files"].([]any)
	require.Len(t, files, 1)
	hunk := files[0].(map[string]any)["hunks"].([]any)[0].(map[string]any)["hunk_id"].(string)

	// A copy of the branch's file in the folder on main: an undo that ran
	// would take its line out.
	copyPath := filepath.Join(repo, "feature.txt")
	require.NoError(t, os.WriteFile(copyPath, []byte("feature.txt\n"), 0o644))

	out := reviewJSON(t, wb, "revert-hunk", "--round", rid, "--hunk", hunk)
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, errBranchRoundReadOnly.Error(), out["error"])
	assert.Equal(t, 0, revertCount(t, database))
	got, err := os.ReadFile(copyPath)
	require.NoError(t, err)
	assert.Equal(t, "feature.txt\n", string(got), "nothing written into the folder on main")
}

// M1 (F2): the round stores the branch it reviews. A ticket whose branch is
// renamed is another place: a plain start moves the open round to the new
// tip, and its label is the branch the round now reads, never a new name
// over the old tree.
func TestWorkbenchReview_RenamedTicketBranchMovesTheRound(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "branch", "feature-v2", "feature")
	commitOnBranch(t, repo, "feature-v2", "v2.txt")
	ticket := ticketTarget(t, database, wb, s, 0, "feature", true)
	first := startRound(t, wb, s)
	require.Equal(t, "feature", first["branch"])

	_, err := database.Exec(`UPDATE targets SET branch = 'feature-v2' WHERE id = ?`, ticket)
	require.NoError(t, err)
	moved := startRound(t, wb, s)
	assert.Equal(t, first["id"], moved["id"])
	assert.Equal(t, "feature-v2", moved["branch"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature-v2^{tree}"), moved["tree_sha"])
	assert.Equal(t, []string{"feature.txt", "v2.txt"}, roundFiles(t, wb, moved))
	got, err := database.GetReviewRound(wb, int64(moved["id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, "feature-v2", got.Branch)
}

// Codex round 4: a folder round's base branch changing in the same folder
// (the folder leaves its own branch for the task branch, whose base is its
// parent's) moves the base; main gaining commits does not.
func TestWorkbenchReview_FolderBaseBranchChangeMovesTheBase(t *testing.T) {
	for _, refresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "start", true: "refresh"}[refresh], func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			commitOnBranch(t, repo, "feature", "feature.txt")
			reviewGit(t, repo, "branch", "feature-task", "feature")
			commitOnBranch(t, repo, "feature-task", "task.txt")
			group := ticketTarget(t, database, wb, s, 0, "feature", false)
			ticketTarget(t, database, wb, s, group, "feature-task", true)
			reviewGit(t, repo, "checkout", "-q", "-b", "mine")

			first := startRound(t, wb, s)
			require.Equal(t, db.ReviewSourceFolder, first["source"])
			require.Equal(t, "main", first["base_label"])

			reviewGit(t, repo, "checkout", "-q", "feature-task")
			args := map[bool][]string{true: {"--refresh"}}[refresh]
			again := startRound(t, wb, s, args...)
			assert.Equal(t, first["id"], again["id"])
			assert.Equal(t, db.ReviewSourceFolder, again["source"])
			assert.Equal(t, "feature", again["base_label"])
			assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature"), again["base_sha"])
			assert.Equal(t, []string{"task.txt"}, roundFiles(t, wb, again))
		})
	}
}

func TestWorkbenchReview_FolderRefreshKeepsAnUnchangedBase(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	reviewGit(t, repo, "checkout", "-q", "-b", "mine")
	first := startRound(t, wb, s)
	require.Equal(t, "main", first["base_label"])
	commitOnBranch(t, repo, "main", "later.txt")
	again := startRound(t, wb, s, "--refresh")
	assert.Equal(t, first["base_sha"], again["base_sha"], "the base commit stays while the base branch is the same")
	assert.Equal(t, first["base_label"], again["base_label"])
}
