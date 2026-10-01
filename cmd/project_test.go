package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/kb"
)

// runProject executes the real "project" command tree via rootCmd (the
// runActions precedent) with stdout and stderr captured separately.
func runProject(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"project"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	projectFlagJSON = false
	projectCreateFlagFolder = ""
	projectCreateFlagName = ""
	projectBriefFlagProject = ""
	projectImportFlagDryRun = false
	projectAttachFlagKind = "doc"
	projectAttachFlagTitle = ""
	projectAttachFlagTarget = 0
	return out.String(), errOut.String(), err
}

func TestProject_CreateStoresTheResolvedFolderAndDefaultsTheName(t *testing.T) {
	writeActionsConfig(t)
	base := t.TempDir()
	realDir := filepath.Join(base, "my проект")
	require.NoError(t, os.Mkdir(realDir, 0o755))
	link := filepath.Join(base, "link with spaces")
	require.NoError(t, os.Symlink(realDir, link))
	want, err := filepath.EvalSymlinks(realDir)
	require.NoError(t, err)

	out, _, err := runProject(t, "create", "--folder", link, "--json")
	require.NoError(t, err)
	var got projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Positive(t, got.ID)
	assert.Equal(t, want, got.Folder, "the symlink-resolved absolute path is stored")
	assert.Equal(t, "my проект", got.Name, "the name defaults to the folder's base name")

	out, _, err = runProject(t, "create", "--folder", realDir, "--name", "Acme", "--json")
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken, "the real path of an already-bound symlink is taken: %s", out)
}

// #79: create attaches the folder's README/specs/plans as imported
// documents; import-docs re-runs additively and its dry run writes nothing.
func TestProject_CreateImportsFolderDocsAndImportDocsIsAdditive(t *testing.T) {
	database := writeActionsConfig(t)
	folder := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(folder, "README.md"), []byte("# acme"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs", "specs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "docs", "specs", "x.md"), []byte("# x"), 0o644))

	out, _, err := runProject(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created projectCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	assert.True(t, created.DocsImportOK)
	require.NotNil(t, created.DocsImport)
	assert.ElementsMatch(t, []string{"README.md", "docs/specs/x.md"}, created.DocsImport.Imported)
	docs, err := database.ListProjectDocuments(created.ID)
	require.NoError(t, err)
	require.Len(t, docs, 2)
	assert.Equal(t, "import", docs[0].Origin)

	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs", "plans"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "docs", "plans", "y.md"), []byte("# y"), 0o644))
	id := strconv.FormatInt(created.ID, 10)
	out, _, err = runProject(t, "import-docs", id, "--dry-run")
	require.NoError(t, err)
	assert.Contains(t, out, "Would import 1 document(s); 2 already attached.")
	docs, err = database.ListProjectDocuments(created.ID)
	require.NoError(t, err)
	assert.Len(t, docs, 2, "a dry run writes nothing")

	out, _, err = runProject(t, "import-docs", id, "--json")
	require.NoError(t, err)
	assert.Contains(t, out, "docs/plans/y.md")
	docs, err = database.ListProjectDocuments(created.ID)
	require.NoError(t, err)
	assert.Len(t, docs, 3)
}

// #80: the Desktop's "Add document…" attaches a picked file as the owner's,
// by absolute path, through the same folder checks as attach_document.
func TestProject_AttachDocAttachesOwnerDocumentsInsideTheFolderOnly(t *testing.T) {
	database := writeActionsConfig(t)
	folder := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "notes"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "notes", "idea.md"), []byte("# idea"), 0o644))
	outside := filepath.Join(t.TempDir(), "secret.md")
	require.NoError(t, os.WriteFile(outside, []byte("secret"), 0o644))
	out, _, err := runProject(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created projectCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	id := strconv.FormatInt(created.ID, 10)
	resolved, err := filepath.EvalSymlinks(folder)
	require.NoError(t, err)

	// The Desktop's argv shape: flags first, then `--`, then id and path.
	out, _, err = runProject(t, "attach-doc", "--kind", "spec", "--json", "--", id, filepath.Join(resolved, "notes", "idea.md"))
	require.NoError(t, err)
	var got projectAttachDocJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.True(t, got.Created)
	assert.Equal(t, "notes/idea.md", got.RelPath)
	doc, err := database.GetProjectDocument(got.DocumentID)
	require.NoError(t, err)
	assert.Equal(t, "owner", doc.Origin)
	assert.Equal(t, "spec", doc.Kind)
	assert.Equal(t, "idea", doc.Title, "the title defaults to the file name")

	out, _, err = runProject(t, "attach-doc", id, "notes/idea.md")
	require.NoError(t, err)
	assert.Contains(t, out, "already attached")

	_, _, err = runProject(t, "attach-doc", id, outside)
	assert.ErrorContains(t, err, "outside the project folder")
	_, _, err = runProject(t, "attach-doc", id, "notes/idea.md", "--kind", "memo")
	assert.Error(t, err, "unknown kind")
	_, _, err = runProject(t, "attach-doc", id, "notes/idea.md", "--target", "999")
	assert.ErrorIs(t, err, db.ErrNotInProject)
	docs, err := database.ListProjectDocuments(created.ID)
	require.NoError(t, err)
	assert.Len(t, docs, 1)
}

// A failed import leaves the project created (exit 0), reports the failure in
// the JSON envelope and warns on stderr too, so a caller decoding only the
// project fields still logs it.
func TestProject_CreateJSONReportsAFailedImportOnStderr(t *testing.T) {
	writeActionsConfig(t)
	folder := t.TempDir()
	locked := filepath.Join(folder, "docs") // an unreadable docs/ itself fails the import
	require.NoError(t, os.MkdirAll(locked, 0o755))
	require.NoError(t, os.Chmod(locked, 0))
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })

	out, errOut, err := runProject(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created projectCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	assert.Positive(t, created.ID)
	assert.False(t, created.DocsImportOK)
	assert.NotEmpty(t, created.DocsImportError)
	assert.Contains(t, errOut, "warning: importing the folder's documents failed")
	assert.Contains(t, errOut, "watchtower project import-docs "+strconv.FormatInt(created.ID, 10))
}

func TestProject_CreateRefusesMissingAndAlreadyBoundFolders(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runProject(t, "create", "--folder", filepath.Join(t.TempDir(), "gone"))
	assert.Error(t, err, "a missing directory is refused")
	_, _, err = runProject(t, "create")
	assert.ErrorContains(t, err, "--folder is required")

	folder := t.TempDir()
	_, _, err = runProject(t, "create", "--folder", folder)
	require.NoError(t, err)
	_, _, err = runProject(t, "create", "--folder", folder)
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken)
}

func TestProject_ListShowAndBoardJSON(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateProject("other", t.TempDir())
	require.NoError(t, err)
	var ids []int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = database.CreateProjectTargetsTx(tx, pid, []db.ProjectTargetInput{
			{Title: "feature", Priority: "high"}, {Title: "task 1", BatchParent: 1},
		})
		return err
	}))
	require.NoError(t, database.UpdateTargetStatus(int(ids[1]), "in_progress"))
	_, err = database.AddProjectSource(db.ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com", Label: "site"})
	require.NoError(t, err)
	_, err = database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: ids[0], Valid: true},
		Author: "owner", Body: "go"})
	require.NoError(t, err)

	out, _, err := runProject(t, "list", "--json")
	require.NoError(t, err)
	var list []projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	assert.Len(t, list, 2)

	out, _, err = runProject(t, "show", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var view projectViewJSON
	require.NoError(t, json.Unmarshal([]byte(out), &view))
	assert.Equal(t, "acme", view.Name)
	require.Len(t, view.Sources, 1)
	assert.Equal(t, "https://example.com", view.Sources[0].Ref)
	// The started task rolls its parent up to in_progress too (PROJ-05).
	assert.Equal(t, 0, view.Counts["todo"])
	assert.Equal(t, 2, view.Counts["in_progress"])

	out, _, err = runProject(t, "board", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var board []boardNodeJSON
	require.NoError(t, json.Unmarshal([]byte(out), &board))
	require.Len(t, board, 1)
	assert.Equal(t, "feature", board[0].Title)
	assert.Equal(t, "high", board[0].Priority)
	assert.Equal(t, "in_progress", board[0].Status, "the parent follows its started task")
	assert.Equal(t, 1, board[0].NewForAgent)
	require.Len(t, board[0].Children, 1)
	assert.Equal(t, "in_progress", board[0].Children[0].Status)
	assert.NotEmpty(t, board[0].Children[0].StatusSince)
	assert.Equal(t, "medium", board[0].Children[0].Priority)

	out, _, err = runProject(t, "board", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "[in_progress <1m, high] feature", "status with its time in status (PROJ-06)")

	_, _, err = runProject(t, "show", "999")
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	_, _, err = runProject(t, "board", "abc")
	assert.Error(t, err)
}

// TestProject_DeleteStillDeletesWhenInstallRemovalFails: the folder cleanup
// runs first; its failure is reported and the delete still happens (spec §4.4).
func TestProject_DeleteStillDeletesWhenInstallRemovalFails(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "board item")

	var removed *db.Project
	orig := projectRemoveInstall
	projectRemoveInstall = func(_ context.Context, _ *config.Config, p *db.Project) error {
		removed = p
		return errors.New("folder is read-only")
	}
	t.Cleanup(func() { projectRemoveInstall = orig })

	out, errOut, err := runProject(t, "delete", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	require.NotNil(t, removed, "the folder cleanup ran")
	assert.Equal(t, pid, removed.ID)
	assert.Contains(t, errOut, "folder is read-only")
	assert.Contains(t, out, "Deleted project")

	_, err = database.GetProject(pid)
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)

	_, _, err = runProject(t, "delete", strconv.FormatInt(pid, 10))
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
}

// TestProject_DeleteJSONReportsTheFolderCleanupOutcome: --json carries the
// cleanup outcome the stderr warning alone hid from the Desktop.
func TestProject_DeleteJSONReportsTheFolderCleanupOutcome(t *testing.T) {
	database := writeActionsConfig(t)
	orig := projectRemoveInstall
	t.Cleanup(func() { projectRemoveInstall = orig })

	for _, tc := range []struct {
		name      string
		removeErr error
		wantOK    bool
		wantError string
	}{
		{name: "ok", wantOK: true},
		{name: "removal fails", removeErr: errors.New("folder is read-only"), wantError: "folder is read-only"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pid, err := database.CreateProject("acme", t.TempDir())
			require.NoError(t, err)
			projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return tc.removeErr }

			out, _, err := runProject(t, "delete", strconv.FormatInt(pid, 10), "--json")
			require.NoError(t, err)
			var got map[string]any
			require.NoError(t, json.Unmarshal([]byte(out), &got), "stdout is exactly one JSON object: %q", out)
			assert.Equal(t, map[string]any{
				"id": float64(pid), "deleted": true, "removal_ok": tc.wantOK, "removal_error": tc.wantError,
				"files_ok": true, "files_error": "",
			}, got)
			_, err = database.GetProject(pid)
			assert.ErrorIs(t, err, db.ErrProjectNotFound)
		})
	}
}

// project create passes Watchtower's own directories to the folder check:
// a folder inside the data root, the config dir or Application Support is
// refused.
func TestProject_CreateRefusesWatchtowerOwnDirs(t *testing.T) {
	writeActionsConfig(t)
	home := os.Getenv("HOME")
	for _, dir := range []string{
		filepath.Join(home, ".local", "share", "watchtower", "test"),
		filepath.Join(home, ".config", "watchtower", "sub"),
		filepath.Join(home, "Library", "Application Support", "Watchtower", "recordings"),
	} {
		require.NoError(t, os.MkdirAll(dir, 0o755))
		_, _, err := runProject(t, "create", "--folder", dir)
		assert.ErrorIs(t, err, db.ErrProjectFolderNotAllowed, dir)
	}
}

// PROJ-08: the daemon's knowledge phase never reads a folder under
// ~/Documents and the like, so the owner's own attach paths — create's
// import, import-docs and attach-doc (the Desktop's "Add Document") — index
// the project's documents themselves, and the documents are searchable from
// the project's session at once. A dry run and knowledge search off index
// nothing.
func TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce(t *testing.T) {
	database := writeActionsConfig(t)
	folder := filepath.Join(os.Getenv("HOME"), "Documents", "acme")
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs", "plans"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "README.md"), []byte("# acme\nzebrafinch\n"), 0o644))

	search := func(pid int64, word string) int {
		t.Helper()
		res, err := kb.Search(context.Background(), database, kb.Request{Queries: []string{word}, ProjectID: pid})
		require.NoError(t, err)
		return len(res.Hits)
	}

	out, _, err := runProject(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created projectCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	pid := created.ID
	id := strconv.FormatInt(pid, 10)
	assert.True(t, created.IndexOK, created.IndexError)
	assert.Equal(t, 1, search(pid, "zebrafinch"), "create: the imported README is searchable at once")
	assert.Zero(t, search(0, "zebrafinch"), "and only from the project's own session")

	require.NoError(t, os.WriteFile(filepath.Join(folder, "docs", "plans", "p.md"), []byte("# plan\nquokka\n"), 0o644))
	_, _, err = runProject(t, "import-docs", id, "--dry-run")
	require.NoError(t, err)
	assert.Zero(t, search(pid, "quokka"), "a dry run indexes nothing")
	_, _, err = runProject(t, "import-docs", id)
	require.NoError(t, err)
	assert.Equal(t, 1, search(pid, "quokka"), "import-docs: the new plan is searchable at once")

	require.NoError(t, os.WriteFile(filepath.Join(folder, "note.md"), []byte("# note\nnarwhal\n"), 0o644))
	out, _, err = runProject(t, "attach-doc", id, "note.md", "--json")
	require.NoError(t, err)
	var attached projectAttachDocJSON
	require.NoError(t, json.Unmarshal([]byte(out), &attached))
	assert.True(t, attached.IndexOK, attached.IndexError)
	assert.Equal(t, 1, search(pid, "narwhal"), "attach-doc: the owner's document is searchable at once")

	// Knowledge search off: the same paths write no index entry (FEAT-01).
	require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\nknowledge:\n  enabled: false\n"), 0o600))
	other := filepath.Join(os.Getenv("HOME"), "Documents", "other")
	require.NoError(t, os.MkdirAll(other, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(other, "README.md"), []byte("# other\nokapi\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(other, "n.md"), []byte("# n\nokapi\n"), 0o644))
	out, _, err = runProject(t, "create", "--folder", other, "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	assert.True(t, created.IndexSkipped)
	_, _, err = runProject(t, "attach-doc", strconv.FormatInt(created.ID, 10), "n.md")
	require.NoError(t, err)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE source = ?`, kb.ProjectDocSource).Scan(&n))
	assert.Equal(t, 3, n, "only the first project's three documents are indexed")
}

// PROJ-08: an index failure never fails the attach: it is a stderr warning
// naming the retry, and the outcome the JSON envelopes carry.
func TestProj08_IndexFailureIsAWarningNotAnError(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var errOut bytes.Buffer
	cmd := &cobra.Command{}
	cmd.SetContext(ctx)
	cmd.SetErr(&errOut)

	got := indexProjectDocs(cmd, true, database, pid)
	assert.False(t, got.IndexOK)
	assert.NotEmpty(t, got.IndexError)
	assert.Contains(t, errOut.String(), "warning: indexing the project's documents for search failed")
	assert.Contains(t, errOut.String(), "watchtower project resync "+strconv.FormatInt(pid, 10))
}
