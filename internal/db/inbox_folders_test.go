package db

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// inboxRootAndApprovals returns the seeded root and Needs approval ids.
func inboxRootAndApprovals(t *testing.T, d *DB) (root, approvals int64) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT id FROM inbox_folders WHERE kind = 'root'`).Scan(&root))
	require.NoError(t, d.QueryRow(`SELECT id FROM inbox_folders WHERE kind = 'approvals'`).Scan(&approvals))
	return root, approvals
}

// insertOwnerFolder adds an owner folder under parent, bypassing the
// revision (fixture only).
func insertOwnerFolder(t *testing.T, d *DB, slug string, parent int64) int64 {
	t.Helper()
	var id int64
	require.NoError(t, d.QueryRow(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('owner', ?, ?, ?)
		RETURNING id`, parent, slug, slug).Scan(&id))
	return id
}

// seedOutputOfKind stores an output of kind (inbox, report, briefing) of
// automation a on a finished manual run and returns its id.
func seedOutputOfKind(t *testing.T, d *DB, a int64, kind string) int64 {
	t.Helper()
	var run, id int64
	require.NoError(t, d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'succeeded')
		RETURNING id`, a).Scan(&run))
	require.NoError(t, d.QueryRow(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body)
		VALUES (?, ?, ?, 't', 'b') RETURNING id`, a, run, kind).Scan(&id))
	return id
}

// artifactFolders reads the whole inbox_artifact_folders view.
func artifactFolders(t *testing.T, d *DB) map[int64]int64 {
	t.Helper()
	rows, err := d.Query(`SELECT output_id, folder_id FROM inbox_artifact_folders`)
	require.NoError(t, err)
	defer rows.Close()
	out := map[int64]int64{}
	for rows.Next() {
		var o, f int64
		require.NoError(t, rows.Scan(&o, &f))
		out[o] = f
	}
	require.NoError(t, rows.Err())
	return out
}

func inboxRevision(t *testing.T, d *DB) int64 {
	t.Helper()
	var rev int64
	require.NoError(t, d.QueryRow(`SELECT revision FROM inbox_folder_state WHERE id = 1`).Scan(&rev))
	return rev
}

func TestInboxFolders_MigrationSeedsRootApprovalsAndRevision(t *testing.T) {
	d := openTestDB(t)
	rev, folders, routes, err := d.InboxFolderTree(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(1), rev)
	assert.Empty(t, routes)
	require.Len(t, folders, 2)

	root, approvals := folders[0], folders[1]
	assert.Equal(t, "root", root.Kind)
	assert.Equal(t, "inbox", root.Slug)
	assert.Equal(t, "Inbox", root.Title)
	assert.Nil(t, root.ParentID)
	assert.Equal(t, 0, root.Position)
	assert.False(t, root.Hidden)

	assert.Equal(t, "approvals", approvals.Kind)
	assert.Equal(t, "needs-approval", approvals.Slug)
	assert.Equal(t, "Needs approval", approvals.Title)
	require.NotNil(t, approvals.ParentID)
	assert.Equal(t, root.ID, *approvals.ParentID)
	assert.Equal(t, 0, approvals.Position)
}

// Outputs that existed before the migration: only inbox cards are in the
// view, every one in the root.
func TestInboxFolders_MigrationOnExistingOutputsPutsInboxCardsInRoot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 174))
	assert.False(t, columnNames(t, d.DB, "automation_outputs")["folder_id"])
	a := seedRunAutomation(t, d, "acme-digest", 1)
	in1 := seedOutputOfKind(t, d, a, "inbox")
	in2 := seedOutputOfKind(t, d, a, "inbox")
	seedOutputOfKind(t, d, a, "report")
	seedOutputOfKind(t, d, a, "briefing")
	require.NoError(t, d.Close())

	d, err = Open(path)
	require.NoError(t, err)
	defer d.Close()
	root, _ := inboxRootAndApprovals(t, d)
	assert.Equal(t, map[int64]int64{in1: root, in2: root}, artifactFolders(t, d))
	assert.Equal(t, int64(1), inboxRevision(t, d))
}

func TestInboxFolders_MigrationDownThenUp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	a := seedRunAutomation(t, d, "acme-digest", 1)
	seedOutputOfKind(t, d, a, "inbox")
	require.NoError(t, gooseDownTo(d.DB, "migrations", 174))
	for _, name := range []string{"inbox_folders", "inbox_folder_state", "inbox_folder_routes", "inbox_artifact_folders"} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = ?`, name).Scan(&n))
		assert.Zero(t, n, "%s must be dropped", name)
	}
	assert.False(t, columnNames(t, d.DB, "automation_outputs")["folder_id"])
	wantRowCount(t, d, "automation_outputs", 1)
	require.NoError(t, d.Close())

	d, err = Open(path)
	require.NoError(t, err)
	defer d.Close()
	assert.True(t, columnNames(t, d.DB, "automation_outputs")["folder_id"])
	_, folders, _, err := d.InboxFolderTree(context.Background())
	require.NoError(t, err)
	assert.Len(t, folders, 2)
	assert.Equal(t, int64(1), inboxRevision(t, d))
}

func TestInboxFolders_RootCheck(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	// An owner folder needs a parent.
	_, err := d.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('owner', NULL, 'orphan', 'Orphan')`)
	assert.Error(t, err, "an owner folder without a parent")
	// A root never has one (a second root is also refused by the unique index;
	// the CHECK refuses it first).
	_, err = d.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('root', ?, 'root-2', 'Root')`, root)
	assert.Error(t, err, "a root with a parent")
	_, err = d.Exec(`UPDATE inbox_folders SET parent_id = ? WHERE id = ?`, root, root)
	assert.Error(t, err, "giving the root a parent")
	wantRowCount(t, d, "inbox_folders", 2)
}

func TestInboxFolders_OneRootOneApprovals(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	_, err := d.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('root', NULL, 'inbox-2', 'Inbox')`)
	assert.Error(t, err, "a second root")
	_, err = d.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('approvals', ?, 'needs-approval-2', 'x')`, root)
	assert.Error(t, err, "a second Needs approval")
	// Owner folders are not limited by the index.
	insertOwnerFolder(t, d, "release", root)
	insertOwnerFolder(t, d, "people", root)
	wantRowCount(t, d, "inbox_folders", 4)
}

func TestInboxFolders_RouteCascadesWithItsAutomation(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	f := insertOwnerFolder(t, d, "release", root)
	a := seedRunAutomation(t, d, "acme-digest", 1)
	b := seedRunAutomation(t, d, "acme-weekly", 1)
	_, err := d.Exec(`INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?), (?, ?)`, a, f, b, f)
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM automations WHERE id = ?`, a)
	require.NoError(t, err)
	_, _, routes, err := d.InboxFolderTree(context.Background())
	require.NoError(t, err)
	assert.Equal(t, map[int64]int64{b: f}, routes)

	// A routed folder cannot go while the route points at it.
	_, err = d.Exec(`DELETE FROM inbox_folders WHERE id = ?`, f)
	assert.True(t, IsForeignKeyViolation(err), "deleting a routed folder: %v", err)
}

func TestInboxFolders_ExplicitFolderSetNullOnDelete(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	f := insertOwnerFolder(t, d, "release", root)
	a := seedRunAutomation(t, d, "acme-digest", 1)
	o := seedOutputOfKind(t, d, a, "inbox")
	_, err := d.Exec(`UPDATE automation_outputs SET folder_id = ? WHERE id = ?`, f, o)
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM inbox_folders WHERE id = ?`, f)
	require.NoError(t, err)
	got, err := d.GetAutomationOutput(o)
	require.NoError(t, err)
	assert.Nil(t, got.FolderID, "the artifact follows its route again")
	folder, err := d.InboxArtifactFolder(context.Background(), o)
	require.NoError(t, err)
	assert.Equal(t, root, folder)
}

// Effective folder = explicit ?? route ?? root.
func TestInboxFolders_ViewPrecedence(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	root, _ := inboxRootAndApprovals(t, d)
	routed := insertOwnerFolder(t, d, "release", root)
	explicit := insertOwnerFolder(t, d, "people", root)
	a := seedRunAutomation(t, d, "acme-digest", 1)
	b := seedRunAutomation(t, d, "acme-weekly", 1)
	_, err := d.Exec(`INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)`, a, routed)
	require.NoError(t, err)

	followsRoute := seedOutputOfKind(t, d, a, "inbox")
	pinned := seedOutputOfKind(t, d, a, "inbox")
	_, err = d.Exec(`UPDATE automation_outputs SET folder_id = ? WHERE id = ?`, explicit, pinned)
	require.NoError(t, err)
	unrouted := seedOutputOfKind(t, d, b, "inbox")
	report := seedOutputOfKind(t, d, a, "report")

	for id, want := range map[int64]int64{followsRoute: routed, pinned: explicit, unrouted: root} {
		got, err := d.InboxArtifactFolder(ctx, id)
		require.NoError(t, err)
		assert.Equal(t, want, got, "output %d", id)
	}
	_, err = d.InboxArtifactFolder(ctx, report)
	assert.ErrorIs(t, err, ErrNoInboxArtifact, "a report is not an inbox artifact")
	_, err = d.InboxArtifactFolder(ctx, 999999)
	assert.ErrorIs(t, err, ErrNoInboxArtifact)
}

// A commit writes the output's explicit folder on insert; nil stays NULL.
func TestInboxFolders_CommitWritesFolderID(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	f := insertOwnerFolder(t, d, "release", root)
	a := seedRunnableAutomation(t, d, "acme-digest")
	run := runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{
		{Kind: "inbox", Title: "pinned", Body: "b", FolderID: &f},
		{Kind: "inbox", Title: "routed", Body: "b"},
	}})
	outs, err := d.ListAutomationOutputsForRun(run, 0)
	require.NoError(t, err)
	require.Len(t, outs, 2)
	require.NotNil(t, outs[0].FolderID)
	assert.Equal(t, f, *outs[0].FolderID)
	assert.Nil(t, outs[1].FolderID)
}

func TestWithInboxFolderRevision_HappyPath(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	root, _ := inboxRootAndApprovals(t, d)
	rev, err := d.WithInboxFolderRevision(ctx, 1, func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('owner', ?, 'release', 'Release')`, root)
		return err
	})
	require.NoError(t, err)
	assert.Equal(t, int64(2), rev)
	got, folders, _, err := d.InboxFolderTree(ctx)
	require.NoError(t, err)
	assert.Equal(t, int64(2), got)
	assert.Len(t, folders, 3)
}

func TestWithInboxFolderRevision_StaleWritesNothing(t *testing.T) {
	d := openTestDB(t)
	called := false
	_, err := d.WithInboxFolderRevision(context.Background(), 7, func(*sql.Tx) error {
		called = true
		return nil
	})
	var conflict *ErrInboxRevisionConflict
	require.ErrorAs(t, err, &conflict)
	assert.Equal(t, ErrInboxRevisionConflict{Now: 1, Given: 7}, *conflict)
	assert.False(t, called, "fn must not run on a stale revision")
	assert.Equal(t, int64(1), inboxRevision(t, d))
	wantRowCount(t, d, "inbox_folders", 2)
}

func TestWithInboxFolderRevision_FnErrorRollsBack(t *testing.T) {
	d := openTestDB(t)
	root, _ := inboxRootAndApprovals(t, d)
	boom := errors.New("boom")
	_, err := d.WithInboxFolderRevision(context.Background(), 1, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('owner', ?, 'release', 'Release')`, root); err != nil {
			return err
		}
		return boom
	})
	require.ErrorIs(t, err, boom)
	assert.Equal(t, int64(1), inboxRevision(t, d))
	wantRowCount(t, d, "inbox_folders", 2)
}

// Two writers on one file with the same expected revision: exactly one wins,
// the other gets the conflict and writes nothing.
func TestWithInboxFolderRevision_ConcurrentWritersOneWins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d1, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d1.Close() })
	d2, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d2.Close() })
	root, _ := inboxRootAndApprovals(t, d1)

	var (
		wg      sync.WaitGroup
		start   = make(chan struct{})
		results = make([]error, 2)
	)
	for i, d := range []*DB{d1, d2} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, results[i] = d.WithInboxFolderRevision(context.Background(), 1, func(tx *sql.Tx) error {
				_, err := tx.Exec(`INSERT INTO inbox_folders (kind, parent_id, slug, title) VALUES ('owner', ?, ?, 'x')`,
					root, []string{"one", "two"}[i])
				return err
			})
		}()
	}
	close(start)
	wg.Wait()

	wins, conflicts := 0, 0
	for _, err := range results {
		var conflict *ErrInboxRevisionConflict
		switch {
		case err == nil:
			wins++
		case errors.As(err, &conflict):
			conflicts++
			assert.Equal(t, int64(2), conflict.Now)
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	assert.Equal(t, 1, wins)
	assert.Equal(t, 1, conflicts)
	assert.Equal(t, int64(2), inboxRevision(t, d1))
	wantRowCount(t, d1, "inbox_folders", 3)
}

// Another connection holds the write lock past busy_timeout: the write fails
// with a busy error before fn runs, and nothing is written.
func TestWithInboxFolderRevision_BusyWritesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	holder, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = holder.Close() })
	held, err := holder.Begin() // BEGIN IMMEDIATE: holds the write lock
	require.NoError(t, err)

	writer, err := OpenExistingRW(path, 50*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = writer.Close() })
	called := false
	_, err = writer.WithInboxFolderRevision(context.Background(), 1, func(*sql.Tx) error {
		called = true
		return nil
	})
	require.Error(t, err)
	assert.True(t, IsBusy(err), "want a busy error, got %v", err)
	assert.False(t, called)

	require.NoError(t, held.Rollback())
	assert.Equal(t, int64(1), inboxRevision(t, holder))
	wantRowCount(t, holder, "inbox_folders", 2)
}
