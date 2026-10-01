package db

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestProject creates a project bound to a fresh temp folder.
func newTestProject(t *testing.T, d *DB) int64 {
	t.Helper()
	id, err := d.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	return id
}

func nullID(id int64) sql.NullInt64 { return sql.NullInt64{Int64: id, Valid: true} }

// insertProjectTargetRow plants a project target with raw SQL, independent of
// CreateProjectTarget (Task 3).
func insertProjectTargetRow(t *testing.T, d *DB, projectID int64, text string) int64 {
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

	got, err := ResolveProjectFolder(link, nil)
	require.NoError(t, err)
	assert.Equal(t, want, got, "the symlink is resolved to the real folder")
	assert.True(t, filepath.IsAbs(got))
}

func TestResolveProjectFolder_RefusesMissingAndNonDirectories(t *testing.T) {
	base := t.TempDir()
	_, err := ResolveProjectFolder(filepath.Join(base, "gone"), nil)
	assert.Error(t, err, "a missing folder is refused")

	file := filepath.Join(base, "README.md")
	require.NoError(t, os.WriteFile(file, []byte("x"), 0o600))
	_, err = ResolveProjectFolder(file, nil)
	assert.ErrorContains(t, err, "not a directory")

	_, err = ResolveProjectFolder("  ", nil)
	assert.Error(t, err, "an empty folder is refused")
}

func TestResolveProjectFolder_RelativePathBecomesAbsolute(t *testing.T) {
	base := t.TempDir()
	t.Chdir(base)
	require.NoError(t, os.Mkdir("repo", 0o755))
	want, err := filepath.EvalSymlinks(filepath.Join(base, "repo"))
	require.NoError(t, err)

	got, err := ResolveProjectFolder("repo", nil)
	require.NoError(t, err)
	assert.Equal(t, want, got)
}

func TestCreateProject_SecondBindingOfTheSameFolderIsRefused(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateProject("acme", folder)
	require.NoError(t, err)
	assert.Positive(t, id)

	_, err = d.CreateProject("again", folder)
	assert.ErrorIs(t, err, ErrProjectFolderTaken)
	_, err = d.CreateProject("relative", "relative/dir")
	assert.Error(t, err, "an unresolved relative folder is refused")
	_, err = d.CreateProject("  ", t.TempDir())
	assert.Error(t, err, "an empty name is refused")
}

func TestGetProject_RoundTripsAndReportsNotFound(t *testing.T) {
	d := openTestDB(t)
	folder := t.TempDir()
	id, err := d.CreateProject("acme", folder)
	require.NoError(t, err)

	p, err := d.GetProject(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", p.Name)
	assert.Equal(t, folder, p.FolderPath)
	assert.Empty(t, p.Description)
	assert.NotEmpty(t, p.CreatedAt)

	_, err = d.GetProject(id + 100)
	assert.ErrorIs(t, err, ErrProjectNotFound)

	list, err := d.ListProjects()
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, id, list[0].ID)
}

func TestUpdateProjectDescription(t *testing.T) {
	d := openTestDB(t)
	id := newTestProject(t, d)
	require.NoError(t, d.UpdateProjectDescription(id, "A CLI and a desktop app."))
	p, err := d.GetProject(id)
	require.NoError(t, err)
	assert.Equal(t, "A CLI and a desktop app.", p.Description)
	assert.ErrorIs(t, d.UpdateProjectDescription(id+100, "x"), ErrProjectNotFound)
}

func TestProjectSources_AddIsIdempotentAndRemoveIsScoped(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)

	src := ProjectSource{ProjectID: pid, Kind: "slack_channel", Ref: "1:C1", Label: "#eng"}
	id1, err := d.AddProjectSource(src)
	require.NoError(t, err)
	id2, err := d.AddProjectSource(src)
	require.NoError(t, err)
	assert.Equal(t, id1, id2, "a duplicate add returns the existing row")

	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "wiki", Ref: "x"})
	assert.Error(t, err, "unknown kind")
	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "link", Ref: "  "})
	assert.Error(t, err, "empty ref")

	assert.ErrorIs(t, d.RemoveProjectSource(other, id1), ErrNotInProject)
	require.NoError(t, d.RemoveProjectSource(pid, id1))
	list, err := d.ListProjectSources(pid)
	require.NoError(t, err)
	assert.Empty(t, list)
}

func TestUpsertProjectDocument_CreatesThenRevises(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")

	id, created, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md",
		Kind: "plan", Title: "Plan", TargetID: nullID(tid)})
	require.NoError(t, err)
	assert.True(t, created)

	_, err = d.Exec(`UPDATE project_documents SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	again, created, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md"})
	require.NoError(t, err)
	assert.Equal(t, id, again)
	assert.False(t, created)

	doc, err := d.GetProjectDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "plan", doc.Kind, "an empty kind keeps the stored one")
	assert.Equal(t, "Plan", doc.Title, "an empty title keeps the stored one")
	assert.Equal(t, nullID(tid), doc.TargetID, "an unset target keeps the stored link")
	assert.NotEqual(t, "2000-01-01T00:00:00Z", doc.UpdatedAt, "re-attach marks the document revised")

	list, err := d.ListProjectDocuments(pid)
	require.NoError(t, err)
	assert.Len(t, list, 1)
}

func TestUpsertProjectDocument_RefusesBadInput(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	foreign := insertProjectTargetRow(t, d, newTestProject(t, d), "other board")

	_, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", TargetID: nullID(foreign)})
	assert.ErrorIs(t, err, ErrNotInProject)
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", Kind: "memo"})
	assert.Error(t, err, "unknown kind")
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: " "})
	assert.Error(t, err, "empty path")
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "/etc/passwd"})
	assert.Error(t, err, "absolute path")
}

func TestAttachOwnerProjectDocument_InsertsOwnerRowAndNeverRevises(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")

	id, created, err := d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/notes.md",
		Kind: "spec", Title: "Notes", TargetID: nullID(tid)})
	require.NoError(t, err)
	assert.True(t, created)
	doc, err := d.GetProjectDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "owner", doc.Origin)
	assert.Equal(t, "spec", doc.Kind)
	assert.Equal(t, nullID(tid), doc.TargetID)

	_, err = d.Exec(`UPDATE project_documents SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	again, created, err := d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "DOCS/Notes.md", Kind: "plan"})
	require.NoError(t, err)
	assert.Equal(t, id, again, "another spelling of the same path is the same document")
	assert.False(t, created)
	doc, err = d.GetProjectDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "2000-01-01T00:00:00Z", doc.UpdatedAt, "an owner attach never marks a document revised")
	assert.Equal(t, "spec", doc.Kind, "an existing row is left untouched")

	// An agent re-attach makes it the agent's, as it does for an import.
	_, _, err = d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/notes.md"})
	require.NoError(t, err)
	doc, err = d.GetProjectDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "agent", doc.Origin)
}

func TestAttachOwnerProjectDocument_RefusesBadInput(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	foreign := insertProjectTargetRow(t, d, newTestProject(t, d), "other board")

	_, _, err := d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", TargetID: nullID(foreign)})
	assert.ErrorIs(t, err, ErrNotInProject)
	_, _, err = d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid + 100, RelPath: "a.md"})
	assert.ErrorIs(t, err, ErrProjectNotFound)
	_, _, err = d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "a.md", Kind: "memo"})
	assert.Error(t, err, "unknown kind")
	_, _, err = d.AttachOwnerProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "/etc/passwd"})
	assert.Error(t, err, "absolute path")
	docs, err := d.ListProjectDocuments(pid)
	require.NoError(t, err)
	assert.Empty(t, docs)
}

// TestProj02_DeleteProjectLeavesNoRows is the DB half of PROJ-02
// (docs/inventory/projects.md): deleting a project leaves no project, target,
// source, document or comment row of it, and touches no other project.
// Task 12 adds the folder half.
func TestProj02_DeleteProjectLeavesNoRows(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	keep := newTestProject(t, d)

	parent := insertProjectTargetRow(t, d, pid, "feature")
	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id)
		VALUES ('task', '2026-09-29', '2026-09-29', ?, ?)`, pid, parent)
	require.NoError(t, err)
	keepTarget := insertProjectTargetRow(t, d, keep, "other board")
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/spec.md", Kind: "spec"})
	require.NoError(t, err)
	root, err := d.AddProjectComment(ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner",
		Body: "why?", AnchorQuote: "the quote"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "because"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(parent), Author: "agent", Body: "blocked"})
	require.NoError(t, err)
	_, err = d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)

	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid-1')`, pid)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (NULL, 'shell', 'Terminal', '/tmp/acme')`)
	require.NoError(t, err)

	require.NoError(t, d.DeleteProject(pid))

	for _, q := range []string{
		`SELECT COUNT(*) FROM projects WHERE id = ?`,
		`SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ?`,
		`SELECT COUNT(*) FROM targets WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_sources WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_documents WHERE project_id = ?`,
		`SELECT COUNT(*) FROM project_comments WHERE project_id = ?`,
	} {
		var n int
		require.NoError(t, d.QueryRow(q, pid).Scan(&n))
		assert.Zero(t, n, q)
	}
	_, err = d.GetTargetByID(int(keepTarget))
	assert.NoError(t, err, "another project's board is untouched")
	var standalone int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE project_id IS NULL`).Scan(&standalone))
	assert.Equal(t, 1, standalone, "a standalone terminal survives a project delete")
	assert.ErrorIs(t, d.DeleteProject(pid), ErrProjectNotFound)
}

// I3 (docs/superpowers/sdd/2026-09-29-projects-poc/final-review.md): a plain
// rowid PK hands out max(rowid)+1, so deleting the newest project and
// creating another would reuse its id — silently rebinding the old folder's
// hook, MCP registration ("watchtower mcp --project N") and any
// "watchtower document <id>"/comment_id the agent still holds to the new
// project's board. AUTOINCREMENT on projects/project_documents/
// project_comments (migration 00081) must make that impossible.
func TestProj02_DeletedProjectDocumentAndCommentIDsAreNeverReused(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	sourceID, err := d.AddProjectSource(ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com"})
	require.NoError(t, err)
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/spec.md", Kind: "spec"})
	require.NoError(t, err)
	target := insertProjectTargetRow(t, d, pid, "feature")
	commentID, err := d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(target), Author: "owner", Body: "why?"})
	require.NoError(t, err)

	require.NoError(t, d.DeleteProject(pid))

	newPID := newTestProject(t, d)
	assert.Greater(t, newPID, pid, "a new project must never reuse a deleted project's id")

	newDocID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: newPID, RelPath: "docs/spec.md", Kind: "spec"})
	require.NoError(t, err)
	assert.Greater(t, newDocID, docID, "a new document must never reuse a deleted one's id")

	newTarget := insertProjectTargetRow(t, d, newPID, "feature")
	newCommentID, err := d.AddProjectComment(ProjectComment{ProjectID: newPID, TargetID: nullID(newTarget), Author: "owner", Body: "why?"})
	require.NoError(t, err)
	assert.Greater(t, newCommentID, commentID, "a new comment must never reuse a deleted one's id")

	// add_project_source/remove_project_source round-trip source_id too.
	newSourceID, err := d.AddProjectSource(ProjectSource{ProjectID: newPID, Kind: "link", Ref: "https://example.com"})
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
		_, err := ResolveProjectFolder(dir, protected)
		assert.ErrorIs(t, err, ErrProjectFolderNotAllowed, dir)
	}

	got, err := ResolveProjectFolder(filepath.Join(home, "code", "repo"), protected)
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
	_, err := d.CreateProject("acme", "/work/Acme")
	require.NoError(t, err)
	_, err = d.CreateProject("again", "/work/acme")
	assert.ErrorIs(t, err, ErrProjectFolderTaken)
}

// A folder path is later written verbatim into .git/info/exclude lines, so a
// line break in it is refused at both entry points.
func TestProjectFolder_RefusesLineBreaks(t *testing.T) {
	base := t.TempDir()
	for _, name := range []string{"evil\nline", "evil\rline"} {
		dir := filepath.Join(base, name)
		require.NoError(t, os.Mkdir(dir, 0o755))
		_, err := ResolveProjectFolder(dir, nil)
		assert.ErrorIs(t, err, ErrProjectFolderNotAllowed, "%q", name)
	}
	d := openTestDB(t)
	_, err := d.CreateProject("acme", "/work/evil\nline")
	assert.ErrorIs(t, err, ErrProjectFolderNotAllowed)
	_, err = d.CreateProject("acme", "/work/evil\rline")
	assert.ErrorIs(t, err, ErrProjectFolderNotAllowed)
}
