package kb

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

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
	write(t, folder, "docs/plans/rollout.md", "# Rollout plan\nIntro text.\n## Phase 1\nРоадмап первой фазы.\n```\n# not a heading\n```\n")
	write(t, folder, "README.md", "Readme without headings, rollout notes.\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)`, fixtureProjectID, folder)
	exec(t, d, `INSERT INTO project_documents (id, project_id, rel_path, kind, title, updated_at) VALUES
		(1, ?, 'docs/plans/rollout.md', 'plan', 'Rollout plan', '2026-09-20T10:00:00Z'),
		(2, ?, 'README.md', 'doc', '', '2026-09-18T10:00:00Z')`, fixtureProjectID, fixtureProjectID)
	return folder
}

func write(t *testing.T, folder, rel, text string) {
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

// A file that is gone, or a symlink leading out of the folder, is indexed
// by its title only — never read.
func TestProjectDoc_UnreadableOrEscapingFileIsTitleOnly(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	outside := t.TempDir()
	write(t, outside, "secret.md", "top secret")
	require.NoError(t, os.Remove(filepath.Join(folder, "README.md")))
	require.NoError(t, os.Symlink(filepath.Join(outside, "secret.md"), filepath.Join(folder, "README.md")))
	doc, err := projectDocSource{}.Build(ctx, d, "project_doc:2")
	require.NoError(t, err)
	assert.Empty(t, doc.Sections)

	require.NoError(t, os.Remove(filepath.Join(folder, "README.md")))
	doc, err = projectDocSource{}.Build(ctx, d, "project_doc:2")
	require.NoError(t, err)
	assert.Equal(t, "README.md", doc.Title)
	assert.Empty(t, doc.Sections)
}

// An edit on disk with no row change is re-indexed on the next run (the
// mtime is part of the change marker); an untouched document is not
// rewritten (content-hash gate); a detached one leaves the index.
func TestProjectDoc_ReindexesOnRevisionAndForgetsADetachedDocument(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedProjectDocs(t, d)
	now := time.Now()
	st, err := Run(ctx, d, Options{Sources: []string{ProjectDocSource}, Now: now})
	require.NoError(t, err)
	assert.Equal(t, 2, st.Written)

	st, err = Run(ctx, d, Options{Sources: []string{ProjectDocSource}, Now: now})
	require.NoError(t, err)
	assert.Zero(t, st.Written, "nothing changed: no write")

	path := filepath.Join(folder, "README.md")
	write(t, folder, "README.md", "Readme rewritten: квартальный отчёт.\n")
	later := time.Now().Add(time.Hour)
	require.NoError(t, os.Chtimes(path, later, later))
	st, err = Run(ctx, d, Options{Sources: []string{ProjectDocSource}, Now: now})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Written)
	res, err := Search(ctx, d, Request{Queries: []string{"квартальный"}, ProjectID: fixtureProjectID, Now: now})
	require.NoError(t, err)
	assert.Equal(t, []string{"project_doc:2"}, hitRefs(res))

	exec(t, d, `DELETE FROM project_documents WHERE id = 2`)
	st, err = Run(ctx, d, Options{Sources: []string{ProjectDocSource}, Now: now})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
}

// TestProj08_ProjectDocsOnlyInTheirOwnProjectSession: project documents
// never reach a search or an open that is not their own project's session —
// not the main chat, the Discuss chats, the CLI or another project.
func TestProj08_ProjectDocsOnlyInTheirOwnProjectSession(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedProjectDocs(t, d)
	other := t.TempDir()
	write(t, other, "plan.md", "# Other\nроадмап другого проекта\n")
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
