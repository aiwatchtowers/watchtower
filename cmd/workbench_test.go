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
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/kb"
)

// runWorkbench executes the real command tree via rootCmd (the runActions
// precedent) under the pre-rename "project" alias — what every Desktop build
// and legacy hook before the rename runs — with stdout and stderr captured
// separately.
func runWorkbench(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	return runWorkbenchAs(t, "project", args...)
}

// resetSetFlags puts every flag a run set on cmds — local, persistent or
// inherited — back to its default value and clears its Changed mark.
// rootCmd is shared across tests: a leftover --help would make every later
// run print usage, a leftover --project would collide with the next run's
// --workbench. Flags no run set are left alone (flagConfig, for one, is
// assigned by the tests, never parsed).
//
// A slice flag is restored through Replace: Set appends, and its "[]"
// default text would parse as one "[]" element.
func resetSetFlags(cmds ...*cobra.Command) {
	reset := func(f *pflag.Flag) {
		if !f.Changed {
			return
		}
		if sv, ok := f.Value.(pflag.SliceValue); ok {
			var def []string
			if inner := strings.Trim(f.DefValue, "[]"); inner != "" {
				def = strings.Split(inner, ",")
			}
			_ = sv.Replace(def)
		} else {
			_ = f.Value.Set(f.DefValue)
		}
		f.Changed = false
	}
	for _, c := range cmds {
		c.Flags().VisitAll(reset)
		c.PersistentFlags().VisitAll(reset)
		c.InheritedFlags().VisitAll(reset)
	}
}

// runWorkbenchAs is runWorkbench run as the command called name ("workbench"
// or its alias "project").
func runWorkbenchAs(t *testing.T, name string, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{name}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	resetSetFlags(append(workbenchCmd.Commands(), workbenchCmd, rootCmd)...)
	workbenchFlagJSON = false
	workbenchCreateFlagFolder = ""
	workbenchCreateFlagName = ""
	workbenchBriefFlagWorkbench = ""
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

	out, _, err := runWorkbench(t, "create", "--folder", link, "--json")
	require.NoError(t, err)
	var got workbenchJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Positive(t, got.ID)
	assert.Equal(t, want, got.Folder, "the symlink-resolved absolute path is stored")
	assert.Equal(t, "my проект", got.Name, "the name defaults to the folder's base name")

	out, _, err = runWorkbench(t, "create", "--folder", realDir, "--name", "Acme", "--json")
	assert.ErrorIs(t, err, db.ErrWorkbenchFolderTaken, "the real path of an already-bound symlink is taken: %s", out)
}

// Spec 2026-10-03 §7: create no longer imports documents — its --json has
// no docs_import_* keys, only the index outcome — and import-docs and
// attach-doc are gone.
func TestProject_CreateIndexesInsteadOfImportingDocs(t *testing.T) {
	database := writeActionsConfig(t)
	folder := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(folder, "README.md"), []byte("# acme"), 0o644))

	out, _, err := runWorkbench(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var raw map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	for key := range raw {
		assert.False(t, strings.HasPrefix(key, "docs_import"), "create --json has no %s", key)
	}
	assert.Equal(t, true, raw["index_ok"], out)
	assert.Contains(t, raw, "index_error")
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE source = ?`, kb.WorkbenchDocSource).Scan(&n))
	assert.Equal(t, 1, n, "the README is indexed")

	for _, gone := range []string{"import-docs", "attach-doc"} {
		cmd, _, err := workbenchCmd.Find([]string{gone})
		require.NoError(t, err)
		assert.Same(t, workbenchCmd, cmd, "workbench %s is not a command any more", gone)
	}
}

// A git failure on create leaves the workbench created (exit 0), reports the
// failed index in the JSON envelope and warns on stderr too, so a caller
// decoding only the workbench fields still logs it.
func TestProject_CreateJSONReportsAFailedIndexOnStderr(t *testing.T) {
	if _, ok := gitbin.Locate(); !ok {
		t.Skip("no git installed: the listing walks the folder and cannot fail this way")
	}
	writeActionsConfig(t)
	folder := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".git"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, ".git", "HEAD"), []byte("garbage\n"), 0o600))

	out, errOut, err := runWorkbench(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created workbenchCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	assert.Positive(t, created.ID)
	assert.False(t, created.IndexOK)
	assert.NotEmpty(t, created.IndexError)
	assert.Contains(t, errOut, "warning: indexing the workbench's documents for search failed")
	assert.Contains(t, errOut, "watchtower workbench resync "+strconv.FormatInt(created.ID, 10))
}

func TestProject_CreateRefusesMissingAndAlreadyBoundFolders(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runWorkbench(t, "create", "--folder", filepath.Join(t.TempDir(), "gone"))
	assert.Error(t, err, "a missing directory is refused")
	_, _, err = runWorkbench(t, "create")
	assert.ErrorContains(t, err, "--folder is required")

	folder := t.TempDir()
	_, _, err = runWorkbench(t, "create", "--folder", folder)
	require.NoError(t, err)
	_, _, err = runWorkbench(t, "create", "--folder", folder)
	assert.ErrorIs(t, err, db.ErrWorkbenchFolderTaken)
}

func TestProject_ListShowAndBoardJSON(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	var ids []int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = database.CreateWorkbenchTargetsTx(tx, pid, []db.WorkbenchTargetInput{
			{Title: "feature", Priority: "high"}, {Title: "task 1", BatchParent: 1},
		})
		return err
	}))
	require.NoError(t, database.UpdateTargetStatus(int(ids[1]), "in_progress"))
	_, err = database.AddWorkbenchSource(db.WorkbenchSource{WorkbenchID: pid, Kind: "link", Ref: "https://example.com", Label: "site"})
	require.NoError(t, err)
	_, err = database.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: pid, TargetID: sql.NullInt64{Int64: ids[0], Valid: true},
		Author: "owner", Body: "go"})
	require.NoError(t, err)

	out, _, err := runWorkbench(t, "list", "--json")
	require.NoError(t, err)
	var list []workbenchJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	assert.Len(t, list, 2)

	out, _, err = runWorkbench(t, "show", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var view workbenchViewJSON
	require.NoError(t, json.Unmarshal([]byte(out), &view))
	assert.Equal(t, "acme", view.Name)
	require.Len(t, view.Sources, 1)
	assert.Equal(t, "https://example.com", view.Sources[0].Ref)
	// The started task rolls its parent up to in_progress too (PROJ-05).
	assert.Equal(t, 0, view.Counts["todo"])
	assert.Equal(t, 2, view.Counts["in_progress"])

	out, _, err = runWorkbench(t, "board", strconv.FormatInt(pid, 10), "--json")
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

	out, _, err = runWorkbench(t, "board", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "[in_progress <1m, high] feature", "status with its time in status (PROJ-06)")

	_, _, err = runWorkbench(t, "show", "999")
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	_, _, err = runWorkbench(t, "board", "abc")
	assert.Error(t, err)
}

// TestProject_DeleteStillDeletesWhenInstallRemovalFails: the folder cleanup
// runs first; its failure is reported and the delete still happens (spec §4.4).
func TestProject_DeleteStillDeletesWhenInstallRemovalFails(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "board item")

	var removed *db.Workbench
	orig := workbenchRemoveInstall
	workbenchRemoveInstall = func(_ context.Context, _ *config.Config, p *db.Workbench) error {
		removed = p
		return errors.New("folder is read-only")
	}
	t.Cleanup(func() { workbenchRemoveInstall = orig })

	out, errOut, err := runWorkbench(t, "delete", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	require.NotNil(t, removed, "the folder cleanup ran")
	assert.Equal(t, pid, removed.ID)
	assert.Contains(t, errOut, "folder is read-only")
	assert.Contains(t, out, "Deleted workbench")

	_, err = database.GetWorkbench(pid)
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)

	_, _, err = runWorkbench(t, "delete", strconv.FormatInt(pid, 10))
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
}

// TestProject_DeleteJSONReportsTheFolderCleanupOutcome: --json carries the
// cleanup outcome the stderr warning alone hid from the Desktop.
func TestProject_DeleteJSONReportsTheFolderCleanupOutcome(t *testing.T) {
	database := writeActionsConfig(t)
	orig := workbenchRemoveInstall
	t.Cleanup(func() { workbenchRemoveInstall = orig })

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
			pid, err := database.CreateWorkbench("acme", t.TempDir())
			require.NoError(t, err)
			workbenchRemoveInstall = func(context.Context, *config.Config, *db.Workbench) error { return tc.removeErr }

			out, _, err := runWorkbench(t, "delete", strconv.FormatInt(pid, 10), "--json")
			require.NoError(t, err)
			var got map[string]any
			require.NoError(t, json.Unmarshal([]byte(out), &got), "stdout is exactly one JSON object: %q", out)
			assert.Equal(t, map[string]any{
				"id": float64(pid), "deleted": true, "removal_ok": tc.wantOK, "removal_error": tc.wantError,
				"files_ok": true, "files_error": "",
			}, got)
			_, err = database.GetWorkbench(pid)
			assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
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
		_, _, err := runWorkbench(t, "create", "--folder", dir)
		assert.ErrorIs(t, err, db.ErrWorkbenchFolderNotAllowed, dir)
	}
}

// TestProj08_ResyncAndCreateIndexTheFolderAtOnce (was
// OwnerAttachPathsIndexTheDocumentsAtOnce; PROJ-08 amended 2026-10-03): the
// daemon's knowledge phase never reads a folder under ~/Documents and the
// like, so the owner's own paths — `workbench create` and `workbench
// resync` (the Desktop's Re-run Setup) — index the folder's text files
// themselves, none of them attached, and they are searchable from the
// workbench's session at once. The daemon pass alone indexes nothing there,
// and knowledge search off indexes nothing.
func TestProj08_ResyncAndCreateIndexTheFolderAtOnce(t *testing.T) {
	database := writeActionsConfig(t)
	useFakeWorkbenchClaude(t)
	folder := filepath.Join(os.Getenv("HOME"), "Documents", "acme")
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs", "plans"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "README.md"), []byte("# acme\nzebrafinch\n"), 0o644))

	search := func(pid int64, word string) int {
		t.Helper()
		res, err := kb.Search(context.Background(), database, kb.Request{Queries: []string{word}, WorkbenchID: pid})
		require.NoError(t, err)
		return len(res.Hits)
	}

	out, _, err := runWorkbench(t, "create", "--folder", folder, "--json")
	require.NoError(t, err)
	var created workbenchCreateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	pid := created.ID
	id := strconv.FormatInt(pid, 10)
	assert.True(t, created.IndexOK, created.IndexError)
	assert.Equal(t, 1, search(pid, "zebrafinch"), "create: the README is searchable at once")
	assert.Zero(t, search(0, "zebrafinch"), "and only from the workbench's own session")

	require.NoError(t, os.WriteFile(filepath.Join(folder, "docs", "plans", "p.md"), []byte("# plan\nquokka\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "note.txt"), []byte("narwhal\n"), 0o644))
	// The daemon's knowledge pass skips the protected folder: the new files
	// stay unindexed, and what create indexed is kept.
	_, err = kb.Run(context.Background(), database, kb.Options{Sources: []string{kb.WorkbenchDocSource}})
	require.NoError(t, err)
	assert.Zero(t, search(pid, "quokka"), "the daemon pass never reads a folder under ~/Documents")
	assert.Zero(t, search(pid, "narwhal"), "the daemon pass never reads a folder under ~/Documents")
	assert.Equal(t, 1, search(pid, "zebrafinch"), "the daemon pass keeps what create indexed")
	out, _, err = runWorkbench(t, "resync", id, "--json")
	require.NoError(t, err)
	var resynced workbenchResyncJSON
	require.NoError(t, json.Unmarshal([]byte(out), &resynced))
	assert.True(t, resynced.IndexOK, resynced.IndexError)
	assert.Equal(t, 1, search(pid, "quokka"), "resync: the new plan is searchable at once")
	assert.Equal(t, 1, search(pid, "narwhal"), "resync: the new note is searchable at once")

	// Knowledge search off: the same paths write no index entry (FEAT-01).
	require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\nknowledge:\n  enabled: false\n"), 0o600))
	other := filepath.Join(os.Getenv("HOME"), "Documents", "other")
	require.NoError(t, os.MkdirAll(other, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(other, "README.md"), []byte("# other\nokapi\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(other, "n.md"), []byte("# n\nokapi\n"), 0o644))
	out, _, err = runWorkbench(t, "create", "--folder", other, "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &created))
	assert.True(t, created.IndexSkipped)
	out, _, err = runWorkbench(t, "resync", strconv.FormatInt(created.ID, 10), "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &resynced))
	assert.True(t, resynced.IndexSkipped)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE source = ?`, kb.WorkbenchDocSource).Scan(&n))
	assert.Equal(t, 3, n, "only the first workbench's three files are indexed — not the skill the install wrote")
}

// PROJ-08: an index failure never fails create: it is a stderr warning
// naming the retry, and the outcome the JSON envelope carries.
func TestProj08_IndexFailureIsAWarningNotAnError(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var errOut bytes.Buffer
	cmd := &cobra.Command{}
	cmd.SetContext(ctx)
	cmd.SetErr(&errOut)

	got := indexWorkbenchDocs(cmd, true, database, pid)
	assert.False(t, got.IndexOK)
	assert.NotEmpty(t, got.IndexError)
	assert.Contains(t, errOut.String(), "warning: indexing the workbench's documents for search failed")
	assert.Contains(t, errOut.String(), "watchtower workbench resync "+strconv.FormatInt(pid, 10))
}
