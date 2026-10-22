package cmd

import (
	"bytes"
	"encoding/json"
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
	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// customisePrompt seeds the prompt store and stores text as the owner's
// customised template of id (a row is inserted first when id has none, as
// for a role variant).
func (c *builtinCLI) customisePrompt(t *testing.T, id, text string) {
	t.Helper()
	require.NoError(t, prompts.New(c.d, nil).Seed())
	p, err := c.d.GetPrompt(id)
	require.NoError(t, err)
	if p == nil {
		require.NoError(t, c.d.UpsertPrompt(db.Prompt{ID: id, Template: text, Version: 1}))
	}
	require.NoError(t, c.d.UpdatePrompt(id, text, "owner edit", true))
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true, builtinBriefReply)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "lead"}))
	// The day plan's legacy pipeline never read a role variant: only the
	// base row ran, so only it is carried.
	c.customisePrompt(t, prompts.DayPlanGenerate+"_lead", "ROLE PLAN\n"+prompts.Defaults[prompts.DayPlanGenerate])
	require.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))

	c2 := newBuiltinCLI(t, true)
	c2.customisePrompt(t, prompts.DayPlanGenerate, "BASE PLAN\n"+prompts.Defaults[prompts.DayPlanGenerate])
	require.True(t, c2.upgrade(t))
	data, err := os.ReadFile(builtin.OwnerCopyPath(c2.ws, morningBriefID))
	require.NoError(t, err)
	assert.Contains(t, string(data), "BASE PLAN")
}

func TestBuiltinUpgrade_WrongPlaceholderCountIsNotCarried(t *testing.T) {
	c := newBuiltinCLI(t, true)
	c.customisePrompt(t, prompts.BriefingDaily, "Brief for %s.") // the pipeline ran the default instead
	assert.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
	assert.Equal(t, db.BuiltinMigrationDone, c.migration(t).Status)
}

func TestBuiltinUpgrade_IsIdempotent(t *testing.T) {
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c2 := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
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
	c := newBuiltinCLI(t, true)
	o, err := c.d.RequireOwner()
	require.NoError(t, err)
	require.NoError(t, c.d.UpsertOwnerProfile(o, db.UserProfile{Role: "testrole"}))
	c.customisePrompt(t, prompts.BriefingDaily, "BASE MARKER\n"+prompts.Defaults[prompts.BriefingDaily])
	_, err = c.d.Exec(`DELETE FROM prompts WHERE id = ?`, variant) // the seed wrote it; no row is the case
	require.NoError(t, err)
	assert.True(t, c.upgrade(t))
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
}
