package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestWorkbench creates a project bound to a fresh temp folder.
func newTestWorkbench(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	return id
}

func nullID(id int64) sql.NullInt64 { return sql.NullInt64{Int64: id, Valid: true} }

// insertWorkbenchTargetRow plants a project target with raw SQL, independent of
// CreateProjectTarget (Task 3).
func insertWorkbenchTargetRow(t *testing.T, d *DB, projectID int64, text string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'chat', ?)`, text, projectID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestResolveProjectFolder_ResolvesSymlinksSpacesAndUnicode(t *testing.T) {
	base := t.TempDir()
	realDir := filepath.Join(base, "my проект dir")
	require.NoError(t, os.Mkdir(realDir, 0o755))
	link := filepath.Join(base, "link to it")
	require.NoError(t, os.Symlink(realDir, link))
	want, err := filepath.EvalSymlinks(realDir)
	require.NoError(t, err)

	got, err := ResolveWorkbenchFolder(link, nil)
	require.NoError(t, err)
	assert.Equal(t, want, got, "the symlink is resolved to the real folder")
	assert.True(t, filepath.IsAbs(got))
}

func TestResolveProjectFolder_RefusesMissingAndNonDirectories(t *testing.T) {
	base := t.TempDir()
	_, err := ResolveWorkbenchFolder(filepath.Join(base, "gone"), nil)
	assert.Error(t, err, "a missing folder is refused")

	file := filepath.Join(base, "README.md")
	require.NoError(t, os.WriteFile(file, []byte("x"), 0o600))
	_, err = ResolveWorkbenchFolder(file, nil)
	assert.ErrorContains(t, err, "not a directory")

	_, err = ResolveWorkbenchFolder("  ", nil)
	assert.Error(t, err, "an empty folder is refused")
}

func TestResolveProjectFolder_RelativePathBecomesAbsolute(t *testing.T) {
	base := t.TempDir()
	t.Chdir(base)
	require.NoError(t, os.Mkdir("repo", 0o755))
	want, err := filepath.EvalSymlinks(filepath.Join(base, "repo"))
	require.NoError(t, err)

	got, err := ResolveWorkbenchFolder("repo", nil)
	require.NoError(t, err)
	assert.Equal(t, want, got)
}

func TestCreateProject_SecondBindingOfTheSameFolderIsRefused(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	assert.Positive(t, id)

	_, err = d.CreateWorkbench("again", folder)
	assert.ErrorIs(t, err, ErrWorkbenchFolderTaken)
	_, err = d.CreateWorkbench("relative", "relative/dir")
	assert.Error(t, err, "an unresolved relative folder is refused")
	_, err = d.CreateWorkbench("  ", t.TempDir())
	assert.Error(t, err, "an empty name is refused")
}

func TestGetProject_RoundTripsAndReportsNotFound(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)

	p, err := d.GetWorkbench(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
	assert.Equal(t, folder, p.FolderPath)
	assert.Empty(t, p.Description)
	assert.NotEmpty(t, p.CreatedAt)

	_, err = d.GetWorkbench(id + 100)
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)

	list, err := d.ListWorkbenches()
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, id, list[0].ID)
}

func TestWorkbenchByFolder_MatchesTheBoundFolderOnly(t *testing.T) {
	d := openTestDB(t)
	folder := filepath.Join(t.TempDir(), "Acme")
	require.NoError(t, os.Mkdir(folder, 0o755))
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)

	got, err := d.WorkbenchByFolder(folder)
	require.NoError(t, err)
	assert.Equal(t, id, got.ID)
	assert.Equal(t, folder, got.FolderPath)

	// APFS is case-insensitive: another spelling of the folder is the folder.
	got, err = d.WorkbenchByFolder(strings.ToLower(folder))
	require.NoError(t, err)
	assert.Equal(t, id, got.ID)

	_, err = d.WorkbenchByFolder(filepath.Join(folder, "sub"))
	assert.ErrorIs(t, err, ErrWorkbenchNotFound, "a subfolder is not the workbench folder")
	_, err = d.WorkbenchByFolder(filepath.Dir(folder))
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
}

func TestUpdateProjectDescription(t *testing.T) {
	d := openTestDB(t)
	id := newTestWorkbench(t, d)
	require.NoError(t, d.UpdateWorkbenchDescription(id, "  A CLI and a desktop app. "))
	p, err := d.GetWorkbench(id)
	require.NoError(t, err)
	assert.Equal(t, "A CLI and a desktop app.", p.Description)
	assert.ErrorIs(t, d.UpdateWorkbenchDescription(id+100, "x"), ErrWorkbenchNotFound)
}

func TestProjectSources_AddIsIdempotentAndRemoveIsScoped(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)

	src := WorkbenchSource{WorkbenchID: pid, Kind: "slack_channel", Ref: "1:C1", Label: "#eng"}
	id1, err := d.AddWorkbenchSource(src)
	require.NoError(t, err)
	id2, err := d.AddWorkbenchSource(src)
	require.NoError(t, err)
	assert.Equal(t, id1, id2, "a duplicate add returns the existing row")

	_, err = d.AddWorkbenchSource(WorkbenchSource{WorkbenchID: pid, Kind: "wiki", Ref: "x"})
	assert.Error(t, err, "unknown kind")
	_, err = d.AddWorkbenchSource(WorkbenchSource{WorkbenchID: pid, Kind: "link", Ref: "  "})
	assert.Error(t, err, "empty ref")

	assert.ErrorIs(t, d.RemoveWorkbenchSource(other, id1), ErrNotInWorkbench)
	require.NoError(t, d.RemoveWorkbenchSource(pid, id1))
	list, err := d.ListWorkbenchSources(pid)
	require.NoError(t, err)
	assert.Empty(t, list)
}

// TestProj02_DeleteProjectLeavesNoRows is the DB half of PROJ-02
// (docs/inventory/workbench.md): deleting a project leaves no project, target,
// source, comment, ask, session link or PR cache row of it, and touches no
// other project.
// Task 12 adds the folder half.
func TestProj02_DeleteProjectLeavesNoRows(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	keep := newTestWorkbench(t, d)

	parent := insertWorkbenchTargetRow(t, d, pid, "feature")
	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id)
		VALUES ('task', '2026-09-29', '2026-09-29', ?, ?)`, pid, parent)
	require.NoError(t, err)
	keepTarget := insertWorkbenchTargetRow(t, d, keep, "other board")
	root, err := d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(parent), Author: "owner", Body: "why?"})
	require.NoError(t, err)
	_, err = d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, ParentID: nullID(root), Author: "agent", Body: "because"})
	require.NoError(t, err)
	_, err = d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(parent), Author: "agent", Body: "blocked"})
	require.NoError(t, err)
	_, err = d.AddWorkbenchSource(WorkbenchSource{WorkbenchID: pid, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		_, err := AddWorkbenchTargetImageTx(tx, WorkbenchTargetImage{WorkbenchID: pid, TargetID: parent,
			FileName: "shot.png", MIME: "image/png", Size: 3, SHA256: "abc", Path: "/tmp/abc.png"})
		return err
	}))

	sid := newTestSession(t, d, pid)
	mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(sid), TargetID: nullID(parent),
		Kind: "question", Title: "Which?"})
	answered := mustInsertAsk(t, d, questionAsk(pid, "Done?"))
	markAskAnswered(t, d, answered)
	keepAsk := mustInsertAsk(t, d, questionAsk(keep, "Theirs"))
	require.NoError(t, d.LinkSessionTarget(sid, parent))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, Ref: "pr:7", State: "open", CheckedAt: "2026-10-03T10:00:00Z"}))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: keep, Ref: "pr:7", State: "open", CheckedAt: "2026-10-03T10:00:00Z"}))
	// The folder files' search index entries (PROJ-08), this project's and another's.
	for _, doc := range []struct {
		id  string
		pid int64
	}{{"project_doc:1", pid}, {"project_doc:2", keep}} {
		_, err = d.Exec(`INSERT INTO kb_documents (id, source, title, anchor_json) VALUES (?, 'project_doc', 'spec', ?)`,
			doc.id, fmt.Sprintf(`{"project_id":"%d"}`, doc.pid))
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO kb_chunks (doc_id, idx, body) VALUES (?, 0, 'spec text')`, doc.id)
		require.NoError(t, err)
	}
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (NULL, 'shell', 'Terminal', '/tmp/acme')`)
	require.NoError(t, err)

	require.NoError(t, d.DeleteWorkbench(pid))

	for _, q := range []string{
		`SELECT COUNT(*) FROM projects WHERE id = ?`,
		`SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ?`,
		`SELECT COUNT(*) FROM targets WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_sources WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_comments WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_target_images WHERE project_id = ?`,
		`SELECT COUNT(*) FROM owner_asks WHERE project_id = ?`,
		`SELECT COUNT(*) FROM workbench_pr_states WHERE project_id = ?`,
		`SELECT COUNT(*) FROM terminal_session_targets l JOIN targets t ON t.id = l.target_id WHERE t.project_id = ?`,
	} {
		var n int
		require.NoError(t, d.QueryRow(q, pid).Scan(&n))
		assert.Zero(t, n, q)
	}
	for _, q := range []string{
		`SELECT COUNT(*) FROM kb_documents WHERE id = 'project_doc:1'`,
		`SELECT COUNT(*) FROM kb_chunks WHERE doc_id = 'project_doc:1'`,
	} {
		var n int
		require.NoError(t, d.QueryRow(q).Scan(&n))
		assert.Zero(t, n, q)
	}
	var kept int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM kb_chunks WHERE doc_id = 'project_doc:2'`).Scan(&kept))
	assert.Equal(t, 1, kept, "another project's index entries are untouched")
	_, err = d.GetTargetByID(int(keepTarget))
	assert.NoError(t, err, "another project's board is untouched")
	_, err = d.GetOwnerAsk(keep, keepAsk)
	assert.NoError(t, err, "another project's asks are untouched")
	var keptPR int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM workbench_pr_states WHERE project_id = ?`, keep).Scan(&keptPR))
	assert.Equal(t, 1, keptPR, "another project's PR cache is untouched")
	var links int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_session_targets`).Scan(&links))
	assert.Zero(t, links, "the deleted project's session links are gone")
	var standalone int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE project_id IS NULL`).Scan(&standalone))
	assert.Equal(t, 1, standalone, "a standalone terminal survives a project delete")
	assert.ErrorIs(t, d.DeleteWorkbench(pid), ErrWorkbenchNotFound)
}

// I3 (docs/superpowers/sdd/2026-09-29-projects-poc/final-review.md): a plain
// rowid PK hands out max(rowid)+1, so deleting the newest project and
// creating another would reuse its id — silently rebinding the old folder's
// hook, MCP registration ("watchtower mcp --project N") and any
// comment_id the agent still holds to the new project's board.
// AUTOINCREMENT on projects/project_comments (migration 00081) must make that
// impossible.
func TestProj02_DeletedProjectAndCommentIDsAreNeverReused(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sourceID, err := d.AddWorkbenchSource(WorkbenchSource{WorkbenchID: pid, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)
	target := insertWorkbenchTargetRow(t, d, pid, "feature")
	commentID, err := d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(target), Author: "owner", Body: "why?"})
	require.NoError(t, err)

	require.NoError(t, d.DeleteWorkbench(pid))

	newPID := newTestWorkbench(t, d)
	assert.Greater(t, newPID, pid, "a new project must never reuse a deleted project's id")

	newTarget := insertWorkbenchTargetRow(t, d, newPID, "feature")
	newCommentID, err := d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: newPID, TargetID: nullID(newTarget), Author: "owner", Body: "why?"})
	require.NoError(t, err)
	assert.Greater(t, newCommentID, commentID, "a new comment must never reuse a deleted one's id")

	// add_project_source/remove_project_source round-trip source_id too.
	newSourceID, err := d.AddWorkbenchSource(WorkbenchSource{WorkbenchID: newPID, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)
	assert.Greater(t, newSourceID, sourceID, "a new source must never reuse a deleted one's id")
}

// A project folder is never the filesystem root, the home directory or an
// ancestor of it, nor Watchtower's own data directories or anything in them.
func TestResolveProjectFolder_RefusesRootHomeAndWatchtowerDirs(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	for _, dir := range []string{
		filepath.Join(home, "code", "repo"),
		filepath.Join(home, ".local", "share", "watchtower", "acme"),
		filepath.Join(home, ".config", "watchtower"),
		filepath.Join(home, "Library", "Application Support", "Watchtower", "recordings"),
	} {
		require.NoError(t, os.MkdirAll(dir, 0o755))
	}
	t.Setenv("HOME", home)
	protected := []string{
		filepath.Join(home, ".local", "share", "watchtower"),
		filepath.Join(home, ".config", "watchtower"),
		filepath.Join(home, "Library", "Application Support", "Watchtower"),
	}

	for _, dir := range []string{
		"/",
		home,
		base,
		filepath.Join(home, ".local", "share", "watchtower"),
		filepath.Join(home, ".local", "share", "watchtower", "acme"),
		filepath.Join(home, ".local"),
		filepath.Join(home, ".config", "watchtower"),
		filepath.Join(home, "Library", "Application Support", "Watchtower", "recordings"),
	} {
		_, err := ResolveWorkbenchFolder(dir, protected)
		assert.ErrorIs(t, err, ErrWorkbenchFolderNotAllowed, dir)
	}

	got, err := ResolveWorkbenchFolder(filepath.Join(home, "code", "repo"), protected)
	require.NoError(t, err, "an ordinary folder under home is fine")
	assert.True(t, strings.HasSuffix(got, filepath.Join("code", "repo")))
}

// The protected-dir check folds case (APFS is case-insensitive) and matches
// whole path components only.
func TestPathWithin_FoldsCaseOnWholeComponents(t *testing.T) {
	assert.True(t, pathWithin("/Users/a/Library/Application Support/watchtower/x", "/Users/a/LIBRARY/Application Support/Watchtower"))
	assert.True(t, pathWithin("/Users/a", "/users/A"))
	assert.False(t, pathWithin("/Users/a/.localize", "/Users/a/.local"))
}

// APFS is case-insensitive: another spelling of a bound folder is taken too.
func TestCreateProject_FolderTakenIgnoresCase(t *testing.T) {
	d := openTestDB(t)
	_, err := d.CreateWorkbench("acme", "/work/Acme")
	require.NoError(t, err)
	_, err = d.CreateWorkbench("again", "/work/acme")
	assert.ErrorIs(t, err, ErrWorkbenchFolderTaken)
}

// A folder path is later written verbatim into .git/info/exclude lines, so a
// line break in it is refused at both entry points.
func TestProjectFolder_RefusesLineBreaks(t *testing.T) {
	base := t.TempDir()
	for _, name := range []string{"evil\nline", "evil\rline"} {
		dir := filepath.Join(base, name)
		require.NoError(t, os.Mkdir(dir, 0o755))
		_, err := ResolveWorkbenchFolder(dir, nil)
		assert.ErrorIs(t, err, ErrWorkbenchFolderNotAllowed, "%q", name)
	}
	d := openTestDB(t)
	_, err := d.CreateWorkbench("acme", "/work/evil\nline")
	assert.ErrorIs(t, err, ErrWorkbenchFolderNotAllowed)
	_, err = d.CreateWorkbench("acme", "/work/evil\rline")
	assert.ErrorIs(t, err, ErrWorkbenchFolderNotAllowed)
}
