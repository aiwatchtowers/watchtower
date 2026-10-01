package kb

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fixtureProjectID is the project seedProjectDocs creates (the first row).
const fixtureProjectID = 1

// seedProjectDocs creates a project with two attached documents: a plan with
// headings, and a README.
func seedProjectDocs(t *testing.T, d *db.DB) string {
	t.Helper()
	folder := t.TempDir()
	writeProjectFile(t, folder, "docs/plans/rollout.md", "# Rollout plan\nIntro text.\n## Phase 1\nРоадмап первой фазы.\n```\n# not a heading\n```\n")
	writeProjectFile(t, folder, "README.md", "Readme without headings, rollout notes.\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)`, fixtureProjectID, folder)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind, title, updated_at) VALUES
		(1, ?, 'docs/plans/rollout.md', 'plan', 'Rollout plan', '2026-09-20T10:00:00Z'),
		(2, ?, 'README.md', 'doc', '', '2026-09-18T10:00:00Z')`, fixtureProjectID, fixtureProjectID)
	return folder
}

func writeProjectFile(t *testing.T, folder, rel, text string) {
	t.Helper()
	path := filepath.Join(folder, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o600))
}

func TestProjectDoc_RendersSectionsAtHeadings(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	doc, err := projectDocSource{}.Build(ctx, d, "project_doc:1")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Rollout plan", doc.Title)
	assert.Equal(t, map[string]string{"project_id": "1", "document_id": "1", "rel_path": "docs/plans/rollout.md"}, doc.Anchor)
	assert.Equal(t, "file://"+filepath.Join(folder, "docs/plans/rollout.md"), doc.Link)
	require.Len(t, doc.Sections, 2, "the fenced # line is not a heading")
	assert.Equal(t, "Rollout plan", doc.Sections[0].Anchor)
	assert.Equal(t, "Phase 1", doc.Sections[1].Anchor)
	assert.Contains(t, doc.Sections[1].Text, "# not a heading")
	assert.Contains(t, doc.Meta, "acme")

	readme, err := projectDocSource{}.Build(ctx, d, "project_doc:2")
	require.NoError(t, err)
	assert.Equal(t, "README.md", readme.Title, "an untitled document is titled by its path")
	require.Len(t, readme.Sections, 1)
	assert.Empty(t, readme.Sections[0].Anchor)

	gone, err := projectDocSource{}.Build(ctx, d, "project_doc:99")
	require.NoError(t, err)
	assert.Nil(t, gone)
}

// A file that is gone, a symlink leading out of the folder or a named pipe
// is indexed by its title only — never read, never blocking — and the
// anchor says why the text is missing.
func TestProjectDoc_UnreadableFilesAreTitleOnlyAndSaySo(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	readme := filepath.Join(folder, "README.md")
	outside := t.TempDir()
	writeProjectFile(t, outside, "secret.md", "top secret")

	for _, tc := range []struct {
		name, reason string
		setup        func()
	}{
		{"escaping symlink", "no longer inside the project folder", func() {
			require.NoError(t, os.Symlink(filepath.Join(outside, "secret.md"), readme))
		}},
		{"named pipe", "not a regular file", func() { require.NoError(t, syscall.Mkfifo(readme, 0o600)) }},
		{"missing", "file is missing", func() {}},
	} {
		require.NoError(t, os.RemoveAll(readme))
		tc.setup()
		doc, err := projectDocSource{}.Build(ctx, d, "project_doc:2")
		require.NoError(t, err, tc.name)
		assert.Equal(t, "README.md", doc.Title, tc.name)
		assert.Empty(t, doc.Sections, tc.name)
		assert.Equal(t, tc.reason, doc.Anchor["unreadable"], tc.name)
	}
}

func TestProjectDoc_LongFileIsCutAndSaysSo(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	writeProjectFile(t, folder, "README.md", strings.Repeat("я", projectDocMaxBytes)) // 2 bytes a rune: twice the cap
	doc, err := projectDocSource{}.Build(ctx, d, "project_doc:2")
	require.NoError(t, err)
	assert.Equal(t, "indexed up to 2 MiB", doc.Anchor["truncated"])
	require.NotEmpty(t, doc.Sections)
	assert.Equal(t, projectDocMaxBytes/2, utf8.RuneCountInString(doc.Sections[0].Text)-1, "cut at the cap, on a rune boundary")
}

func runProjectDocs(t *testing.T, d *db.DB) Stats {
	t.Helper()
	st, err := Run(context.Background(), d, Options{Sources: []string{ProjectDocSource}, Now: time.Now()})
	require.NoError(t, err)
	return st
}

func indexedText(t *testing.T, d *db.DB, id string) string {
	t.Helper()
	var text string
	require.NoError(t, d.QueryRow(`SELECT COALESCE(group_concat(body, ' '), '') FROM kb_chunks WHERE doc_id = ?`, id).Scan(&text))
	return text
}

// A revision is re-indexed whatever its mtime — a later one, or an older one
// (cp -p, a sync client); an untouched document is never re-read into a
// write; a file that comes back after a while gone gets its text back; a
// detached document leaves the index.
func TestProjectDoc_ReindexesOnRevision(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	readme := filepath.Join(folder, "README.md")
	assert.Equal(t, 2, runProjectDocs(t, d).Written)
	assert.Zero(t, runProjectDocs(t, d).Written, "nothing changed: no write")

	writeProjectFile(t, folder, "README.md", "Readme rewritten: квартальный отчёт.\n")
	later := time.Now().Add(time.Hour)
	require.NoError(t, os.Chtimes(readme, later, later))
	assert.Equal(t, 1, runProjectDocs(t, d).Written)
	assert.Contains(t, indexedText(t, d, "project_doc:2"), "квартальный")

	writeProjectFile(t, folder, "README.md", "Readme restored from a backup: годовой отчёт.\n")
	older := time.Now().Add(-48 * time.Hour)
	require.NoError(t, os.Chtimes(readme, older, older))
	assert.Equal(t, 1, runProjectDocs(t, d).Written, "an edit with an older mtime is a revision too")
	assert.Contains(t, indexedText(t, d, "project_doc:2"), "годовой")

	require.NoError(t, os.Rename(readme, readme+".bak"))
	runProjectDocs(t, d)
	assert.NotContains(t, indexedText(t, d, "project_doc:2"), "годовой", "gone: title only")
	require.NoError(t, os.Rename(readme+".bak", readme)) // back with its old mtime
	runProjectDocs(t, d)
	assert.Contains(t, indexedText(t, d, "project_doc:2"), "годовой", "back: its text is indexed again")

	exec(t, d, `DELETE FROM project_documents WHERE id = 2`)
	assert.Equal(t, 1, runProjectDocs(t, d).Deleted)
}

// The daemon never reads a folder macOS guards (~/Documents and the like):
// a background read could raise a privacy prompt. An explicit trigger
// (IndexProjectDocs) indexes it, and drops what the project no longer has.
func TestProjectDoc_DaemonSkipsProtectedFoldersExplicitIndexDoesNot(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := db.OpenTestDB(t)
	folder := filepath.Join(home, "Documents", "acme")
	writeProjectFile(t, folder, "plan.md", "# Plan\nКанареечный выкат\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind) VALUES (1, 1, 'plan.md', 'plan'), (2, 1, 'gone.md', 'doc')`)
	other := t.TempDir()
	writeProjectFile(t, other, "b.md", "beta")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (2, 'beta', ?)`, other)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind) VALUES (3, 2, 'b.md', 'doc')`)

	runProjectDocs(t, d)
	assert.Empty(t, indexedText(t, d, "project_doc:1"), "the daemon did not read the protected folder")
	assert.Contains(t, indexedText(t, d, "project_doc:3"), "beta")

	documents, changed, err := IndexProjectDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 2, documents)
	assert.Equal(t, 2, changed)
	assert.Contains(t, indexedText(t, d, "project_doc:1"), "Канареечный")

	exec(t, d, `DELETE FROM project_documents WHERE id = 2`)
	_, changed, err = IndexProjectDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 1, changed, "the detached document left the index")
	assert.Empty(t, indexedText(t, d, "project_doc:2"))
	assert.Contains(t, indexedText(t, d, "project_doc:3"), "beta", "another project's entries are untouched")
}

// A document symlinked into a guarded location is refused before the
// target is touched: the target's directory here cannot even be searched,
// so following the link would fail differently.
func TestProjectDoc_SymlinkOutOfTheFolderIsNeverFollowed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	guarded := filepath.Join(home, "Documents")
	writeProjectFile(t, guarded, "x.md", "private")
	require.NoError(t, os.Chmod(guarded, 0o000))
	t.Cleanup(func() { _ = os.Chmod(guarded, 0o755) })
	folder := t.TempDir()
	realFolder, err := filepath.EvalSymlinks(folder)
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs"), 0o755))
	require.NoError(t, os.Symlink(filepath.Join(guarded, "x.md"), filepath.Join(folder, "docs", "x.md")))
	require.NoError(t, os.Symlink(guarded, filepath.Join(folder, "linked")))
	require.NoError(t, os.Symlink("../docs/inner.md", filepath.Join(folder, "docs", "rel.md")))
	writeProjectFile(t, folder, "docs/inner.md", "inside")

	for _, rel := range []string{"docs/x.md", "linked/x.md", "../outside.md"} {
		_, err := resolveInside(realFolder, rel)
		assert.ErrorIs(t, err, errDocOutside, rel)
	}
	got, err := resolveInside(realFolder, "docs/rel.md")
	require.NoError(t, err, "a link that stays inside is followed")
	assert.Equal(t, filepath.Join(realFolder, "docs", "inner.md"), got)
}

func TestPrivacyProtected(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for folder, want := range map[string]bool{
		filepath.Join(home, "Documents", "acme"):                 true,
		filepath.Join(home, "documents", "acme"):                 true, // APFS ignores case
		filepath.Join(home, "Library", "CloudStorage", "x", "y"): true,
		filepath.Join(home, "Library", "Mobile Documents", "a"):  true,
		"/Volumes/USB/acme":                     true,
		filepath.Join(home, "Code", "acme"):     false,
		filepath.Join(home, "DocumentsArchive"): false,
	} {
		assert.Equal(t, want, privacyProtected(folder), folder)
	}
}

// kb reindex (owner-started) loses nothing an explicit trigger indexed in a
// guarded folder the daemon skips.
func TestReindex_KeepsProtectedProjectDocs(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := db.OpenTestDB(t)
	folder := filepath.Join(home, "Documents", "acme")
	writeProjectFile(t, folder, "plan.md", "# Plan\nКанареечный выкат\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind) VALUES (1, 1, 'plan.md', 'plan')`)
	_, _, err := IndexProjectDocs(ctx, d, 1)
	require.NoError(t, err)

	_, err = Reindex(ctx, d, []string{ProjectDocSource}, time.Now())
	require.NoError(t, err)
	assert.Contains(t, indexedText(t, d, "project_doc:1"), "Канареечный")
}

// TestProj08_ProjectDocsOnlyInTheirOwnProjectSession: project documents
// never reach a search or an open that is not their own project's session —
// not the main chat, the Discuss chats, the CLI or another project.
func TestProj08_ProjectDocsOnlyInTheirOwnProjectSession(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedProjectDocs(t, d)
	other := t.TempDir()
	writeProjectFile(t, other, "plan.md", "# Other\nроадмап другого проекта\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (2, 'beta', ?)`, other)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind) VALUES (3, 2, 'plan.md', 'plan')`)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)

	search := func(projectID int64, sources ...string) []string {
		res, err := Search(ctx, d, Request{Queries: []string{"роадмап"}, Sources: sources, ProjectID: projectID, Limit: MaxLimit, Now: testNow()})
		require.NoError(t, err)
		return hitRefs(res)
	}
	assert.Empty(t, search(0), "a non-project search sees no project document")
	assert.Empty(t, search(0, ProjectDocSource), "not even when it asks for the source")
	assert.Equal(t, []string{"project_doc:1"}, search(1))
	assert.Equal(t, []string{"project_doc:3"}, search(2), "another project sees only its own")

	for _, tc := range []struct {
		projectID int64
		ref       string
		visible   bool
	}{{0, "project_doc:1", false}, {2, "project_doc:1", false}, {1, "project_doc:1", true}, {2, "project_doc:3", true}} {
		_, err := GetDocument(ctx, d, tc.ref, DocOptions{ProjectID: tc.projectID})
		if tc.visible {
			assert.NoError(t, err, "%s from project %d", tc.ref, tc.projectID)
		} else {
			assert.ErrorIs(t, err, ErrNotFound, "%s from project %d", tc.ref, tc.projectID)
		}
	}
}
