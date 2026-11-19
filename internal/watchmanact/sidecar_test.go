package watchmanact

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

func TestWriteSidecar_AtomicAndReadable(t *testing.T) {
	ws := t.TempDir()
	path := SidecarPath(ws)
	assert.Equal(t, filepath.Join(ws, "watchman.armed"), path)
	sessions := []db.ArmedSession{
		{SessionID: 7, WorkbenchID: 1, Folder: "/tmp/acme/wt-7"},
		{SessionID: 9, WorkbenchID: 1, Folder: "/tmp/acme/wt-7"}, // one worktree, two sessions
		{SessionID: 11, WorkbenchID: 2, Folder: "/tmp/acme-docs"},
	}
	require.NoError(t, WriteSidecar(path, sessions, true))
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, "session 7\nworktree /tmp/acme/wt-7\nsession 9\nsession 11\nworktree /tmp/acme-docs\ntargets-armed\n", string(raw))
	got, err := ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{7, 9, 11}, Worktrees: []string{"/tmp/acme/wt-7", "/tmp/acme-docs"}, TargetsArmed: true}, got)

	// A rewrite replaces the whole file; no temp file is left beside it.
	require.NoError(t, WriteSidecar(path, sessions[2:], false))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{11}, Worktrees: []string{"/tmp/acme-docs"}}, got)
	entries, err := os.ReadDir(ws)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, "watchman.armed", entries[0].Name())

	// Nothing armed: an empty file, read as not armed.
	require.NoError(t, WriteSidecar(path, nil, false))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{}, got)
}

func TestReadSidecar_MissingIsNotArmed(t *testing.T) {
	got, err := ReadSidecar(filepath.Join(t.TempDir(), "watchman.armed"))
	require.NoError(t, err)
	assert.Equal(t, Sidecar{}, got)
}

func TestReadSidecar_SkipsUnknownLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchman.armed")
	require.NoError(t, os.WriteFile(path, []byte("session x\nsomething else\nsession 3\nworktree /tmp/acme\n"), 0o600))
	got, err := ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{3}, Worktrees: []string{"/tmp/acme"}}, got)
}

// sidecarSession inserts a live claude session of workbench wb and arms it.
func sidecarSession(t *testing.T, d *db.DB, wb int64, folder string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'acme', ?, ?)`, wb, folder, "sid-"+filepath.Base(folder))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: id, ArmedAt: time.Now(), ArmedBy: "cli"}))
	return id
}

// Two writers: the first holds the lock from its read through its write, so
// a second writer that saw a newer database state cannot be overwritten by
// the first's stale one — the later database state is what stays.
func TestRefreshSidecar_LaterStateWins(t *testing.T) {
	ws := t.TempDir()
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	f1, f2 := t.TempDir(), t.TempDir()
	s1 := sidecarSession(t, d, wb, f1)
	var s2 int64
	calls := 0
	sidecarAfterRead = func() {
		calls++
		if calls > 1 {
			return
		}
		// Writer A has read; the lock is still its own.
		_, ok, err := fsutil.TryLockFile(SidecarPath(ws) + ".lock")
		require.NoError(t, err)
		assert.False(t, ok, "the lock is held between the read and the write")
		// Meanwhile the database moves on (writer B's arm).
		s2 = sidecarSession(t, d, wb, f2)
	}
	t.Cleanup(func() { sidecarAfterRead = nil })

	arming, err := RefreshSidecar(context.Background(), ws, d) // writer A: the stale state
	require.NoError(t, err)
	assert.Len(t, arming, 1)
	_, err = RefreshSidecar(context.Background(), ws, d) // writer B: after A released the lock
	require.NoError(t, err)
	got, err := ReadSidecar(SidecarPath(ws))
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{s1, s2}, Worktrees: []string{f1, f2}}, got)
}

func TestSidecar_CarriesTheOwnersLimits(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchman.armed")
	limits := []db.WatchmanExtraLimit{
		{ID: 4, Kind: "command", Pattern: "terraform apply"},
		{ID: 5, Kind: "tool", Pattern: "create_jira_issue"},
	}
	require.NoError(t, WriteSidecar(path, []db.ArmedSession{{SessionID: 7, Folder: "/tmp/acme"}}, false, limits...))
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, "session 7\nworktree /tmp/acme\nlimit command terraform apply\nlimit tool create_jira_issue\n", string(raw))
	got, err := ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, []db.WatchmanExtraLimit{{Kind: "command", Pattern: "terraform apply"}, {Kind: "tool", Pattern: "create_jira_issue"}}, got.Limits)
	assert.False(t, got.LimitsUnavailable)

	// A limit that cannot be a line is not dropped silently: the marker.
	limits = append(limits, db.WatchmanExtraLimit{ID: 6, Kind: "command", Pattern: "two\nlines"})
	require.NoError(t, WriteSidecar(path, nil, false, limits...))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.True(t, got.LimitsUnavailable)
	assert.Len(t, got.Limits, 2)

	// A file from before the limit lines reads as no owner's limits.
	require.NoError(t, os.WriteFile(path, []byte("session 7\ntargets-armed\n"), 0o600))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{7}, TargetsArmed: true}, got)
}

func TestRefreshSidecar_WritesTheOwnersLimits(t *testing.T) {
	ws := t.TempDir()
	d := db.OpenTestDB(t)
	_, err := d.AddWatchmanExtraLimit("command", "terraform apply")
	require.NoError(t, err)
	_, err = RefreshSidecar(context.Background(), ws, d)
	require.NoError(t, err)
	got, err := ReadSidecar(SidecarPath(ws))
	require.NoError(t, err)
	assert.Equal(t, []db.WatchmanExtraLimit{{Kind: "command", Pattern: "terraform apply"}}, got.Limits)
}

// A limit row the CLI would refuse (a line break) came in some other way:
// the refresh writes the marker, not a silent gap.
func TestRefreshSidecar_UnwritableLimitRowMarksUnavailable(t *testing.T) {
	ws := t.TempDir()
	d := db.OpenTestDB(t)
	_, err := d.Exec(`INSERT INTO watchman_extra_limits (kind, pattern, created_at) VALUES ('command', 'make' || char(10) || 'deploy', '2026-11-18T00:00:00Z')`)
	require.NoError(t, err)
	_, err = RefreshSidecar(context.Background(), ws, d)
	require.NoError(t, err)
	got, err := ReadSidecar(SidecarPath(ws))
	require.NoError(t, err)
	assert.True(t, got.LimitsUnavailable)
	assert.Empty(t, got.Limits)
}

// The owner's limits unreadable after the arming was read: the arming is
// still written, with the marker, and the error is returned.
func TestRefreshSidecar_LimitsReadFailureWritesArmingAndMarker(t *testing.T) {
	ws := t.TempDir()
	d := db.OpenTestDB(t)
	_, err := d.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path, claude_session_id) VALUES (7, 1, 'claude', 'acme', '/tmp/acme/wt', 'sid-7')`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: 7, ArmedAt: time.Now(), ArmedBy: "cli"}))
	_, err = d.Exec(`DROP TABLE watchman_extra_limits`)
	require.NoError(t, err)
	_, err = RefreshSidecar(context.Background(), ws, d)
	require.Error(t, err)
	got, err := ReadSidecar(SidecarPath(ws))
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{7}, Worktrees: []string{"/tmp/acme/wt"}, LimitsUnavailable: true}, got)
}
