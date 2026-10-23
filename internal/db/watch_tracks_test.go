package db

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedSyncRecipe indexes an owner recipe at path with trigger kind and spec.
func seedSyncRecipe(t *testing.T, d *DB, slug, triggerKind, triggerSpec string) int64 {
	t.Helper()
	id, err := d.UpsertAutomationIndex(Automation{
		Slug: slug, Scope: "personal", Path: "/acme/automations/" + slug + ".md", Name: "Acme " + slug,
		TriggerKind: triggerKind, TriggerSpec: triggerSpec,
		RecipeText: "---\nname: x\n---\n", ContentHash: "c-" + slug, ApprovalHash: "a-" + slug,
	})
	require.NoError(t, err)
	return id
}

func setAutomationEnabled(t *testing.T, d *DB, id int64, enabled bool) {
	t.Helper()
	_, err := d.Exec(`UPDATE automations SET enabled = ? WHERE id = ?`, enabled, id)
	require.NoError(t, err)
}

func seedCustomTrack(t *testing.T, d *DB, text string) int {
	t.Helper()
	id, err := d.CreateCustomTrack(Track{AssigneeUserID: "U1", Text: text, Instruction: "watch " + text})
	require.NoError(t, err)
	return int(id)
}

func trackEnabled(t *testing.T, d *DB, id int) bool {
	t.Helper()
	tr, err := d.GetTrackByID(id)
	require.NoError(t, err)
	return tr.Enabled
}

func TestBindWatchTrack_RefusesAutoTrackAndDoubleBinding(t *testing.T) {
	d := openTestDB(t)
	a1 := seedSyncRecipe(t, d, "w1", TriggerKindSync, `{"sync":"tracks"}`)
	a2 := seedSyncRecipe(t, d, "w2", TriggerKindSync, `{"sync":"tracks"}`)
	auto := seedScanTrack(t, d, "auto", "auto track", "", "2026-10-01T00:00:00Z")
	c1 := seedCustomTrack(t, d, "c1")
	c2 := seedCustomTrack(t, d, "c2")

	require.ErrorIs(t, d.BindWatchTrack(auto, a1), ErrNotCustomTrack)
	require.Error(t, d.BindWatchTrack(c1, 9999), "a missing automation is refused")

	require.NoError(t, d.BindWatchTrack(c1, a1))
	require.NoError(t, d.BindWatchTrack(c1, a1), "binding the same pair again is a no-op")
	require.ErrorIs(t, d.BindWatchTrack(c1, a2), ErrWatchAlreadyBound, "the track is bound elsewhere")
	require.ErrorIs(t, d.BindWatchTrack(c2, a1), ErrWatchAlreadyBound, "the recipe is bound elsewhere")

	got, err := d.GetWatchTrack(a1)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, c1, got.ID)
	assert.Equal(t, a1, got.AutomationID)
	assert.False(t, got.Enabled, "the bound track takes the disabled recipe's enabled")

	none, err := d.GetWatchTrack(a2)
	require.NoError(t, err)
	assert.Nil(t, none)
}

func TestEnsureWatchTrack_CreatesOnceAndInheritsEnabled(t *testing.T) {
	d := openTestDB(t)
	on := seedSyncRecipe(t, d, "on", TriggerKindSync, `{"sync":"tracks"}`)
	setAutomationEnabled(t, d, on, true)
	off := seedSyncRecipe(t, d, "off", TriggerKindSync, `{"sync":"tracks"}`)

	id, err := d.EnsureWatchTrack(on, "U1", "Acme launch", "watch the launch")
	require.NoError(t, err)
	again, err := d.EnsureWatchTrack(on, "U1", "other name", "other instruction")
	require.NoError(t, err)
	assert.Equal(t, id, again)

	tr, err := d.GetTrackByID(id)
	require.NoError(t, err)
	assert.Equal(t, "custom", tr.Origin)
	assert.Equal(t, "U1", tr.AssigneeUserID)
	assert.Equal(t, "Acme launch", tr.Text)
	assert.Equal(t, "watch the launch", tr.Instruction)
	assert.Equal(t, on, tr.AutomationID)
	assert.True(t, tr.Enabled)

	offID, err := d.EnsureWatchTrack(off, "U1", "Paused", "x")
	require.NoError(t, err)
	assert.NotEqual(t, id, offID)
	assert.False(t, trackEnabled(t, d, offID))

	_, err = d.EnsureWatchTrack(9999, "U1", "x", "y")
	require.ErrorIs(t, err, ErrAutomationNotFound)
}

func TestWatchTrack_EnabledMirrorsAutomation(t *testing.T) {
	d := openTestDB(t)
	a := seedSyncRecipe(t, d, "w", TriggerKindSync, `{"sync":"tracks"}`)
	setAutomationEnabled(t, d, a, true)
	bound, err := d.EnsureWatchTrack(a, "U1", "bound", "x")
	require.NoError(t, err)
	unbound := seedCustomTrack(t, d, "unbound")
	require.True(t, trackEnabled(t, d, unbound))

	setAutomationEnabled(t, d, a, false)
	assert.False(t, trackEnabled(t, d, bound))
	assert.True(t, trackEnabled(t, d, unbound), "an unbound track is untouched")

	setAutomationEnabled(t, d, a, true)
	assert.True(t, trackEnabled(t, d, bound))
}

func TestWatchTrack_AutomationDeleteUnbindsAndPauses(t *testing.T) {
	d := openTestDB(t)
	a := seedSyncRecipe(t, d, "w", TriggerKindSync, `{"sync":"tracks"}`)
	setAutomationEnabled(t, d, a, true)
	id, err := d.EnsureWatchTrack(a, "U1", "bound", "x")
	require.NoError(t, err)
	other := seedCustomTrack(t, d, "other")

	_, err = d.Exec(`DELETE FROM automations WHERE id = ?`, a)
	require.NoError(t, err)

	tr, err := d.GetTrackByID(id)
	require.NoError(t, err, "the track and its history stay")
	assert.Equal(t, int64(0), tr.AutomationID)
	assert.False(t, tr.Enabled)
	assert.True(t, trackEnabled(t, d, other))
	got, err := d.GetWatchTrack(a)
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestSetWatchInstruction_WritesOnlyOnChange(t *testing.T) {
	d := openTestDB(t)
	id := seedCustomTrack(t, d, "c")
	_, err := d.Exec(`UPDATE tracks SET updated_at = '2026-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)

	require.NoError(t, d.SetWatchInstruction(id, "watch c"))
	tr, err := d.GetTrackByID(id)
	require.NoError(t, err)
	assert.Equal(t, "2026-01-01T00:00:00Z", tr.UpdatedAt, "the same value writes nothing")

	require.NoError(t, d.SetWatchInstruction(id, "new"))
	tr, err = d.GetTrackByID(id)
	require.NoError(t, err)
	assert.Equal(t, "new", tr.Instruction)
	assert.NotEqual(t, "2026-01-01T00:00:00Z", tr.UpdatedAt)

	require.Error(t, d.SetWatchInstruction(9999, "x"))
}

func TestListSlotRecipes_OnlyPersonalSyncOfThatSlot(t *testing.T) {
	d := openTestDB(t)
	first := seedSyncRecipe(t, d, "z-first", TriggerKindSync, `{"sync":"tracks"}`)
	second := seedSyncRecipe(t, d, "a-second", TriggerKindSync, `{"sync":"tracks"}`)
	seedSyncRecipe(t, d, "elsewhere", TriggerKindSync, `{"sync":"ideas"}`)
	seedSyncRecipe(t, d, "cron", "schedule", `{"cron":"0 9 * * *"}`)
	removed := seedSyncRecipe(t, d, "removed", TriggerKindSync, `{"sync":"tracks"}`)
	_, err := d.Exec(`UPDATE automations SET removed_at = '2026-10-01T00:00:00Z' WHERE id = ?`, removed)
	require.NoError(t, err)
	_, err = d.UpsertBuiltinAutomation(Automation{
		BuiltinID: "tracks", Slug: "tracks", Name: "Acme tracks",
		TriggerKind: TriggerKindSync, TriggerSpec: `{"sync":"tracks"}`,
		RecipeText: "---\nname: x\n---\n", ContentHash: "c", ApprovalHash: "a",
	})
	require.NoError(t, err)
	wb := newTestWorkbench(t, d)
	_, err = d.UpsertAutomationIndex(Automation{
		Slug: "wb", Scope: "workbench", ProjectID: wb, Path: "/acme/wb/.watchtower/automations/wb.md",
		TriggerKind: TriggerKindSync, TriggerSpec: `{"sync":"tracks"}`, ContentHash: "c", ApprovalHash: "a",
	})
	require.NoError(t, err)

	got, err := d.ListSlotRecipes("tracks")
	require.NoError(t, err)
	var ids []int64
	for _, a := range got {
		ids = append(ids, a.ID)
	}
	assert.Equal(t, []int64{first, second}, ids, "id order, owner personal sync recipes of the slot only")

	none, err := d.ListSlotRecipes("nowhere")
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestHasScanActivity_MatchesGetScanActivity(t *testing.T) {
	d := openTestDB(t)
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	ts := func(n int) string { return scanTS(base, n) }

	seedScanDigest(t, d, "channel", "digest", ts(10))
	seedScanDigest(t, d, "daily", "rollup only", ts(20))
	seedScanTrack(t, d, "auto", "auto", "", ts(30))
	seedScanTrack(t, d, "auto", "dismissed", ts(40), ts(40))
	seedScanTrack(t, d, "custom", "custom", "", ts(50))
	seedScanInbox(t, d, "inbox", ts(60))

	windows := [][2]int{
		{0, 5}, {0, 10}, {10, 15}, {15, 25}, {25, 30}, {35, 45}, {45, 55}, {55, 60}, {60, 70}, {0, 100}, {70, 100},
	}
	for _, w := range windows {
		t.Run(fmt.Sprintf("%d-%d", w[0], w[1]), func(t *testing.T) {
			since, until := ts(w[0]), ts(w[1])
			act, err := d.GetScanActivity(since, until, 40)
			require.NoError(t, err)
			has, err := d.HasScanActivity(since, until)
			require.NoError(t, err)
			assert.Equal(t, len(act.Digests)+len(act.Tracks)+len(act.Inbox) > 0, has)
		})
	}
}

func TestGetCustomTracksDueForScan_LeavesBoundTracksOut(t *testing.T) {
	d := openTestDB(t)
	a := seedSyncRecipe(t, d, "w", TriggerKindSync, `{"sync":"tracks"}`)
	setAutomationEnabled(t, d, a, true)
	bound, err := d.EnsureWatchTrack(a, "U1", "bound", "x")
	require.NoError(t, err)
	unbound := seedCustomTrack(t, d, "unbound")

	due, err := d.GetCustomTracksDueForScan("2026-10-01", 3)
	require.NoError(t, err)
	require.Len(t, due, 1)
	assert.Equal(t, unbound, due[0].ID)

	list, err := d.ListUnboundCustomTracks()
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, unbound, list[0].ID)
	assert.NotEqual(t, bound, list[0].ID)
}

func TestListUnboundCustomTracks_ActiveUnboundCustomInCreatedOrder(t *testing.T) {
	d := openTestDB(t)
	seedScanTrack(t, d, "auto", "auto", "", "2026-10-01T00:00:00Z")
	first := seedCustomTrack(t, d, "first")
	second := seedCustomTrack(t, d, "second")
	dismissed := seedCustomTrack(t, d, "dismissed")
	_, err := d.Exec(`UPDATE tracks SET created_at = '2026-01-01T00:00:00Z' WHERE id = ?`, second)
	require.NoError(t, err)
	require.NoError(t, d.DismissTrack(dismissed))
	paused := seedCustomTrack(t, d, "paused")
	require.NoError(t, d.SetTrackEnabled(paused, false))

	list, err := d.ListUnboundCustomTracks()
	require.NoError(t, err)
	var ids []int
	for _, tr := range list {
		ids = append(ids, tr.ID)
	}
	assert.Equal(t, []int{second, first, paused}, ids, "a paused track is listed; a dismissed one is not")
}

func TestMigration00151_UpAndDown(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 150))

	var ids []int64
	for i, origin := range []string{"auto", "custom", "custom"} {
		res, err := d.Exec(`INSERT INTO tracks (text, origin, instruction, enabled) VALUES (?, ?, ?, ?)`,
			fmt.Sprintf("t%d", i), origin, "i", i%2)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		ids = append(ids, id)
		_, err = d.Exec(`INSERT INTO track_events (track_id, summary) VALUES (?, 'e')`, id)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO track_states (track_id, text, category, ownership, priority, source)
			VALUES (?, 's', 'task', 'watching', 'medium', 'manual')`, id)
		require.NoError(t, err)
	}
	snapshot := func() string {
		rows, err := d.Query(`SELECT t.id, t.text, t.origin, t.enabled,
			(SELECT COUNT(*) FROM track_events e WHERE e.track_id = t.id),
			(SELECT COUNT(*) FROM track_states s WHERE s.track_id = t.id)
			FROM tracks t ORDER BY t.id`)
		require.NoError(t, err)
		defer rows.Close()
		out := ""
		for rows.Next() {
			var (
				id, enabled, events, states int64
				text, origin                string
			)
			require.NoError(t, rows.Scan(&id, &text, &origin, &enabled, &events, &states))
			out += fmt.Sprintf("%d|%s|%s|%d|%d|%d;", id, text, origin, enabled, events, states)
		}
		require.NoError(t, rows.Err())
		return out
	}
	objects := func() int {
		return countWhere(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name IN
			('idx_tracks_automation_id','trg_automations_enabled_watch_track','trg_automations_delete_watch_track')`)
	}
	hasColumn := func() int {
		return countWhere(t, d, `SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name = 'automation_id'`)
	}
	before := snapshot()
	require.Equal(t, 0, hasColumn())

	require.NoError(t, gooseUp(d.DB, "migrations"))
	assert.Equal(t, before, snapshot(), "every row and id is kept")
	assert.Equal(t, 1, hasColumn())
	assert.Equal(t, 3, objects())
	assert.Equal(t, len(ids), countWhere(t, d, `SELECT COUNT(*) FROM tracks WHERE automation_id IS NULL`))

	// Bind one so the down migration drops a populated column.
	a := seedSyncRecipe(t, d, "w", TriggerKindSync, `{"sync":"tracks"}`)
	require.NoError(t, d.BindWatchTrack(int(ids[1]), a))
	afterBind := snapshot()

	require.NoError(t, gooseDownTo(d.DB, "migrations", 150))
	assert.Equal(t, 0, hasColumn())
	assert.Equal(t, 0, objects())
	assert.Equal(t, afterBind, snapshot(), "the rows are kept")
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM pragma_foreign_key_check`))
}
