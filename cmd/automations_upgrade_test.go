package cmd

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

var upgradeNow = time.Date(2026, 10, 18, 9, 0, 0, 0, time.UTC)

// upgradeWorkspace is one seeded workspace database for the upgrade step: an
// enabled recipe with a queued manual run and a queued dry run, and a recipe
// already disabled by the daemon for its own reason.
type upgradeWorkspace struct {
	path                       string
	enabled, disabled          int64
	queuedManual, queuedDryRun int64
}

func seedUpgradeWorkspace(t *testing.T, root, name string) upgradeWorkspace {
	t.Helper()
	ws := upgradeWorkspace{path: filepath.Join(root, name, "watchtower.db")}
	d, err := db.Open(ws.path)
	require.NoError(t, err)
	defer d.Close()
	old := upgradeNow.Add(-48 * time.Hour)
	seed := func(slug string) int64 {
		id, err := d.UpsertAutomationIndex(db.Automation{
			Slug: slug, Scope: "personal", Path: "/acme/automations/" + slug + ".md", Name: slug,
			TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
			Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
			PermissionsJSON: `["llm:light"]`, OutputsJSON: `["inbox"]`,
			RecipeText: "---\nname: x\n---\n", ContentHash: "c-" + slug, ApprovalHash: "h-" + slug,
		})
		require.NoError(t, err)
		return id
	}
	ws.enabled = seed("nightly")
	require.NoError(t, d.SetAutomationEnabled(ws.enabled, true, old))
	ws.disabled = seed("runaway")
	require.NoError(t, d.DisableRunawayAutomation(ws.disabled, "too many failures", old))
	ws.queuedManual, _, err = d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: ws.enabled, Trigger: db.TriggerManual, Now: old})
	require.NoError(t, err)
	ws.queuedDryRun, _, err = d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: ws.enabled, Trigger: db.TriggerDryRun, Now: old})
	require.NoError(t, err)
	return ws
}

// assertPaused checks the workspace after a successful step: the enabled
// recipe paused with the reason, its queued manual run cancelled, the dry run
// and the already-disabled recipe untouched.
func (ws upgradeWorkspace) assertPaused(t *testing.T) {
	t.Helper()
	d, err := db.Open(ws.path)
	require.NoError(t, err)
	defer d.Close()
	a, err := d.GetAutomation(ws.enabled)
	require.NoError(t, err)
	assert.False(t, a.Enabled, "enabled recipe paused")
	assert.Equal(t, automationsUpgradePauseReason, a.DisabledReason)
	require.NotNil(t, a.DisabledAt)
	assert.True(t, a.DisabledAt.Equal(upgradeNow))
	b, err := d.GetAutomation(ws.disabled)
	require.NoError(t, err)
	assert.Equal(t, "too many failures", b.DisabledReason, "an already-disabled recipe keeps its own reason")
	run, err := d.GetAutomationRun(ws.queuedManual)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)
	dry, err := d.GetAutomationRun(ws.queuedDryRun)
	require.NoError(t, err)
	assert.Equal(t, db.RunQueued, dry.Status, "a dry run belongs to a live CLI")
}

// assertUntouched checks the enabled recipe is still on and its run queued.
func (ws upgradeWorkspace) assertUntouched(t *testing.T) {
	t.Helper()
	d, err := db.Open(ws.path)
	require.NoError(t, err)
	defer d.Close()
	a, err := d.GetAutomation(ws.enabled)
	require.NoError(t, err)
	assert.True(t, a.Enabled)
	assert.Empty(t, a.DisabledReason)
	run, err := d.GetAutomationRun(ws.queuedManual)
	require.NoError(t, err)
	assert.Equal(t, db.RunQueued, run.Status)
}

func writeUpgradeConfig(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))
	return p
}

func keyOff(t *testing.T, path string) bool {
	t.Helper()
	off, err := config.LegacyAutomationsOff(path)
	require.NoError(t, err)
	return off
}

// An install with automations.enabled: false gets every enabled recipe paused
// in every workspace database, and the key removed with the rest of the file
// (comments included) kept; the next start is a no-op.
func TestPauseAutomationsTurnedOff_PausesEveryWorkspaceAndRemovesKey(t *testing.T) {
	root := t.TempDir()
	acme := seedUpgradeWorkspace(t, root, "acme")
	other := seedUpgradeWorkspace(t, root, "other")
	cfgPath := writeUpgradeConfig(t, "# owner note\nactive_workspace: acme\nautomations:\n  enabled: false\n")
	var logs bytes.Buffer

	ok := pauseAutomationsTurnedOff(cfgPath, root, false, upgradeNow, log.New(&logs, "", 0))

	require.True(t, ok, logs.String())
	acme.assertPaused(t)
	other.assertPaused(t)
	assert.False(t, keyOff(t, cfgPath), "the key is removed")
	raw, err := os.ReadFile(cfgPath)
	require.NoError(t, err)
	assert.Contains(t, string(raw), "# owner note")
	assert.Contains(t, string(raw), "active_workspace: acme")
	assert.NotContains(t, string(raw), "automations")
	assert.Contains(t, logs.String(), "paused 1 automation(s), cancelled 1 queued run(s)")

	// Owner turns the recipe back on; the next start must not pause it again.
	d, err := db.Open(acme.path)
	require.NoError(t, err)
	require.NoError(t, d.SetAutomationEnabled(acme.enabled, true, upgradeNow))
	require.NoError(t, d.Close())
	require.True(t, pauseAutomationsTurnedOff(cfgPath, root, false, upgradeNow.Add(time.Hour), log.New(&logs, "", 0)))
	d, err = db.Open(acme.path)
	require.NoError(t, err)
	defer d.Close()
	a, err := d.GetAutomation(acme.enabled)
	require.NoError(t, err)
	assert.True(t, a.Enabled, "with the key gone the step is a no-op")
}

// A legacy digest.enabled=false install (MigrateFeatureGates reported it this
// start) counts as off even when the key is not on disk.
func TestPauseAutomationsTurnedOff_LegacyDigestOffCountsAsOff(t *testing.T) {
	root := t.TempDir()
	acme := seedUpgradeWorkspace(t, root, "acme")
	cfgPath := writeUpgradeConfig(t, "digest:\n  enabled: false\n")

	require.True(t, pauseAutomationsTurnedOff(cfgPath, root, true, upgradeNow, log.New(&bytes.Buffer{}, "", 0)))

	acme.assertPaused(t)
}

// The real legacy migration writes automations.enabled: false, so a step that
// fails after it still sees the key on the next start.
func TestMigrateFeatureGates_LegacyDigestOffLeavesTheUpgradeSignal(t *testing.T) {
	cfgPath := writeUpgradeConfig(t, "digest:\n  enabled: false\n")
	legacy, err := config.MigrateFeatureGates(cfgPath)
	require.NoError(t, err)
	require.True(t, legacy)
	assert.True(t, keyOff(t, cfgPath))
}

// No key, or true, is not off: nothing is paused and the file is not written.
func TestPauseAutomationsTurnedOff_NotOffIsNoOp(t *testing.T) {
	for name, content := range map[string]string{
		"absent": "active_workspace: acme\n",
		"true":   "automations:\n  enabled: true\n",
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			acme := seedUpgradeWorkspace(t, root, "acme")
			cfgPath := writeUpgradeConfig(t, content)

			require.True(t, pauseAutomationsTurnedOff(cfgPath, root, false, upgradeNow, log.New(&bytes.Buffer{}, "", 0)))

			acme.assertUntouched(t)
			raw, err := os.ReadFile(cfgPath)
			require.NoError(t, err)
			assert.Equal(t, content, string(raw))
		})
	}
}

// A database the step cannot open fails closed: the other workspaces are
// still paused, the key stays for the next start, and the daemon wires no
// automations this run. Once the database is fixed, the retry completes.
func TestPauseAutomationsTurnedOff_FailedDatabaseFailsClosedAndRetries(t *testing.T) {
	root := t.TempDir()
	acme := seedUpgradeWorkspace(t, root, "acme")
	broken := filepath.Join(root, "broken", "watchtower.db")
	require.NoError(t, os.MkdirAll(filepath.Dir(broken), 0o700))
	require.NoError(t, os.WriteFile(broken, []byte("not a sqlite database, just bytes"), 0o600))
	cfgPath := writeUpgradeConfig(t, "automations:\n  enabled: false\n")
	var logs bytes.Buffer

	ok := pauseAutomationsTurnedOff(cfgPath, root, false, upgradeNow, log.New(&logs, "", 0))

	assert.False(t, ok, "fail closed")
	assert.True(t, keyOff(t, cfgPath), "the key stays so the next start retries")
	assert.Contains(t, logs.String(), "workspace broken")
	acme.assertPaused(t)

	require.NoError(t, os.Remove(broken))
	require.True(t, pauseAutomationsTurnedOff(cfgPath, root, false, upgradeNow, log.New(&logs, "", 0)), logs.String())
	assert.False(t, keyOff(t, cfgPath))
}

// A config file that cannot be read fails closed too.
func TestPauseAutomationsTurnedOff_UnreadableConfigFailsClosed(t *testing.T) {
	cfgPath := writeUpgradeConfig(t, "automations: [\n")
	assert.False(t, pauseAutomationsTurnedOff(cfgPath, t.TempDir(), false, upgradeNow, log.New(&bytes.Buffer{}, "", 0)))
}
