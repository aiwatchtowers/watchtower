package coach

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A repository or memory proposal is accepted by a workbench session the
// Desktop starts (spec part 3, C6, C10); no test here reads or writes the
// real home.

const memIndex = "# Memory\n- [Alpha](alpha.md) — the alpha note\n- [Beta](beta.md) — the beta note\n"

// coachSession adds a workbench session row to wb.
func coachSession(t *testing.T, d dbs, wb int64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'Session', '/tmp/acme', 'uuid')`, wb)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func sessionBranch(t *testing.T, d dbs, sess int64, branch string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
		VALUES (?, '/tmp/acme-wt', ?, '2026-10-01T09:00:00.000Z')`, sess, branch)
	require.NoError(t, err)
}

// sessionWorkbench is a workbench over a fresh folder.
func sessionWorkbench(t *testing.T, d dbs) (int64, string) {
	t.Helper()
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	w, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	return wb, w.FolderPath
}

// memoryProposal files an open memory proposal of wb whose index (under home)
// holds memIndex.
func memoryProposal(t *testing.T, d dbs, home string, wb int64, folder string) (int64, string) {
	t.Helper()
	path := MemoryIndexPath(home, folder)
	writeHomeFile(t, path, memIndex)
	id, err := d.InsertContextCoachProposal(db.CoachProposal{Fingerprint: "mem|" + folder, Kind: "restructure",
		Destination: DestMemoryIndex, WorkbenchID: wb, SourceKey: "memory", Title: "Archive stale memory lines",
		Why: "The index is 9.0 KB.", Metric: "start_tokens", BeforeText: memIndex,
		Evidence: []db.CoachEvidence{{Kind: "source", Ref: "MEMORY.md · 9.0 KB"}}}, t0)
	require.NoError(t, err)
	require.NotZero(t, id)
	return id, path
}

// repoSessionProposal files an open CLAUDE.md restructure of wb.
func repoSessionProposal(t *testing.T, d dbs, wb int64, fp string) int64 {
	t.Helper()
	id, err := d.InsertContextCoachProposal(db.CoachProposal{Fingerprint: fp, Kind: "restructure",
		Destination: DestRepoClaudeMD, WorkbenchID: wb, Title: "Slim CLAUDE.md", Why: "It is 24 KB.",
		Metric: "start_tokens", Evidence: []db.CoachEvidence{{Kind: "section", Ref: "## Build · 9.1 KB"}}}, t0)
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

func TestAccept_SessionDestinationRefusedWithoutSession(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	wb, folder := sessionWorkbench(t, d)
	mem, path := memoryProposal(t, d, home, wb, folder)
	repo := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, home)

	for _, id := range []int64{mem, repo} {
		err := a.acceptErr(id, "")
		require.ErrorIs(t, err, ErrRefused)
		assert.Contains(t, err.Error(), "Accept it in Watchtower — it starts a session")
		assert.Equal(t, "open", proposal(t, d, id).Status)
	}
	assert.Equal(t, memIndex, string(readHomeFile(t, path)))
	_, err := os.Stat(filepath.Join(folder, "CLAUDE.md"))
	assert.ErrorIs(t, err, os.ErrNotExist, "nothing written into the folder")
}

func TestAcceptWithSession_Marks(t *testing.T) {
	d := openDBs(t)
	wb, folder := sessionWorkbench(t, d)
	sess := coachSession(t, d, wb)
	sessionBranch(t, d, sess, "wt/slim-claude-md")
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))

	require.NoError(t, a.AcceptWithSession(id, sess))
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.True(t, p.ViaSession)
	require.NotNil(t, p.SessionID)
	assert.Equal(t, sess, *p.SessionID)
	assert.Equal(t, "wt/slim-claude-md", p.SessionBranch, "copied in the same compare-and-set")
	assert.True(t, p.DecidedAt.Equal(applyNow))
	_, err := os.Stat(filepath.Join(folder, "CLAUDE.md"))
	assert.ErrorIs(t, err, os.ErrNotExist, "Watchtower writes nothing: the session does")

	// A session without a worktree branch yet leaves session_branch empty.
	id2 := repoSessionProposal(t, d, wb, "repo2")
	require.NoError(t, a.AcceptWithSession(id2, coachSession(t, d, wb)))
	assert.Empty(t, proposal(t, d, id2).SessionBranch)
}

func TestAcceptWithSession_WrongWorkbench(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	other, _ := sessionWorkbench(t, d)
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))

	err := a.AcceptWithSession(id, coachSession(t, d, other))
	require.ErrorIs(t, err, ErrRefused)
	err = a.AcceptWithSession(id, 9999)
	require.ErrorIs(t, err, ErrRefused, "a missing session")
	p := proposal(t, d, id)
	assert.Equal(t, "open", p.Status)
	assert.Nil(t, p.SessionID)
}

func TestAcceptWithSession_Twice(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	sess := coachSession(t, d, wb)
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))

	require.NoError(t, a.AcceptWithSession(id, sess))
	err := a.AcceptWithSession(id, coachSession(t, d, wb))
	require.ErrorIs(t, err, db.ErrCoachStateChanged)
	assert.Equal(t, sess, *proposal(t, d, id).SessionID, "the first session stays")
}

func TestAcceptWithSession_NotASessionDestination(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")
	err := ctxApplier(t, d, ctxHome(t)).AcceptWithSession(id, coachSession(t, d, wb))
	require.ErrorIs(t, err, ErrRefused)
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

// The index is read again at Accept: a line the owner (or auto-memory) added
// after the proposal is in the copy Rollback restores.
func TestAcceptWithSession_MemoryRefreshesBefore(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	wb, folder := sessionWorkbench(t, d)
	id, path := memoryProposal(t, d, home, wb, folder)
	now := memIndex + "- [Gamma](gamma.md) — added later\n"
	writeHomeFile(t, path, now)

	require.NoError(t, ctxApplier(t, d, home).AcceptWithSession(id, coachSession(t, d, wb)))
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.Equal(t, now, p.BeforeText)
	assert.Equal(t, now, string(readHomeFile(t, path)), "Accept writes nothing")
}

// acceptedMemory is a memory proposal accepted through a session whose
// session wrote after (after_text seeded the way the daemon records it).
func acceptedMemory(t *testing.T, d dbs, home, after string) (int64, string, *Applier) {
	t.Helper()
	wb, folder := sessionWorkbench(t, d)
	id, path := memoryProposal(t, d, home, wb, folder)
	a := ctxApplier(t, d, home)
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))
	if after != "" {
		_, err := d.Exec(`UPDATE coach_proposals SET after_text = ? WHERE id = ?`, after, id)
		require.NoError(t, err)
		writeHomeFile(t, path, after)
	}
	return id, path, a
}

const memSlim = "# Memory\n- [Alpha](alpha.md) — the alpha note\n- [Archive](archive.md) — older notes\n"

func TestRollback_MemoryRestoresIndex(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := acceptedMemory(t, d, home, memSlim)
	archive := filepath.Join(filepath.Dir(path), "archive.md")
	writeHomeFile(t, archive, "- [Beta](beta.md) — the beta note\n")

	diff, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Empty(t, diff)
	assert.Equal(t, memIndex, string(readHomeFile(t, path)))
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
	_, err = os.Stat(archive)
	require.NoError(t, err, "the archive file the agent made is left in place")
	entries, err := os.ReadDir(filepath.Dir(path))
	require.NoError(t, err)
	assert.Len(t, entries, 2, "no backup or temp file is left in the memory folder")
}

func TestRollback_MemoryChangedSinceRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := acceptedMemory(t, d, home, memSlim)
	changed := memSlim + "- [Delta](delta.md) — written by auto-memory\n"
	writeHomeFile(t, path, changed)

	for _, force := range []bool{false, true} {
		_, err := a.Rollback(id, force)
		require.ErrorIs(t, err, ErrRefused)
		assert.Contains(t, err.Error(), "the memory index changed since — roll it back by hand")
	}
	assert.Equal(t, changed, string(readHomeFile(t, path)))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

func TestRollback_MemoryNeverWrittenRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := acceptedMemory(t, d, home, "")

	_, err := a.Rollback(id, true)
	require.ErrorIs(t, err, ErrRefused)
	assert.Contains(t, err.Error(), "nothing to roll back")
	assert.Equal(t, memIndex, string(readHomeFile(t, path)))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// A session that ended without a change is recorded as after_text =
// before_text: nothing to roll back, even with force.
func TestRollback_MemoryEndedWithoutChangeRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := acceptedMemory(t, d, home, memIndex)

	_, err := a.Rollback(id, true)
	require.ErrorIs(t, err, ErrRefused)
	assert.Contains(t, err.Error(), "nothing to roll back")
	assert.Equal(t, memIndex, string(readHomeFile(t, path)))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

// A repository change accepted through a session is rolled back by a revert
// session, never by Watchtower writing the file.
func TestRollback_RepoViaSessionRefused(t *testing.T) {
	d := openDBs(t)
	wb, folder := sessionWorkbench(t, d)
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))

	_, err := a.Rollback(id, true)
	require.ErrorIs(t, err, ErrRefused)
	assert.Contains(t, err.Error(), "Roll it back with a session: Watchtower opens one")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
	_, err = os.Stat(filepath.Join(folder, "CLAUDE.md"))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestDismiss_AcceptedWithoutMeasure(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))
	require.ErrorIs(t, a.Dismiss(id), db.ErrCoachStateChanged, "an open row is declined, not dismissed")
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))

	require.NoError(t, a.Dismiss(id))
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.Equal(t, "too_little_data", p.Verdict)
	assert.Nil(t, p.VerdictValue)
}

func TestDismiss_MeasuredRefused(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))
	ok, err := d.SetCoachMeasureFrom(id, applyNow)
	require.NoError(t, err)
	require.True(t, ok)

	require.ErrorIs(t, a.Dismiss(id), db.ErrCoachStateChanged)
	assert.Empty(t, proposal(t, d, id).Verdict)
}

func TestRestart_ReplacesSession(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	first := coachSession(t, d, wb)
	sessionBranch(t, d, first, "wt/first")
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))
	require.NoError(t, a.AcceptWithSession(id, first))

	second := coachSession(t, d, wb)
	sessionBranch(t, d, second, "wt/second")
	later := applyNow.Add(48 * time.Hour)
	a.Now = func() time.Time { return later }
	require.NoError(t, a.Restart(id, second))
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	require.NotNil(t, p.SessionID)
	assert.Equal(t, second, *p.SessionID)
	assert.Equal(t, "wt/second", p.SessionBranch)
	assert.True(t, p.DecidedAt.Equal(later))

	other, _ := sessionWorkbench(t, d)
	require.ErrorIs(t, a.Restart(id, coachSession(t, d, other)), ErrRefused, "a session of another workbench")
	assert.Equal(t, second, *proposal(t, d, id).SessionID)
}

func TestRestart_RefusedWithPR(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	first := coachSession(t, d, wb)
	sessionBranch(t, d, first, "wt/first")
	id := repoSessionProposal(t, d, wb, "repo1")
	a := ctxApplier(t, d, ctxHome(t))
	require.NoError(t, a.AcceptWithSession(id, first))
	require.NoError(t, d.UpsertPRState(db.PRState{WorkbenchID: wb, Ref: "branch:wt/first", State: "open",
		PRNumber: sql.NullInt64{Int64: 41, Valid: true}, CheckedAt: "2026-10-01T12:00:00Z"}))

	err := a.Restart(id, coachSession(t, d, wb))
	require.ErrorIs(t, err, db.ErrCoachSessionHasPR)
	assert.Equal(t, first, *proposal(t, d, id).SessionID)
}

// The 30-day wait for a merge restarts with the new session: a restart on
// day 28 is not too_little_data on day 31; a row left alone is.
func TestRestart_ResetsWindow(t *testing.T) {
	d := openDBs(t)
	wb, _ := sessionWorkbench(t, d)
	a := ctxApplier(t, d, ctxHome(t))
	restarted := repoSessionProposal(t, d, wb, "repo1")
	require.NoError(t, a.AcceptWithSession(restarted, coachSession(t, d, wb)))
	alone := repoSessionProposal(t, d, wb, "repo2")
	require.NoError(t, a.AcceptWithSession(alone, coachSession(t, d, wb)))

	day := 24 * time.Hour
	a.Now = func() time.Time { return applyNow.Add(28 * day) }
	require.NoError(t, a.Restart(restarted, coachSession(t, d, wb)))

	_, _, err := judge(d.DB, d.al, ctxHome(t), applyNow.Add(31*day))
	require.NoError(t, err)
	assert.Empty(t, proposal(t, d, restarted).Verdict)
	assert.Equal(t, "too_little_data", proposal(t, d, alone).Verdict)
}

func TestRestart_MemoryRefreshesBefore(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	wb, folder := sessionWorkbench(t, d)
	id, path := memoryProposal(t, d, home, wb, folder)
	a := ctxApplier(t, d, home)
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))

	ok, err := d.SetCoachMemoryUnchanged(id, proposal(t, d, id).SessionID) // the daemon decided: ended without a change
	require.NoError(t, err)
	require.True(t, ok)

	between := memIndex + "- [Gamma](gamma.md) — auto-memory, between the sessions\n"
	writeHomeFile(t, path, between)
	require.NoError(t, a.Restart(id, coachSession(t, d, wb)))
	assert.Equal(t, between, proposal(t, d, id).BeforeText)
}

// A memory row whose session ended but that the daemon has not decided yet
// (after_text empty) is neither restarted nor dismissed: a Restart would
// read the cleaned index into before_text and a Dismiss would close a write
// still to be measured — both lose the copy Undo restores.
func TestRestart_MemoryUndecidedRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	wb, folder := sessionWorkbench(t, d)
	id, path := memoryProposal(t, d, home, wb, folder)
	a := ctxApplier(t, d, home)
	first := coachSession(t, d, wb)
	require.NoError(t, a.AcceptWithSession(id, first))
	before := proposal(t, d, id).BeforeText
	writeHomeFile(t, path, "- [Alpha](alpha.md) — cleaned\n")

	require.ErrorIs(t, a.Restart(id, coachSession(t, d, wb)), db.ErrCoachStateChanged)
	p := proposal(t, d, id)
	assert.Equal(t, before, p.BeforeText, "the original index is kept for Undo")
	assert.Equal(t, first, *p.SessionID)
}

func TestDismiss_MemoryUndecidedRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	wb, folder := sessionWorkbench(t, d)
	id, _ := memoryProposal(t, d, home, wb, folder)
	a := ctxApplier(t, d, home)
	require.NoError(t, a.AcceptWithSession(id, coachSession(t, d, wb)))

	require.ErrorIs(t, a.Dismiss(id), db.ErrCoachStateChanged)
	assert.Empty(t, proposal(t, d, id).Verdict)
	ok, err := d.SetCoachMemoryUnchanged(id, proposal(t, d, id).SessionID)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, a.Dismiss(id), "decided unchanged: Dismiss closes it")
	assert.Equal(t, "too_little_data", proposal(t, d, id).Verdict)
}

// revertedPlugin is an accepted plugin proposal whose key someone turned back
// on (the daemon's reverted_outside verdict).
func revertedPlugin(t *testing.T, d dbs, home string) (int64, string, *Applier) {
	t.Helper()
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")
	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	writeHomeFile(t, path, ctxSettings) // Claude Code wrote its old copy back
	v := 1.0
	require.NoError(t, d.SetCoachVerdict(id, "reverted_outside", &v, applyNow))
	return id, path, a
}

func TestReapply_TurnsOffAgain(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := revertedPlugin(t, d, home)
	later := applyNow.Add(72 * time.Hour)
	a.Now = func() time.Time { return later }

	require.NoError(t, a.Reapply(id))
	got := topKeys(t, readHomeFile(t, path))
	assert.Equal(t, `{"alpha@example-market":false,"beta@example-market":true}`, got["enabledPlugins"])
	assert.Equal(t, `"opus"`, got["model"], "other keys kept")
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.Empty(t, p.Verdict)
	assert.True(t, p.MeasureFrom.Equal(later))

	require.ErrorIs(t, a.Reapply(id), db.ErrCoachStateChanged, "no longer reverted_outside")
}

func TestReapply_StaleKeyRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	id, path, a := revertedPlugin(t, d, home)
	other := `{"enabledPlugins":{"beta@example-market":true},"model":"opus"}`
	writeHomeFile(t, path, other) // the plugin key is gone: neither before nor after

	require.ErrorIs(t, a.Reapply(id), ErrStale)
	assert.Equal(t, other, string(readHomeFile(t, path)))
	p := proposal(t, d, id)
	assert.Equal(t, "reverted_outside", p.Verdict)
	assert.True(t, p.MeasureFrom.IsZero())
}

// "Back on" is defined per destination: a plugin at true only (a key gone
// from enabledPlugins — the plugin uninstalled — is not back on), the
// connectors switch at anything but "false"/"0" (absent = on by default),
// a server whenever present.
func TestSettingsBackOn_PerDestination(t *testing.T) {
	for _, tc := range []struct {
		dest, text string
		on         bool
	}{
		{DestPluginOff, "true", true}, {DestPluginOff, "false", false}, {DestPluginOff, "", false},
		{DestConnectorsOff, "", true}, {DestConnectorsOff, `"true"`, true}, {DestConnectorsOff, `"1"`, true},
		{DestConnectorsOff, `"false"`, false}, {DestConnectorsOff, `"0"`, false},
		{DestMCPServerOff, "present", true}, {DestMCPServerOff, "", false},
	} {
		assert.Equal(t, tc.on, settingsBackOn(tc.dest, tc.text), "%s %q", tc.dest, tc.text)
	}
}

// A server re-added outside Watchtower, with a different entry, reads back
// on; Turn Off Again removes it and saves the entry as it is now, so Undo
// puts back the latest one.
func TestReapply_MCPServerSavesTheNewEntry(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeJSONPath(home)
	writeHomeFile(t, path, ctxClaudeJSON)
	id := proposeCtx(t, d, DestMCPServerOff, "alpha-docs", "present", "")
	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))

	readded := `{"mcpServers":{"alpha-docs":{"type":"http","url":"https://mcp.example.com/v2"},` +
		`"beta-files":{"command":"beta-mcp","args":["--stdio"]}},"numStartups":6}`
	writeHomeFile(t, path, readded)
	back, err := a.SettingsReverted(proposal(t, d, id))
	require.NoError(t, err)
	require.True(t, back)
	require.NoError(t, d.SetCoachVerdict(id, "reverted_outside", nil, applyNow))

	require.NoError(t, a.Reapply(id))
	assert.NotContains(t, topKeys(t, []byte(topKeys(t, readHomeFile(t, path))["mcpServers"])), "alpha-docs")
	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, topKeys(t, []byte(topKeys(t, []byte(readded))["mcpServers"])),
		topKeys(t, []byte(topKeys(t, readHomeFile(t, path))["mcpServers"])), "the re-added entry is back")
	_, err = os.Stat(filepath.Join(a.WorkspaceDir, "coach-undo", fmt.Sprintf("%d.json", id)))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

// The connectors switch turned back on in another form than before_text
// (absent before, "true" now) reads back on, and Turn Off Again sets it
// from what it reads now.
func TestReapply_ConnectorsFromAnyOnForm(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, `{"env":{"OTHER_FLAG":"1"},"model":"opus"}`)
	id := proposeCtx(t, d, DestConnectorsOff, "connectors", "", `"false"`)
	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))

	writeHomeFile(t, path, `{"env":{"ENABLE_CLAUDEAI_MCP_SERVERS":"true","OTHER_FLAG":"1"},"model":"opus"}`)
	back, err := a.SettingsReverted(proposal(t, d, id))
	require.NoError(t, err)
	require.True(t, back, `"true" is on though before_text was absent`)
	require.NoError(t, d.SetCoachVerdict(id, "reverted_outside", nil, applyNow))

	require.NoError(t, a.Reapply(id))
	assert.Equal(t, `{"ENABLE_CLAUDEAI_MCP_SERVERS":"false","OTHER_FLAG":"1"}`, topKeys(t, readHomeFile(t, path))["env"])
	assert.Empty(t, proposal(t, d, id).Verdict)
}
