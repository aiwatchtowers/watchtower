package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/automations/watch"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// customisePrompt seeds the prompt store and stores text as the owner's
// customised template of id (a row is inserted first when id has none, as
// for a role variant).
func (c *builtinCLI) customisePrompt(t *testing.T, id, text string) {
	t.Helper()
	customisePromptRow(t, c.d, id, text)
}

func customisePromptRow(t *testing.T, d *db.DB, id, text string) {
	t.Helper()
	require.NoError(t, prompts.New(d, nil).Seed())
	p, err := d.GetPrompt(id)
	require.NoError(t, err)
	if p == nil {
		require.NoError(t, d.UpsertPrompt(db.Prompt{ID: id, Template: text, Version: 1}))
	}
	require.NoError(t, d.UpdatePrompt(id, text, "owner edit", true))
}

// upgrade runs the daemon's upgrade step on c and returns Morning brief's
// active flag.
func (c *builtinCLI) upgrade(t *testing.T) bool {
	t.Helper()
	return upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(io.Discard, "", 0))[morningBriefID]
}

func (c *builtinCLI) migration(t *testing.T) *db.BuiltinMigration {
	t.Helper()
	m, err := c.d.GetBuiltinMigration(morningBriefID)
	require.NoError(t, err)
	require.NotNil(t, m)
	return m
}

func morningBriefEntry(t *testing.T) builtin.Entry {
	t.Helper()
	e, ok := builtin.Lookup(morningBriefID)
	require.True(t, ok)
	return e
}

func TestBuiltinUpgrade_NoCustomPromptRecordsDone(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	require.NoError(t, prompts.New(c.d, nil).Seed())
	assert.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
	m := c.migration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.Empty(t, m.Error)
	assert.Equal(t, 1, m.Attempts)
	assert.False(t, c.row(t).Overridden)
}

func TestBuiltinUpgrade_CustomPromptBecomesConfirmedCopy(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true, builtinBriefReply)
	carried := "CARRIED MARKER\n" + prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, carried)

	require.True(t, c.upgrade(t))
	data, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, err)
	want, err := builtin.RenderOwnerCopy(morningBriefEntry(t), map[string]string{"brief": carried})
	require.NoError(t, err)
	assert.Equal(t, string(want), string(data), "only the customised prompt is carried")
	_, err = automations.ParseRecipe(morningBriefID, data, automations.Scope{Kind: automations.ScopePersonal, BuiltinID: morningBriefID})
	require.NoError(t, err)
	row := c.row(t)
	assert.True(t, row.Overridden)
	assert.True(t, row.Confirmed())
	assert.Equal(t, morningBriefEntry(t).ShippedContentHash(), row.BuiltinBaseHash)
	assert.Equal(t, db.BuiltinMigrationDone, c.migration(t).Status)

	code, stderr := executeCLI(t, "briefing", "generate")
	require.Equal(t, 0, code, stderr)
	require.NotEmpty(t, c.gen.Calls)
	assert.Contains(t, c.gen.Calls[0].SystemPrompt, "CARRIED MARKER", "the run passes the carried text")
}

func TestBuiltinUpgrade_CarriesTheResolvedRolePrompt(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "lead"}))
	base := prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, "BASE MARKER\n"+base)
	c.customisePrompt(t, prompts.BriefingDaily+"_lead", "ROLE MARKER\n"+base)
	resolved, _, err := prompts.Resolve(prompts.New(c.d, nil), prompts.BriefingDaily, "lead")
	require.NoError(t, err)
	require.Equal(t, "ROLE MARKER\n"+base, resolved, "GetForRole resolves the role row")

	require.True(t, c.upgrade(t))
	want, err := builtin.RenderOwnerCopy(morningBriefEntry(t), map[string]string{"brief": resolved})
	require.NoError(t, err)
	data, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, err)
	assert.Equal(t, string(want), string(data))
	assert.NotContains(t, string(data), "BASE MARKER")
}

func TestBuiltinUpgrade_DayPlanIgnoresRole(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "lead"}))
	// The day plan's legacy pipeline never read a role variant: only the
	// base row ran, so only it is carried.
	c.customisePrompt(t, prompts.DayPlanGenerate+"_lead", "ROLE PLAN\n"+prompts.Defaults[prompts.DayPlanGenerate])
	require.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))

	c2 := newUnmovedBuiltinCLI(t, true)
	c2.customisePrompt(t, prompts.DayPlanGenerate, "BASE PLAN\n"+prompts.Defaults[prompts.DayPlanGenerate])
	require.True(t, c2.upgrade(t))
	data, err := os.ReadFile(builtin.OwnerCopyPath(c2.ws, morningBriefID))
	require.NoError(t, err)
	assert.Contains(t, string(data), "BASE PLAN")
}

func TestBuiltinUpgrade_WrongPlaceholderCountIsNotCarried(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	c.customisePrompt(t, prompts.BriefingDaily, "Brief for %s.") // the pipeline ran the default instead
	assert.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
	assert.Equal(t, db.BuiltinMigrationDone, c.migration(t).Status)
}

func TestBuiltinUpgrade_IsIdempotent(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	c.customisePrompt(t, prompts.BriefingDaily, "CARRIED\n"+prompts.Defaults[prompts.BriefingDaily])
	require.True(t, c.upgrade(t))
	path := builtin.OwnerCopyPath(c.ws, morningBriefID)
	first, err := os.ReadFile(path)
	require.NoError(t, err)
	// The owner edits the copy by hand afterwards: a second start keeps it.
	edited := append(bytes.Clone(first), []byte("\n")...)
	require.NoError(t, os.WriteFile(path, edited, 0o600))

	require.True(t, c.upgrade(t))
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, edited, data, "the second call writes nothing")
	assert.Equal(t, 1, c.migration(t).Attempts)
}

func TestBuiltinUpgrade_ResumesAnInterruptedMove(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	carried := "CARRIED\n" + prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, carried)
	// A move that wrote its copy and stopped before the confirmation.
	data, err := builtin.RenderOwnerCopy(morningBriefEntry(t), map[string]string{"brief": carried})
	require.NoError(t, err)
	path := builtin.OwnerCopyPath(c.ws, morningBriefID)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, data, 0o600))
	require.False(t, c.row(t).Confirmed())

	require.True(t, c.upgrade(t))
	assert.True(t, c.row(t).Confirmed())
}

func TestBuiltinUpgrade_FailureKeepsLegacyAndRecords(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	c.customisePrompt(t, prompts.BriefingDaily, "CARRIED\n"+prompts.Defaults[prompts.BriefingDaily])
	dir := filepath.Dir(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, os.MkdirAll(dir, 0o500))
	require.NoError(t, os.Chmod(dir, 0o500))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	var buf bytes.Buffer
	active := upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(&buf, "", 0))
	assert.False(t, active[morningBriefID], "the legacy phases keep running")
	m := c.migration(t)
	assert.Equal(t, db.BuiltinMigrationFailed, m.Status)
	assert.Contains(t, m.Error, "writing")
	assert.Equal(t, 1, m.Attempts)
	assert.Contains(t, buf.String(), "the settings move failed")
	assert.False(t, c.row(t).Overridden)
}

func TestBuiltinUpgrade_RetryCommandRunsFailedOnly(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	// Nothing failed: nothing runs, and no record is written.
	var out upgradeBuiltinsJSON
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	require.NoError(t, json.Unmarshal([]byte(raw), &out))
	assert.Empty(t, out.Results)
	assert.Contains(t, raw, `"results": []`)
	m, err := c.d.GetBuiltinMigration(morningBriefID)
	require.NoError(t, err)
	assert.Nil(t, m, "an entry with no record is the daemon's to move")

	// A done entry is not run again.
	require.NoError(t, c.d.RecordBuiltinMigration(morningBriefID, db.BuiltinMigrationDone, "", time.Now()))
	raw, err = runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	require.NoError(t, json.Unmarshal([]byte(raw), &out))
	assert.Empty(t, out.Results)
	assert.Equal(t, 1, c.migration(t).Attempts)

	// A failed entry runs now.
	carried := "CARRIED\n" + prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, carried)
	require.NoError(t, c.d.RecordBuiltinMigration(morningBriefID, db.BuiltinMigrationFailed, "disk full", time.Now()))
	var keys struct {
		Results []map[string]any `json:"results"`
	}
	raw, err = runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	require.NoError(t, json.Unmarshal([]byte(raw), &keys))
	require.Len(t, keys.Results, 1)
	wantKeys(t, keys.Results[0], "builtin_id", "status", "error")
	assert.Equal(t, morningBriefID, keys.Results[0]["builtin_id"])
	assert.Equal(t, db.BuiltinMigrationDone, keys.Results[0]["status"])
	assert.Equal(t, "", keys.Results[0]["error"])
	m = c.migration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.Equal(t, 3, m.Attempts)
	assert.True(t, c.row(t).Confirmed())
	assert.FileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
}

// TestAuto06_UpgradeConfirmsOnlyCarriedPrompt: the upgrade step confirms
// exactly the copy it rendered from the customised prompt that was running —
// the confirmed hash is that of RenderOwnerCopy's bytes — and never an
// owner's copy already there.
func TestAuto06_UpgradeConfirmsOnlyCarriedPrompt(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	carried := "CARRIED\n" + prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, carried)
	require.True(t, c.upgrade(t))
	want, err := builtin.RenderOwnerCopy(morningBriefEntry(t), map[string]string{"brief": carried})
	require.NoError(t, err)
	r, err := automations.ParseRecipe(morningBriefID, want, automations.Scope{Kind: automations.ScopePersonal, BuiltinID: morningBriefID})
	require.NoError(t, err)
	row := c.row(t)
	assert.Equal(t, automations.ContentHash(want), row.ContentHash)
	assert.Equal(t, automations.ApprovalHash(r), row.ConfirmedHash)

	// An owner's copy already there (not this step's bytes) stays unconfirmed.
	c2 := newUnmovedBuiltinCLI(t, true)
	c2.customisePrompt(t, prompts.BriefingDaily, carried)
	a := c2.writeCopy(t, "OWNER EDIT\n"+prompts.Defaults[prompts.BriefingDaily])
	require.False(t, a.Confirmed())
	require.True(t, c2.upgrade(t))
	after := c2.row(t)
	assert.False(t, after.Confirmed(), "an owner's copy is never confirmed by the step")
	assert.Equal(t, a.ContentHash, after.ContentHash)
}

// TestBuiltinUpgrade_UnreadableRecordKeepsLegacy: a migration record that
// cannot be read leaves the built-in on its legacy phases (its key false,
// and wireBuiltins narrows every registry entry by it).
func TestBuiltinUpgrade_UnreadableRecordKeepsLegacy(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	_, err := c.d.Exec(`INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
		VALUES (?, 'done', '', 1, 'not a time')`, morningBriefID)
	require.NoError(t, err)
	var buf bytes.Buffer
	active := upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(&buf, "", 0))
	v, ok := active[morningBriefID]
	assert.True(t, ok, "the key is there")
	assert.False(t, v, "the legacy phases run")
	assert.Contains(t, buf.String(), "reading its settings move failed")
}

func TestBuiltinUpgrade_RetryRefusedUnderAgentMarkers(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true)
	c.customisePrompt(t, prompts.BriefingDaily, "CARRIED\n"+prompts.Defaults[prompts.BriefingDaily])
	require.NoError(t, c.d.RecordBuiltinMigration(morningBriefID, db.BuiltinMigrationFailed, "disk full", time.Now()))
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			t.Setenv(marker, "1")
			_, err := runAutomations(t, "upgrade-builtins", "--json")
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
			m := c.migration(t)
			assert.Equal(t, db.BuiltinMigrationFailed, m.Status)
			assert.Equal(t, 1, m.Attempts)
		})
	}
}

// TestBuiltinUpgrade_ShippedRoleDefaultWinsOverCustomBase: with no role
// variant row but a shipped role variant default, GetForRole ran that
// default, not the customised base row — nothing is carried.
func TestBuiltinUpgrade_ShippedRoleDefaultWinsOverCustomBase(t *testing.T) {
	const variant = prompts.BriefingDaily + "_testrole"
	prompts.Defaults[variant] = prompts.Defaults[prompts.BriefingDaily]
	t.Cleanup(func() { delete(prompts.Defaults, variant) })
	c := newUnmovedBuiltinCLI(t, true)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "testrole"}))
	c.customisePrompt(t, prompts.BriefingDaily, "BASE MARKER\n"+prompts.Defaults[prompts.BriefingDaily])
	_, err = c.d.Exec(`DELETE FROM prompts WHERE id = ?`, variant) // the seed wrote it; no row is the case
	require.NoError(t, err)
	assert.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
}

// upgradeAll runs the daemon's upgrade step on c and returns its active set.
func (c *c3CLI) upgradeAll(t *testing.T) map[string]bool {
	t.Helper()
	return upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(io.Discard, "", 0))
}

// customTrack creates a custom track of the owner (U001).
func (c *c3CLI) customTrack(t *testing.T, tr db.Track) int {
	t.Helper()
	tr.AssigneeUserID = "U001"
	id, err := c.d.CreateCustomTrack(tr)
	require.NoError(t, err)
	return int(id)
}

// recipeOf is track id's bound watch recipe (the track must be bound).
func (c *c3CLI) recipeOf(t *testing.T, id int) *db.Automation {
	t.Helper()
	tr := c.track(t, id)
	require.NotZero(t, tr.AutomationID, "track #%d is bound", id)
	return c.automation(t, tr.AutomationID)
}

func (c *c3CLI) tracksMigration(t *testing.T) *db.BuiltinMigration {
	t.Helper()
	m, err := c.d.GetBuiltinMigration(customTracksID)
	require.NoError(t, err)
	require.NotNil(t, m)
	return m
}

// watchFiles is the watch-*.md files in the personal folder.
func (c *c3CLI) watchFiles(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(c.personal, "watch-*.md"))
	require.NoError(t, err)
	return files
}

// legacyDue is the ids the daemon's legacy scan would scan today.
func (c *c3CLI) legacyDue(t *testing.T) []int {
	t.Helper()
	due, err := c.d.GetCustomTracksDueForScan(time.Now().UTC().Format("2006-01-02"), 100)
	require.NoError(t, err)
	ids := []int{}
	for _, tr := range due {
		ids = append(ids, tr.ID)
	}
	return ids
}

// failStartOn makes the n-th watch start of the upgrade step fail.
func failStartOn(t *testing.T, n int) {
	t.Helper()
	calls := 0
	upgradeWatchStart = func(ctx context.Context, d *db.DB, ix *automations.Indexer, ws string, tr db.Track, opts watch.StartOptions) (*db.Automation, error) {
		calls++
		if calls == n {
			return nil, errors.New("disk full")
		}
		return watch.Start(ctx, d, ix, ws, tr, opts)
	}
	t.Cleanup(func() { upgradeWatchStart = watch.Start })
}

// TestCustomTracksUpgrade_EachLiveTrackGetsOneConfirmedRecipe: an install
// with many custom tracks — paused, empty instruction, linked to a target,
// two with the same title, one dismissed — gives each live one exactly one
// confirmed watch recipe; its events and watermark are kept, and the move
// is recorded done and active.
func TestCustomTracksUpgrade_EachLiveTrackGetsOneConfirmedRecipe(t *testing.T) {
	c := newC3CLI(t)
	target, err := c.d.CreateTarget(db.Target{Text: "Ship refunds", Level: "week", PeriodStart: "2026-10-19", PeriodEnd: "2026-10-25",
		Priority: "medium", Status: "todo", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	a := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund decision"})
	b := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund amount"})
	paused := c.customTrack(t, db.Track{Text: "Hiring", Instruction: "watch the hiring"})
	require.NoError(t, c.d.SetTrackEnabled(paused, false))
	empty := c.customTrack(t, db.Track{Text: "Budget", Context: "the budget review"})
	linked := c.customTrack(t, db.Track{Text: "Launch", Instruction: "watch the launch", LinkedTargetID: int(target)})
	dismissed := c.customTrack(t, db.Track{Text: "Old", Instruction: "watch the old thing"})
	_, err = c.d.DismissTracks([]int{dismissed})
	require.NoError(t, err)
	_, err = c.d.InsertTrackEvent(db.TrackEvent{TrackID: a, Summary: "refund approved"})
	require.NoError(t, err)
	require.NoError(t, c.d.SetTrackLastRun(a, "2026-10-20T08:00:00Z"))

	active := c.upgradeAll(t)
	assert.True(t, active[customTracksID])
	m := c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.Empty(t, m.Error)

	live := []int{a, b, paused, empty, linked}
	seen := map[int64]bool{}
	for _, id := range live {
		r := c.recipeOf(t, id)
		assert.True(t, r.Confirmed(), "track #%d", id)
		assert.False(t, seen[r.ID], "one recipe per track")
		seen[r.ID] = true
	}
	assert.Len(t, c.watchFiles(t), len(live), "one file per live track")
	slot, err := c.d.ListSlotRecipes(string(builtin.SlotCustomTracks))
	require.NoError(t, err)
	assert.Len(t, slot, len(live))
	assert.Zero(t, c.track(t, dismissed).AutomationID)

	events, err := c.d.GetTrackEvents(a, 10)
	require.NoError(t, err)
	require.Len(t, events, 1)
	assert.Equal(t, "refund approved", events[0].Summary)
	assert.Equal(t, "2026-10-20T08:00:00Z", c.track(t, a).LastRunAt, "the scan watermark is kept")
	assert.Empty(t, c.legacyDue(t), "the legacy scan has nothing left")
}

func TestCustomTracksUpgrade_PausedStaysPaused(t *testing.T) {
	c := newC3CLI(t)
	on := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	paused := c.customTrack(t, db.Track{Text: "Hiring", Instruction: "watch the hiring"})
	require.NoError(t, c.d.SetTrackEnabled(paused, false))

	require.True(t, c.upgradeAll(t)[customTracksID])
	assert.True(t, c.track(t, on).Enabled)
	assert.True(t, c.recipeOf(t, on).Enabled, "Collecting stays Collecting")
	assert.False(t, c.track(t, paused).Enabled)
	r := c.recipeOf(t, paused)
	assert.False(t, r.Enabled, "Paused stays Paused")
	assert.True(t, r.Confirmed(), "a paused track is confirmed too")
}

func TestCustomTracksUpgrade_DismissedStaysUnbound(t *testing.T) {
	c := newC3CLI(t)
	id := c.customTrack(t, db.Track{Text: "Old", Instruction: "watch the old thing"})
	_, err := c.d.DismissTracks([]int{id})
	require.NoError(t, err)

	require.True(t, c.upgradeAll(t)[customTracksID])
	tr := c.track(t, id)
	assert.Zero(t, tr.AutomationID, "a dismissed track gets no recipe")
	assert.NotEmpty(t, tr.DismissedAt)
	assert.Empty(t, c.watchFiles(t))
	assert.Equal(t, db.BuiltinMigrationDone, c.tracksMigration(t).Status)
}

func TestCustomTracksUpgrade_EmptyInstructionUsesContextThenTitle(t *testing.T) {
	c := newC3CLI(t)
	withContext := c.customTrack(t, db.Track{Text: "Budget", Context: "the budget review"})
	titleOnly := c.customTrack(t, db.Track{Text: "Launch day"})

	require.True(t, c.upgradeAll(t)[customTracksID])
	want, err := watch.Render("Budget", "the budget review")
	require.NoError(t, err)
	assert.Equal(t, string(want), c.recipeOf(t, withContext).RecipeText)
	want, err = watch.Render("Launch day", "Launch day")
	require.NoError(t, err)
	assert.Equal(t, string(want), c.recipeOf(t, titleOnly).RecipeText)
}

func TestCustomTracksUpgrade_LinkedTargetKept(t *testing.T) {
	c := newC3CLI(t)
	target, err := c.d.CreateTarget(db.Target{Text: "Ship refunds", Level: "week", PeriodStart: "2026-10-19", PeriodEnd: "2026-10-25",
		Priority: "medium", Status: "todo", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	id := c.customTrack(t, db.Track{Text: "Launch", Instruction: "watch the launch", LinkedTargetID: int(target)})

	require.True(t, c.upgradeAll(t)[customTracksID])
	tr := c.track(t, id)
	assert.NotZero(t, tr.AutomationID)
	assert.Equal(t, int(target), tr.LinkedTargetID)
}

// TestCustomTracksUpgrade_PartialFailureResumesOnRetry: the third start
// fails — two tracks are bound and run as recipes, the move is recorded
// failed and not active, the legacy scan covers exactly the rest (nothing
// scanned twice), and the Retry binds them.
func TestCustomTracksUpgrade_PartialFailureResumesOnRetry(t *testing.T) {
	c := newC3CLI(t)
	ids := []int{
		c.customTrack(t, db.Track{Text: "One", Instruction: "watch one"}),
		c.customTrack(t, db.Track{Text: "Two", Instruction: "watch two"}),
		c.customTrack(t, db.Track{Text: "Three", Instruction: "watch three"}),
		c.customTrack(t, db.Track{Text: "Four", Instruction: "watch four"}),
	}
	failStartOn(t, 3)
	var buf bytes.Buffer
	active := upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(&buf, "", 0))
	assert.False(t, active[customTracksID], "the legacy scan keeps running")
	assert.True(t, active[trackMyThreadsID], "the other moves are not held back")
	m := c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationFailed, m.Status)
	assert.Contains(t, m.Error, "disk full")
	assert.Contains(t, buf.String(), "the move to watch recipes failed")
	for _, id := range ids[:2] {
		assert.True(t, c.recipeOf(t, id).Confirmed(), "track #%d stays bound", id)
	}
	for _, id := range ids[2:] {
		assert.Zero(t, c.track(t, id).AutomationID, "track #%d", id)
	}
	assert.Equal(t, ids[2:], c.legacyDue(t), "the legacy scan covers only the unbound tracks")
	slot, err := c.d.ListSlotRecipes(string(builtin.SlotCustomTracks))
	require.NoError(t, err)
	assert.Len(t, slot, 2, "the bound ones run as recipes")
	assert.False(t, activeBuiltins(map[string]bool{trackMyThreadsID: true}, active)[customTracksID],
		"the daemon's active set keeps the legacy scan")

	upgradeWatchStart = watch.Start
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	var out upgradeBuiltinsJSON
	require.NoError(t, json.Unmarshal([]byte(raw), &out))
	require.Len(t, out.Results, 1)
	assert.Equal(t, builtinUpgradeResult{BuiltinID: customTracksID, Status: db.BuiltinMigrationDone}, out.Results[0])
	seen := map[int64]bool{}
	for _, id := range ids {
		r := c.recipeOf(t, id)
		assert.True(t, r.Confirmed(), "track #%d", id)
		assert.False(t, seen[r.ID])
		seen[r.ID] = true
	}
	assert.Len(t, c.watchFiles(t), len(ids), "the retry wrote no second file")
	m = c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.Equal(t, 2, m.Attempts)
	assert.Empty(t, c.legacyDue(t))
	assert.True(t, c.upgradeAll(t)[customTracksID], "the next daemon start runs the recipes only")
}

func TestCustomTracksUpgrade_IsIdempotent(t *testing.T) {
	c := newC3CLI(t)
	a := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	b := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the amount"})
	require.True(t, c.upgradeAll(t)[customTracksID])
	first := []int64{c.recipeOf(t, a).ID, c.recipeOf(t, b).ID}
	files := c.watchFiles(t)

	// A track made after the move is the commands' to start, never the step's.
	later := c.customTrack(t, db.Track{Text: "Later", Instruction: "watch later"})
	require.True(t, c.upgradeAll(t)[customTracksID])
	assert.Equal(t, first, []int64{c.recipeOf(t, a).ID, c.recipeOf(t, b).ID})
	assert.Equal(t, files, c.watchFiles(t), "the second start writes nothing")
	assert.Zero(t, c.track(t, later).AutomationID)
	assert.Equal(t, 1, c.tracksMigration(t).Attempts)
}

// TestCustomTracksUpgrade_EditedRecipeLeftForOwner: a recipe found edited
// since it was rendered is left bound and unconfirmed; the move goes on and
// is done.
func TestCustomTracksUpgrade_EditedRecipeLeftForOwner(t *testing.T) {
	c := newC3CLI(t)
	edited := c.customTrack(t, db.Track{Text: "One", Instruction: "watch one"})
	next := c.customTrack(t, db.Track{Text: "Two", Instruction: "watch two"})
	upgradeWatchStart = func(ctx context.Context, d *db.DB, ix *automations.Indexer, ws string, tr db.Track, opts watch.StartOptions) (*db.Automation, error) {
		if tr.ID == edited {
			return nil, watch.ErrEditedSinceRendered
		}
		return watch.Start(ctx, d, ix, ws, tr, opts)
	}
	t.Cleanup(func() { upgradeWatchStart = watch.Start })
	var buf bytes.Buffer
	active := upgradeBuiltins(c.cfg, c.d, time.Now(), log.New(&buf, "", 0))
	assert.True(t, active[customTracksID])
	assert.Equal(t, db.BuiltinMigrationDone, c.tracksMigration(t).Status)
	assert.True(t, c.recipeOf(t, next).Confirmed())
	assert.Contains(t, buf.String(), "left for you to confirm in Automations")
}

// TestWireBuiltins_CustomTracksActiveOnlyWhenDone: the daemon's active set
// carries the custom tracks' move, true only when it is done.
func TestWireBuiltins_CustomTracksActiveOnlyWhenDone(t *testing.T) {
	synced := map[string]bool{trackMyThreadsID: true}
	assert.False(t, activeBuiltins(synced, map[string]bool{trackMyThreadsID: true})[customTracksID], "no key: not moved")
	assert.False(t, activeBuiltins(synced, map[string]bool{customTracksID: false})[customTracksID])
	got := activeBuiltins(synced, map[string]bool{customTracksID: true, trackMyThreadsID: false})
	assert.True(t, got[customTracksID])
	assert.False(t, got[trackMyThreadsID], "a failed built-in move keeps its legacy phases")
	assert.False(t, activeBuiltins(map[string]bool{}, map[string]bool{ideaFinderID: true})[ideaFinderID], "a built-in that did not sync stays legacy")

	c := newC3CLI(t)
	c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	assert.True(t, activeBuiltins(synced, c.upgradeAll(t))[customTracksID])
}

func TestBuiltinUpgrade_CustomisedTracksPromptBecomesCopy(t *testing.T) {
	c := newC3CLI(t)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "lead"}))
	base := prompts.Defaults[prompts.TracksExtractBatch]
	customisePromptRow(t, c.d, prompts.TracksExtractBatch, "BASE MARKER\n"+base)
	customisePromptRow(t, c.d, prompts.TracksExtractBatch+"_lead", "ROLE MARKER\n"+base)

	require.True(t, c.upgradeAll(t)[trackMyThreadsID])
	e, ok := builtin.Lookup(trackMyThreadsID)
	require.True(t, ok)
	want, err := builtin.RenderOwnerCopy(e, map[string]string{"extract": "ROLE MARKER\n" + base})
	require.NoError(t, err)
	data, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, trackMyThreadsID))
	require.NoError(t, err)
	assert.Equal(t, string(want), string(data), "the role variant is carried first")
	row := c.builtinRow(t, trackMyThreadsID)
	assert.True(t, row.Overridden)
	assert.True(t, row.Confirmed())
}

func TestBuiltinUpgrade_CustomisedReactionPromptBecomesCopy(t *testing.T) {
	c := newC3CLI(t)
	carried := "REACTION MARKER\n" + prompts.Defaults[prompts.ReactionCommand]
	customisePromptRow(t, c.d, prompts.ReactionCommand, carried)

	require.True(t, c.upgradeAll(t)[reactionsID])
	e, ok := builtin.Lookup(reactionsID)
	require.True(t, ok)
	want, err := builtin.RenderOwnerCopy(e, map[string]string{"compose": carried})
	require.NoError(t, err)
	data, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, reactionsID))
	require.NoError(t, err)
	assert.Equal(t, string(want), string(data))
	row := c.builtinRow(t, reactionsID)
	assert.True(t, row.Overridden)
	assert.True(t, row.Confirmed())
}

// TestAuto06_UpgradeConfirmsOnlyRenderedWatchRecipes: the custom-track move
// confirms exactly the recipe watch.Render made from the track — the
// confirmed hash is that of Render's bytes — and never a watch recipe that
// was already bound unconfirmed (an agent's `tracks create`).
func TestAuto06_UpgradeConfirmsOnlyRenderedWatchRecipes(t *testing.T) {
	c := newC3CLI(t)
	id := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund decision"})
	agents := c.customTrack(t, db.Track{Text: "Hiring", Instruction: "watch the hiring"})
	pending, err := startTrackWatch(context.Background(), c.cfg, c.d, agents, false)
	require.NoError(t, err)
	require.False(t, pending.Confirmed())

	require.True(t, c.upgradeAll(t)[customTracksID])
	want, err := watch.Render("Refund", "watch the refund decision")
	require.NoError(t, err)
	r, err := automations.ParseRecipe(watch.TemplateName, want, automations.Scope{Kind: automations.ScopePersonal})
	require.NoError(t, err)
	a := c.recipeOf(t, id)
	assert.Equal(t, automations.ContentHash(want), a.ContentHash)
	assert.Equal(t, automations.ApprovalHash(r), a.ConfirmedHash)

	after := c.recipeOf(t, agents)
	assert.Equal(t, pending.ID, after.ID)
	assert.False(t, after.Confirmed(), "a watch recipe already bound stays the owner's to confirm")

	// Nor on a Retry: a recipe written before the move's first attempt is
	// not one the move left unconfirmed.
	_, err = c.d.Exec(`UPDATE automations SET created_at = '2026-01-01T00:00:00Z' WHERE id = ?`, pending.ID)
	require.NoError(t, err)
	_, err = c.d.Exec(`UPDATE builtin_migrations SET status = 'failed', error = 'disk full' WHERE builtin_id = ?`, customTracksID)
	require.NoError(t, err)
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	assert.Equal(t, db.BuiltinMigrationDone, c.tracksMigration(t).Status)
	assert.False(t, c.recipeOf(t, agents).Confirmed(), "the Retry leaves it the owner's to confirm")
}

// failConfirm makes the upgrade step's starts bind their track and then
// fail before the confirm, as a busy database at the confirm does; times
// says how many starts fail so (-1: all of them).
func failConfirm(t *testing.T, times int) {
	t.Helper()
	upgradeWatchStart = func(ctx context.Context, d *db.DB, ix *automations.Indexer, ws string, tr db.Track, opts watch.StartOptions) (*db.Automation, error) {
		if times == 0 {
			return watch.Start(ctx, d, ix, ws, tr, opts)
		}
		times--
		if _, err := watch.Start(ctx, d, ix, ws, tr, watch.StartOptions{Now: opts.Now}); err != nil {
			return nil, err
		}
		return nil, errors.New("confirming: database is locked")
	}
	t.Cleanup(func() { upgradeWatchStart = watch.Start })
}

// TestCustomTracksUpgrade_ConfirmFailureAfterBindResumesOnRetry: a start
// that bound its track and failed at the confirm leaves the move failed;
// the Retry confirms that recipe (still the untouched template) with no
// second file, and the move is done.
func TestCustomTracksUpgrade_ConfirmFailureAfterBindResumesOnRetry(t *testing.T) {
	c := newC3CLI(t)
	id := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	failConfirm(t, -1)
	assert.False(t, c.upgradeAll(t)[customTracksID])
	m := c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationFailed, m.Status)
	assert.Contains(t, m.Error, "database is locked")
	first := c.recipeOf(t, id)
	assert.False(t, first.Confirmed(), "bound, not confirmed")

	upgradeWatchStart = watch.Start
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	var out upgradeBuiltinsJSON
	require.NoError(t, json.Unmarshal([]byte(raw), &out))
	require.Len(t, out.Results, 1)
	assert.Equal(t, builtinUpgradeResult{BuiltinID: customTracksID, Status: db.BuiltinMigrationDone}, out.Results[0])
	r := c.recipeOf(t, id)
	assert.Equal(t, first.ID, r.ID)
	assert.True(t, r.Confirmed())
	assert.Len(t, c.watchFiles(t), 1)
}

// TestCustomTracksUpgrade_ConfirmRetriedOnceInTheSameAttempt: a start that
// failed after binding is tried once more at once; when that confirms, the
// move goes on and is done.
func TestCustomTracksUpgrade_ConfirmRetriedOnceInTheSameAttempt(t *testing.T) {
	c := newC3CLI(t)
	a := c.customTrack(t, db.Track{Text: "One", Instruction: "watch one"})
	b := c.customTrack(t, db.Track{Text: "Two", Instruction: "watch two"})
	failConfirm(t, 1)
	assert.True(t, c.upgradeAll(t)[customTracksID])
	assert.Equal(t, db.BuiltinMigrationDone, c.tracksMigration(t).Status)
	assert.True(t, c.recipeOf(t, a).Confirmed())
	assert.True(t, c.recipeOf(t, b).Confirmed())
	assert.Len(t, c.watchFiles(t), 2)
}

// TestCustomTracksUpgrade_TrackMadeAfterFirstAttemptNotConfirmed: a Retry
// covers only the tracks created by the move's first attempt; one made
// afterwards (an agent's, a reaction's) is never confirmed by the move.
func TestCustomTracksUpgrade_TrackMadeAfterFirstAttemptNotConfirmed(t *testing.T) {
	c := newC3CLI(t)
	a := c.customTrack(t, db.Track{Text: "One", Instruction: "watch one"})
	b := c.customTrack(t, db.Track{Text: "Two", Instruction: "watch two"})
	_, err := c.d.Exec(`UPDATE tracks SET created_at = '2026-01-01T00:00:00Z' WHERE id IN (?, ?)`, a, b)
	require.NoError(t, err)
	failStartOn(t, 2)
	assert.False(t, c.upgradeAll(t)[customTracksID])
	_, err = c.d.Exec(`UPDATE builtin_migrations SET first_attempted_at = '2026-01-02T00:00:00Z' WHERE builtin_id = ?`, customTracksID)
	require.NoError(t, err)
	later := c.customTrack(t, db.Track{Text: "Later", Instruction: "watch everything"})

	upgradeWatchStart = watch.Start
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	m := c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.True(t, m.FirstAttemptedAt.Equal(time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)), "the first attempt's moment is kept")
	assert.True(t, c.recipeOf(t, a).Confirmed())
	assert.True(t, c.recipeOf(t, b).Confirmed())
	assert.Zero(t, c.track(t, later).AutomationID, "a track made after the first attempt is not the move's")
	assert.Len(t, c.watchFiles(t), 2)
}

// TestBuiltinUpgrade_RetrySkipsCustomTracksWithNoRecord: with no
// custom-tracks record the move is the daemon's; the Retry runs nothing.
func TestBuiltinUpgrade_RetrySkipsCustomTracksWithNoRecord(t *testing.T) {
	c := newC3CLI(t)
	id := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	var out upgradeBuiltinsJSON
	require.NoError(t, json.Unmarshal([]byte(raw), &out))
	assert.Empty(t, out.Results)
	m, err := c.d.GetBuiltinMigration(customTracksID)
	require.NoError(t, err)
	assert.Nil(t, m, "no record is written")
	assert.Zero(t, c.track(t, id).AutomationID)
	assert.Empty(t, c.watchFiles(t))
}

// TestCustomTracksUpgrade_FirstMomentPersistedBeforeAnyStart: the move dies
// after one start with no record of its own; the stamp written before that
// start keeps the first moment, so the next attempt does not confirm a
// track created in between.
func TestCustomTracksUpgrade_FirstMomentPersistedBeforeAnyStart(t *testing.T) {
	c := newC3CLI(t)
	a := c.customTrack(t, db.Track{Text: "One", Instruction: "watch one"})
	b := c.customTrack(t, db.Track{Text: "Two", Instruction: "watch two"})
	_, err := c.d.Exec(`UPDATE tracks SET created_at = '2026-01-01T00:00:00Z' WHERE id IN (?, ?)`, a, b)
	require.NoError(t, err)
	first := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	failStartOn(t, 2)
	// startCustomTrackWatches alone: the daemon died before recordUpgrade.
	require.Error(t, startCustomTrackWatches(c.cfg, c.d, first, log.New(io.Discard, "", 0)))
	m := c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationFailed, m.Status, "a crash reads as failed and retryable")
	assert.Equal(t, db.BuiltinMigrationInterrupted, m.Error)
	assert.Zero(t, m.Attempts)
	assert.True(t, m.FirstAttemptedAt.Equal(first))
	later := c.customTrack(t, db.Track{Text: "Later", Instruction: "watch everything"})

	upgradeWatchStart = watch.Start
	require.True(t, c.upgradeAll(t)[customTracksID])
	m = c.tracksMigration(t)
	assert.Equal(t, db.BuiltinMigrationDone, m.Status)
	assert.Equal(t, 1, m.Attempts)
	assert.True(t, m.FirstAttemptedAt.Equal(first), "the stamped moment is the cutoff")
	assert.True(t, c.recipeOf(t, a).Confirmed())
	assert.True(t, c.recipeOf(t, b).Confirmed())
	assert.Zero(t, c.track(t, later).AutomationID, "a track created after the first moment is not the move's")
}

// TestAuto06_UpgradeRetryNeverConfirmsAnInstructionEditedOnDisk: a failed
// attempt left the recipe bound and unconfirmed; its instruction line is
// edited on disk (still template-shaped); the Retry leaves it unconfirmed
// for the owner and the move is done.
func TestAuto06_UpgradeRetryNeverConfirmsAnInstructionEditedOnDisk(t *testing.T) {
	c := newC3CLI(t)
	id := c.customTrack(t, db.Track{Text: "Refund", Instruction: "watch the refund"})
	failConfirm(t, -1)
	assert.False(t, c.upgradeAll(t)[customTracksID])
	bound := c.recipeOf(t, id)
	require.False(t, bound.Confirmed())
	edited, err := watch.SetInstruction([]byte(bound.RecipeText), "watch every message in every channel")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(bound.Path, edited, 0o600))
	ix := automations.NewIndexer(c.d, c.cfg.WorkspaceDir(), automations.RealClock{})
	_, err = ix.RescanPersonal(context.Background())
	require.NoError(t, err)
	require.Equal(t, string(edited), c.recipeOf(t, id).RecipeText)

	upgradeWatchStart = watch.Start
	raw, err := runAutomations(t, "upgrade-builtins", "--json")
	require.NoError(t, err, raw)
	assert.Equal(t, db.BuiltinMigrationDone, c.tracksMigration(t).Status)
	r := c.recipeOf(t, id)
	assert.Equal(t, bound.ID, r.ID)
	assert.False(t, r.Confirmed(), "an instruction edited on disk is the owner's to confirm")
}

func TestBuiltinUpgrade_CarriesRawTemplateWithoutAdditions(t *testing.T) {
	c := newUnmovedBuiltinCLI(t, true, builtinBriefReply)
	carried := "CARRIED MARKER\n" + prompts.Defaults[prompts.BriefingDaily]
	c.customisePrompt(t, prompts.BriefingDaily, carried)
	_, err := c.d.AddPromptAddition(prompts.BriefingDaily, "Keep it short.", 0, time.Now())
	require.NoError(t, err)

	require.True(t, c.upgrade(t))
	data, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, err)
	assert.NotContains(t, string(data), "OWNER PREFERENCES")
	assert.Contains(t, string(data), "CARRIED MARKER")
}
