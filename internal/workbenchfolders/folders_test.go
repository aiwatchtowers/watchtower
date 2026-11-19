package workbenchfolders

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func openDB(t *testing.T, path string) *db.DB {
	t.Helper()
	d, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func testDB(t *testing.T) *db.DB {
	t.Helper()
	return openDB(t, filepath.Join(t.TempDir(), "wt.db"))
}

// dir makes a directory under a fresh temp root and returns its resolved path.
func dir(t *testing.T, parts ...string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	p := filepath.Join(append([]string{root}, parts...)...)
	require.NoError(t, os.MkdirAll(p, 0o755))
	return p
}

func bench(t *testing.T, d *db.DB, name, folder string) int64 {
	t.Helper()
	id, err := d.CreateWorkbench(name, folder)
	require.NoError(t, err)
	return id
}

// refusal asserts err is a code refusal and returns a copy of it (a value,
// not an error).
func refusal(t *testing.T, err error, code string) Refusal {
	t.Helper()
	var r *Refusal
	require.True(t, errors.As(err, &r), "want a %s refusal, got %v", code, err)
	require.Equal(t, code, r.Code, r.Error())
	assert.True(t, strings.HasPrefix(err.Error(), code+": "), "D42: the message starts with the code: %q", err.Error())
	return *r
}

func folderCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM workbench_folders`).Scan(&n))
	return n
}

// seedSession inserts an agent session row in folder f (a start would).
func seedSession(t *testing.T, d *db.DB, f db.WorkbenchFolder) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, workbench_folder_id)
		VALUES (?, 'claude', 'work', ?, 'sid', ?)`, f.WorkbenchID, f.FolderPath, f.ID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// PROJ-24: a folder belongs to at most one workbench.
func TestProj24_AFolderBelongsToOneWorkbench(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub := dir(t, "hub")
	bench(t, d, "beta", hub)
	before := folderCount(t, d)

	_, err := Add(context.Background(), d, a, hub, AddedByOwner, nil)
	r := refusal(t, err, CodeOtherBench)
	require.NotNil(t, r.OtherBench)
	assert.Equal(t, "beta", r.OtherBench.Name)
	assert.Equal(t, before, folderCount(t, d), "nothing written")
}

// PROJ-24 (spec §7 row 3): two adds of one path to two benches race; the
// write lock and the live-path index let exactly one win.
func TestProj24_ConcurrentAddsOneWins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wt.db")
	d1 := openDB(t, path)
	d2 := openDB(t, path)
	a := bench(t, d1, "acme", dir(t, "app"))
	b := bench(t, d1, "beta", dir(t, "web"))
	shared := dir(t, "shared")

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i, c := range []struct {
		d  *db.DB
		wb int64
	}{{d1, a}, {d2, b}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = Add(context.Background(), c.d, c.wb, shared, AddedByOwner, nil)
		}()
	}
	wg.Wait()

	wins := 0
	for _, err := range errs {
		if err == nil {
			wins++
			continue
		}
		var r *Refusal
		require.True(t, errors.As(err, &r), "the loser gets a refusal, not %v", err)
		assert.Contains(t, []string{CodeAlreadyHere, CodeOtherBench}, r.Code)
	}
	assert.Equal(t, 1, wins, "exactly one add wins: %v", errs)
	var n int
	require.NoError(t, d1.QueryRow(`SELECT COUNT(*) FROM workbench_folders WHERE folder_path = ? AND removed_at IS NULL`, shared).Scan(&n))
	assert.Equal(t, 1, n)
}

// Spec §7 row 1: the path vanished between the panel and the add.
func TestAddOfAMissingPathWritesNothing(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	before := folderCount(t, d)
	_, err := Add(context.Background(), d, a, filepath.Join(t.TempDir(), "gone"), AddedByOwner, nil)
	refusal(t, err, CodeNotFound)
	assert.Equal(t, before, folderCount(t, d))
}

func TestAddRefusesNested(t *testing.T) {
	d := testDB(t)
	root := dir(t, "code")
	app := filepath.Join(root, "app")
	require.NoError(t, os.MkdirAll(filepath.Join(app, "pkg"), 0o755))
	a := bench(t, d, "acme", app)
	other := bench(t, d, "beta", dir(t, "web"))

	_, err := Add(context.Background(), d, other, filepath.Join(app, "pkg"), AddedByOwner, nil)
	r := refusal(t, err, CodeNested)
	assert.Contains(t, r.Detail, "inside app", "names the folder it is inside")
	require.NotNil(t, r.Folder)
	_, err = Add(context.Background(), d, a, root, AddedByOwner, nil)
	r = refusal(t, err, CodeNested)
	assert.Contains(t, r.Detail, "contains app")

	// A pair nested before the rule (seeded directly) still opens and lists.
	inner := filepath.Join(root, "app", "pkg")
	_, err = d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name) VALUES (?, ?, 5, 'owner', 'pkg')`, other, inner)
	require.NoError(t, err)
	got, err := d.WorkbenchFolders(context.Background(), other, false)
	require.NoError(t, err)
	assert.Len(t, got, 2, "grandfathered: the nested folder still lists")
	f, err := Resolve(context.Background(), d, other, "pkg")
	require.NoError(t, err)
	assert.Equal(t, inner, f.FolderPath)
}

// Review Focus 2: every spelling of one folder is that folder.
func TestAddTreatsSpellingsAsOneFolder(t *testing.T) {
	d := testDB(t)
	app := dir(t, "App")
	a := bench(t, d, "acme", app)
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(app, link))

	spellings := []string{app + "/", link} // trailing slash, a symlink to it
	if lower := filepath.Join(filepath.Dir(app), "app"); isDir(lower) {
		spellings = append(spellings, lower) // case (a case-insensitive volume, as APFS by default)
	}
	for _, spelling := range spellings {
		_, err := Add(context.Background(), d, a, spelling, AddedByOwner, nil)
		r := refusal(t, err, CodeAlreadyHere)
		require.NotNil(t, r.Folder, spelling)
		assert.Equal(t, app, r.Folder.FolderPath, spelling)
	}
	assert.Equal(t, 1, folderCount(t, d))
}

func TestAddNamesAClashingFolderAfterItsParent(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "code", "app"))
	f, err := Add(context.Background(), d, a, dir(t, "work", "app"), AddedByOwner, nil)
	require.NoError(t, err)
	assert.Equal(t, "work-app", f.Name)
	assert.Equal(t, 1, f.Position)
	assert.Equal(t, AddedByOwner, f.AddedBy)

	got, err := Resolve(context.Background(), d, a, "work-app")
	require.NoError(t, err)
	assert.Equal(t, f.ID, got.ID)
	home, err := Resolve(context.Background(), d, a, "APP")
	require.NoError(t, err)
	assert.NotEqual(t, f.ID, home.ID, "app is the home folder, never ambiguous")
	assert.Equal(t, "app", home.Name)
}

func TestAddRecordsAgentSuggestion(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	f, err := Add(context.Background(), d, a, dir(t, "hub"), AddedByAgentSuggestion, nil)
	require.NoError(t, err)
	assert.Equal(t, AddedByAgentSuggestion, f.AddedBy)
	_, err = Add(context.Background(), d, a, dir(t, "site"), "someone", nil)
	assert.Error(t, err)
}

func TestAddBackOnTheSameBenchClearsRemovedAt(t *testing.T) {
	d := testDB(t)
	ctx := context.Background()
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	_, err = Add(ctx, d, a, dir(t, "site"), AddedByOwner, nil)
	require.NoError(t, err)
	removed, err := Remove(ctx, d, hub.ID, nil)
	require.NoError(t, err)
	require.True(t, removed.RemovedAt.Valid)

	back, err := Add(ctx, d, a, hub.FolderPath, AddedByOwner, nil)
	require.NoError(t, err)
	assert.Equal(t, hub.ID, back.ID, "the row is reused")
	assert.False(t, back.RemovedAt.Valid)
	assert.Equal(t, 3, back.Position, "a new last position")
	assert.Equal(t, "hub", back.Name)
}

func TestRemoveRefusedWhileSessionsRun(t *testing.T) {
	ctx := context.Background()
	for _, n := range []int{1, 2} {
		d := testDB(t)
		a := bench(t, d, "acme", dir(t, "app"))
		hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
		require.NoError(t, err)
		for range n {
			seedSession(t, d, hub)
		}
		_, err = Remove(ctx, d, hub.ID, nil)
		r := refusal(t, err, CodeSessionsRunning)
		assert.Equal(t, strconv.Itoa(n), r.Detail)
		want := map[int]string{1: "sessions_running: 1 session is running in hub. Finish it first.",
			2: "sessions_running: 2 sessions are running in hub. Finish them first."}[n]
		assert.Equal(t, want, r.Error(), "spec §6.3's sentence")
		assert.Equal(t, "hub", r.Folder.Name)
		f, err := d.WorkbenchFolderByID(ctx, hub.ID)
		require.NoError(t, err)
		assert.False(t, f.RemovedAt.Valid, "nothing written")
	}
}

// The host's answer is advisory: a stale row the host no longer runs (it
// reported a state before the check) does not block; a host run does.
func TestRemoveTrustsTheHostForRowsItAnswered(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	stale := seedSession(t, d, hub)
	_, err = d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-11-01T00:00:00.000Z',
		last_active_at = '2026-11-01T00:00:00Z' WHERE id = ?`, stale)
	require.NoError(t, err)

	_, err = Remove(ctx, d, hub.ID, func(context.Context, int64) (int, error) { return 2, nil })
	assert.Equal(t, "2", refusal(t, err, CodeSessionsRunning).Detail)

	_, err = Remove(ctx, d, hub.ID, func(context.Context, int64) (int, error) { return 0, errors.New("host down") })
	refusal(t, err, CodeSessionsRunning) // no answer: every live-looking row counts

	f, err := Remove(ctx, d, hub.ID, func(context.Context, int64) (int, error) { return 0, nil })
	require.NoError(t, err)
	assert.True(t, f.RemovedAt.Valid)
}

func TestRemoveRefusesTheLastFolder(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	home, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)
	_, err = Remove(ctx, d, home.ID, nil)
	assert.Equal(t, "A workbench needs at least one folder.", refusal(t, err, CodeLastFolder).Detail)
}

// Review Focus 3: the home folder leaves; the next live folder by position
// becomes projects.folder_path in the same transaction.
func TestRemoveHomeMovesFolderPath(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	app := dir(t, "app")
	a := bench(t, d, "acme", app)
	site, err := Add(ctx, d, a, dir(t, "site"), AddedByOwner, nil)
	require.NoError(t, err)
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	_, err = Remove(ctx, d, site.ID, nil)
	require.NoError(t, err)
	home, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)

	_, err = Remove(ctx, d, home.ID, nil)
	require.NoError(t, err)
	wb, err := d.GetWorkbench(a)
	require.NoError(t, err)
	assert.Equal(t, hub.FolderPath, wb.FolderPath, "the next live folder by position is home")
	newHome, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)
	assert.Equal(t, hub.ID, newHome.ID)
	_, err = d.WorkbenchByFolder(app)
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound, "the removed folder is no bench's")
}

// Spec §7 row 4: remove and a start in the same folder; the first commit
// wins. A start whose row committed first is seen by remove's in-tx recount
// (even after the host answered without it); a start after the remove
// finds the folder removed. Task 3's start re-checks inside its insert;
// until then the row is seeded and the start's lookup is Resolve.
func TestRemoveVsStartRace(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)

	// The start commits its row while remove waits on the host's answer.
	live := func(context.Context, int64) (int, error) {
		seedSession(t, d, hub)
		return 0, nil
	}
	_, err = Remove(ctx, d, hub.ID, live)
	assert.Equal(t, "1", refusal(t, err, CodeSessionsRunning).Detail)

	_, err = d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-11-18T00:00:00.000Z'`)
	require.NoError(t, err)
	_, err = Remove(ctx, d, hub.ID, nil)
	require.NoError(t, err)
	_, err = Resolve(ctx, d, a, "hub")
	assert.Error(t, err, "a removed folder's name no longer resolves")
	_, err = Resolve(ctx, d, a, hub.FolderPath)
	refusal(t, err, CodeFolderRemoved)
	_, err = Remove(ctx, d, hub.ID, nil)
	refusal(t, err, CodeFolderRemoved)
}

func TestLocateKeepsTheNameAndMovesHome(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	home, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)

	moved := dir(t, "moved", "app2")
	// Spec §6.3: Locate is for a missing folder; one still at its path keeps
	// its install there, so it is removed from the bench instead.
	_, err = Locate(ctx, d, home.ID, moved, nil)
	r := refusal(t, err, CodeFolderPresent)
	assert.Equal(t, "folder_present: app is still at "+home.FolderPath+". Remove it from the bench instead.", r.Error())

	require.NoError(t, os.RemoveAll(home.FolderPath))
	_, err = Locate(ctx, d, home.ID, hub.FolderPath, nil)
	refusal(t, err, CodeAlreadyHere)
	_, err = Locate(ctx, d, home.ID, filepath.Join(t.TempDir(), "gone"), nil)
	refusal(t, err, CodeNotFound)

	f, err := Locate(ctx, d, home.ID, moved, nil)
	require.NoError(t, err)
	assert.Equal(t, moved, f.FolderPath)
	assert.Equal(t, "app", f.Name, "Locate keeps the name")
	wb, err := d.GetWorkbench(a)
	require.NoError(t, err)
	assert.Equal(t, moved, wb.FolderPath, "the home folder follows")
}

// One `~` expansion for every path: Add stores the expanded form, the
// protected-dir check runs on exactly that form, Resolve finds it by the `~`
// spelling, and Locate's new path gets the same check.
func TestTildePathsAreExpandedOnceAndChecked(t *testing.T) {
	ctx := context.Background()
	home := dir(t, "home")
	t.Setenv("HOME", home)
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	require.NoError(t, os.MkdirAll(filepath.Join(home, "code", "hub"), 0o755))
	protectedDir := filepath.Join(home, "Library", "Application Support", "Watchtower")
	require.NoError(t, os.MkdirAll(filepath.Join(protectedDir, "recordings"), 0o755))
	protected := []string{protectedDir}

	hub, err := Add(ctx, d, a, "~/code/hub", AddedByOwner, protected)
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(home, "code", "hub"), hub.FolderPath, "stored expanded")
	got, err := Resolve(ctx, d, a, "~/code/hub")
	require.NoError(t, err)
	assert.Equal(t, hub.ID, got.ID)

	before := folderCount(t, d)
	_, err = Add(ctx, d, a, "~/Library/Application Support/Watchtower/recordings", AddedByOwner, protected)
	assert.ErrorIs(t, err, db.ErrWorkbenchFolderNotAllowed)
	assert.Equal(t, before, folderCount(t, d))

	require.NoError(t, os.RemoveAll(hub.FolderPath))
	_, err = Locate(ctx, d, hub.ID, "~/Library/Application Support/Watchtower/recordings", protected)
	assert.ErrorIs(t, err, db.ErrWorkbenchFolderNotAllowed)
}

func TestResolveByEveryRef(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	app := dir(t, "app")
	a := bench(t, d, "acme", app)
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	other := bench(t, d, "beta", dir(t, "web"))

	for ref, want := range map[string]string{"": "app", "hub": "hub", "HUB": "hub", hub.FolderPath: "hub", app + "/": "app"} {
		f, err := Resolve(ctx, d, a, ref)
		require.NoError(t, err, ref)
		assert.Equal(t, want, f.Name, ref)
	}
	f, err := Resolve(ctx, d, a, itoa(hub.ID))
	require.NoError(t, err)
	assert.Equal(t, hub.ID, f.ID)
	otherHome, err := d.HomeFolder(ctx, other)
	require.NoError(t, err)
	_, err = Resolve(ctx, d, a, itoa(otherHome.ID))
	refusal(t, err, CodeNotFound)
	_, err = Resolve(ctx, d, a, "nope")
	refusal(t, err, CodeNotFound)

	_, err = Remove(ctx, d, hub.ID, nil)
	require.NoError(t, err)
	_, err = Resolve(ctx, d, a, itoa(hub.ID))
	removed := refusal(t, err, CodeFolderRemoved)
	assert.Equal(t, "folder_removed: hub was removed from the bench.", removed.Error())
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// Removing the home folder pins the rows naming it by NULL to it before the
// home moves: a target there keeps the removed folder (its card reads
// "· folder removed", drift folder_removed), not the next home.
func TestRemoveHomePinsNullFolderRows(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	home, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)
	target := insertTarget(t, d, a, "ship", "todo", 0, 0)
	res, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, doc_path) VALUES (?, 'review', 'Review the spec', 'docs/spec.md')`, a)
	require.NoError(t, err)
	ask, err := res.LastInsertId()
	require.NoError(t, err)
	sess := seedSession(t, d, *home)
	_, err = d.Exec(`UPDATE terminal_sessions SET workbench_folder_id = NULL, finished_at = '2026-11-18T00:00:00.000Z' WHERE id = ?`, sess)
	require.NoError(t, err)

	_, err = Remove(ctx, d, home.ID, nil)
	require.NoError(t, err)
	newHome, err := d.HomeFolder(ctx, a)
	require.NoError(t, err)
	require.Equal(t, hub.ID, newHome.ID)
	for _, q := range []struct {
		query string
		id    int64
	}{
		{`SELECT workbench_folder_id FROM targets WHERE id = ?`, target},
		{`SELECT doc_folder_id FROM owner_asks WHERE id = ?`, ask},
		{`SELECT workbench_folder_id FROM terminal_sessions WHERE id = ?`, sess},
	} {
		var got sql.NullInt64
		require.NoError(t, d.QueryRow(q.query, q.id).Scan(&got))
		assert.Equal(t, sql.NullInt64{Int64: home.ID, Valid: true}, got, q.query)
	}
}

// A resume keeps its row id and may keep finished_at until its first state
// report; remove's recount still sees one between the snapshot and the
// commit: every resume touches last_active_at.
func TestRemoveRaceRecheckedForAResume(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "app"))
	hub, err := Add(ctx, d, a, dir(t, "hub"), AddedByOwner, nil)
	require.NoError(t, err)
	sess := seedSession(t, d, hub)
	_, err = d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-01-01T00:00:00.000Z',
		finished_at = '2026-01-01T00:00:00.000Z', last_active_at = '2026-01-01T00:00:00Z' WHERE id = ?`, sess)
	require.NoError(t, err)
	resume := func(context.Context, int64) (int, error) {
		_, err := d.Exec(`UPDATE terminal_sessions SET last_active_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, sess)
		require.NoError(t, err)
		return 0, nil
	}
	_, err = Remove(ctx, d, hub.ID, resume)
	assert.Equal(t, "1", refusal(t, err, CodeSessionsRunning).Detail)

	// The same row, not resumed: the host's answer stands and the remove runs.
	_, err = d.Exec(`UPDATE terminal_sessions SET last_active_at = '2026-01-01T00:00:00Z' WHERE id = ?`, sess)
	require.NoError(t, err)
	_, err = Remove(ctx, d, hub.ID, func(context.Context, int64) (int, error) { return 0, nil })
	require.NoError(t, err)
}
