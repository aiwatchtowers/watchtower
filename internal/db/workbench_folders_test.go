package db

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// addTestFolder plants a live folder row on workbench wb, the way Task 2's
// Add will (the only writer is the Go CLI).
func addTestFolder(t *testing.T, d *DB, wb int64, path, name string, position int) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, ?, ?, 'owner', ?)`, wb, path, position, name)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func homeFolderID(t *testing.T, d *DB, wb int64) int64 {
	t.Helper()
	id, err := d.HomeFolderID(context.Background(), wb)
	require.NoError(t, err)
	return id
}

func TestUniqueFolderName_Clash(t *testing.T) {
	var live []string
	taken := func(name string) bool {
		for _, n := range live {
			if strings.EqualFold(n, name) {
				return true
			}
		}
		return false
	}
	for _, c := range []struct{ path, want string }{
		{"/Users/acme/code/app", "app"},
		{"/Users/acme/work/app", "work-app"},
		{"/Users/acme/work2/work/App", "work-App-2"},
		{"/Users/acme/x/work/app", "work-app-3"},
		{"/Users/acme/code/hub", "hub"},
	} {
		got := UniqueFolderName(c.path, taken)
		assert.Equal(t, c.want, got, c.path)
		live = append(live, got)
	}
	assert.Equal(t, "app-2", UniqueFolderName("/app", func(n string) bool { return strings.EqualFold(n, "app") }),
		"a folder with no parent name numbers its own name")
}

func TestWorkbenchFolders_NameUniquePerBenchAmongLiveRows(t *testing.T) {
	d := openTestDB(t)
	a := newTestWorkbench(t, d)
	b := newTestWorkbench(t, d)
	home, err := d.HomeFolder(context.Background(), a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, '/tmp/elsewhere/x', 1, 'owner', ?)`, a, strings.ToUpper(home.Name))
	assert.Error(t, err, "a second live folder of the bench with the same name (NOCASE)")
	addTestFolder(t, d, b, "/tmp/elsewhere/y", home.Name, 1)

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, home.ID)
	require.NoError(t, err)
	addTestFolder(t, d, a, "/tmp/elsewhere/z", home.Name, 2)
}

func TestWorkbenchFolders_OneLivePathGlobally(t *testing.T) {
	d := openTestDB(t)
	a := newTestWorkbench(t, d)
	b := newTestWorkbench(t, d)
	first := addTestFolder(t, d, a, "/X/App", "App", 1)
	_, err := d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, '/x/app', 1, 'owner', 'other')`, b)
	assert.Error(t, err, "another spelling of a live folder on another bench")

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, first)
	require.NoError(t, err)
	addTestFolder(t, d, b, "/x/app", "app", 1)
}

func TestWorkbenchFolders_Readers(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	hub := addTestFolder(t, d, wb, "/tmp/code/hub", "hub", 2)
	site := addTestFolder(t, d, wb, "/tmp/code/site", "site", 1)
	_, err := d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, site)
	require.NoError(t, err)

	live, err := d.WorkbenchFolders(ctx, wb, false)
	require.NoError(t, err)
	require.Len(t, live, 2)
	assert.Equal(t, 0, live[0].Position)
	assert.Equal(t, "owner", live[0].AddedBy)
	assert.NotEmpty(t, live[0].AddedAt)
	assert.Equal(t, hub, live[1].ID)
	all, err := d.WorkbenchFolders(ctx, wb, true)
	require.NoError(t, err)
	require.Len(t, all, 3)
	assert.Equal(t, site, all[1].ID, "position order")
	assert.True(t, all[1].RemovedAt.Valid)
	none, err := d.WorkbenchFolders(ctx, wb+100, false)
	require.NoError(t, err)
	assert.NotNil(t, none)
	assert.Empty(t, none)

	got, err := d.WorkbenchFolderByID(ctx, hub)
	require.NoError(t, err)
	assert.Equal(t, "/tmp/code/hub", got.FolderPath)
	assert.Equal(t, wb, got.WorkbenchID)
	_, err = d.WorkbenchFolderByID(ctx, hub+100)
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)

	byPath, err := d.LiveFolderByPath(ctx, d, "/TMP/code/HUB")
	require.NoError(t, err)
	assert.Equal(t, hub, byPath.ID)
	_, err = d.LiveFolderByPath(ctx, d, "/tmp/code/site")
	assert.ErrorIs(t, err, ErrWorkbenchNotFound, "a removed folder is not live")
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		f, err := d.LiveFolderByPath(ctx, tx, "/tmp/code/hub")
		if err == nil && f.ID != hub {
			err = errors.New("wrong folder")
		}
		return err
	}))

	home, err := d.HomeFolder(ctx, wb)
	require.NoError(t, err)
	assert.Equal(t, live[0].ID, home.ID)
	homeID, err := d.HomeFolderID(ctx, wb)
	require.NoError(t, err)
	assert.Equal(t, home.ID, homeID)
	_, err = d.HomeFolderID(ctx, wb+100)
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
}

func TestCreateWorkbench_InsertsItsFolderRow(t *testing.T) {
	d := openTestDB(t)
	dir := t.TempDir()
	wb, err := d.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	folders, err := d.WorkbenchFolders(context.Background(), wb, false)
	require.NoError(t, err)
	require.Len(t, folders, 1)
	f := folders[0]
	assert.Equal(t, dir, f.FolderPath)
	assert.Equal(t, 0, f.Position)
	assert.Equal(t, "owner", f.AddedBy)
	assert.Equal(t, dir[strings.LastIndex(dir, "/")+1:], f.Name)
	assert.False(t, f.RemovedAt.Valid)
}

func TestCreateWorkbench_RefusesAFolderOfAnotherBench(t *testing.T) {
	d := openTestDB(t)
	a := newTestWorkbench(t, d)
	hub := t.TempDir()
	addTestFolder(t, d, a, hub, "hub", 1)

	_, err := d.CreateWorkbench("hub", hub)
	assert.ErrorIs(t, err, ErrWorkbenchFolderTaken)
	_, err = d.CreateWorkbench("hub", strings.ToUpper(hub))
	assert.ErrorIs(t, err, ErrWorkbenchFolderTaken, "another spelling (APFS)")

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE folder_path = ?`, hub)
	require.NoError(t, err)
	_, err = d.CreateWorkbench("hub", hub)
	assert.NoError(t, err, "a removed folder is free again")
}

func TestWorkbenchByFolder_FindsNonHomeFolder(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	hub := addTestFolder(t, d, wb, "/tmp/code/hub", "hub", 1)

	got, err := d.WorkbenchByFolder("/tmp/code/hub")
	require.NoError(t, err)
	assert.Equal(t, wb, got.ID)

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, hub)
	require.NoError(t, err)
	_, err = d.WorkbenchByFolder("/tmp/code/hub")
	assert.ErrorIs(t, err, ErrWorkbenchNotFound)
}

func TestSetTargetFolderTx(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	hub := addTestFolder(t, d, wb, "/tmp/code/hub", "hub", 1)
	theirs := addTestFolder(t, d, other, "/tmp/code/theirs", "theirs", 1)
	target := insertWorkbenchTargetRow(t, d, wb, "feature")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.SetTargetFolderTx(tx, target, nullID(hub)) }))
	got, err := d.GetTargetByID(int(target))
	require.NoError(t, err)
	assert.Equal(t, nullID(hub), got.WorkbenchFolderID)

	err = d.WithTx(func(tx *sql.Tx) error { return d.SetTargetFolderTx(tx, target, nullID(theirs)) })
	assert.ErrorIs(t, err, ErrNotInWorkbench, "a folder of another bench")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.SetTargetFolderTx(tx, target, sql.NullInt64{}) }))
	got, err = d.GetTargetByID(int(target))
	require.NoError(t, err)
	assert.False(t, got.WorkbenchFolderID.Valid)

	err = d.WithTx(func(tx *sql.Tx) error { return d.SetTargetFolderTx(tx, target+100, sql.NullInt64{}) })
	assert.ErrorIs(t, err, ErrNotInWorkbench)
}

func TestCreateTerminalSession_FolderAndParent(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	home, err := d.HomeFolderID(ctx, wb)
	require.NoError(t, err)
	parent, err := d.CreateTerminalSession(ctx, NewTerminalSession{WorkbenchID: wb, Kind: "codex", Title: "Parent",
		FolderPath: "/tmp/acme", WorkbenchFolderID: home})
	require.NoError(t, err)
	child, err := d.CreateTerminalSession(ctx, NewTerminalSession{WorkbenchID: wb, Kind: "codex", Title: "Child",
		FolderPath: "/tmp/acme", WorkbenchFolderID: home, ParentSessionID: parent})
	require.NoError(t, err)
	standalone, err := d.CreateTerminalSession(ctx, NewTerminalSession{Kind: "shell", Title: "Terminal", FolderPath: "/tmp"})
	require.NoError(t, err)

	s, err := d.GetTerminalSession(child)
	require.NoError(t, err)
	assert.Equal(t, nullID(home), s.WorkbenchFolderID)
	assert.Equal(t, nullID(parent), s.ParentSessionID)
	s, err = d.GetTerminalSession(standalone)
	require.NoError(t, err)
	assert.False(t, s.WorkbenchFolderID.Valid)
	assert.False(t, s.ParentSessionID.Valid)

	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, parent)
	require.NoError(t, err)
	s, err = d.GetTerminalSession(child)
	require.NoError(t, err)
	assert.False(t, s.ParentSessionID.Valid, "a gone parent clears the link")
}

func TestOwnerAsk_DocFolderID(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	hub := addTestFolder(t, d, wb, "/tmp/code/hub", "hub", 1)
	id := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: wb, Kind: AskKindReview, Title: "Spec", DocPath: "docs/spec.md",
		DocFolderID: nullID(hub)})
	home := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: wb, Kind: AskKindReview, Title: "Plan", DocPath: "docs/plan.md"})
	folder := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: wb, Kind: AskKindFolder, Title: "Add hub?",
		Payload: `{"path":"/tmp/code/hub2","repo_root":"/tmp/code/hub2","touches":3,"why":"x"}`})

	got, err := d.GetOwnerAsk(wb, id)
	require.NoError(t, err)
	assert.Equal(t, nullID(hub), got.DocFolderID)
	got, err = d.GetOwnerAsk(wb, home)
	require.NoError(t, err)
	assert.False(t, got.DocFolderID.Valid, "NULL = the home folder")
	got, err = d.GetOwnerAsk(wb, folder)
	require.NoError(t, err)
	assert.Equal(t, AskKindFolder, got.Kind)
}
