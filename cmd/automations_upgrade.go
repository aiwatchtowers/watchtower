package cmd

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// automationsUpgradePauseReason is the disabled_reason the one-time upgrade
// step writes on every recipe it pauses (board #671, ask #372); Desktop's
// failure watch shows it in its notice.
const automationsUpgradePauseReason = "Paused by the update: Automations was turned off. Turn it on to run it again."

// automationsUpgradeMarker is the file the upgrade step writes in a workspace
// directory once that workspace's database is paused (content: RFC 3339 time).
// A retry after a partial failure skips such a workspace, so a recipe the
// owner turned back on there is not paused again. The markers are removed
// once the key is gone.
const automationsUpgradeMarker = "automations-upgrade-paused"

// runAutomationsUpgradeStep runs pauseAutomationsTurnedOff over the daemon's
// config file and data root; a data root it cannot resolve fails closed.
func runAutomationsUpgradeStep(legacyDigestOff bool, logger *log.Logger) bool {
	root, err := config.DataRoot()
	if err != nil {
		logger.Printf("automations: upgrade step: %v — automations not started this run", err)
		return false
	}
	return pauseAutomationsTurnedOff(flagConfig, root, legacyDigestOff, time.Now(), logger)
}

// pauseAutomationsTurnedOff is the daemon's one-time upgrade step for the
// removed automations feature switch (board #671, ask #372). An install whose
// automations were off — config.yaml says automations.enabled: false, or
// legacyDigestOff (this start's MigrateFeatureGates found a legacy
// digest.enabled=false "all AI off" install) — must not start spending tokens
// on the update. So, in every workspace database under dataRoot, each in one
// transaction, every enabled recipe is paused with
// automationsUpgradePauseReason and the queued non-dry runs are cancelled
// (db.PauseAutomationsForUpgrade), and the workspace gets its
// automationsUpgradeMarker; then the key is removed from configPath, which
// makes the step a no-op from the next start on.
//
// It reports whether the daemon may wire automations this run. Any failure
// (a marker write included) is logged, keeps the key (the next start retries)
// and returns false: fail closed, no scheduler, executor or event bus for this
// process. A workspace that failed is not rolled back in the others; the
// retry skips every workspace whose marker exists, so it never pauses a
// recipe the owner turned back on in a workspace already done.
//
// It runs under an agent marker too, unlike carryOverWorkflowChecks: it only
// turns recipes off and removes a key nothing reads, so no owner decision is
// taken for the owner, and refusing would leave the install fail-closed.
func pauseAutomationsTurnedOff(configPath, dataRoot string, legacyDigestOff bool, now time.Time, logger *log.Logger) bool {
	keyOff, err := config.LegacyAutomationsOff(configPath)
	if err != nil {
		logger.Printf("automations: upgrade step: %v — automations not started this run", err)
		return false
	}
	if !keyOff && !legacyDigestOff {
		return true
	}
	names, err := config.WorkspaceDirsWithDatabase(dataRoot)
	if err != nil {
		logger.Printf("automations: upgrade step: %v — automations not started this run", err)
		return false
	}
	ok := true
	for _, name := range names {
		dir := filepath.Join(dataRoot, name)
		paused, cancelled, done, err := pauseWorkspaceOnce(dir, now)
		if err != nil {
			logger.Printf("automations: upgrade step: workspace %s: %v", name, err)
			ok = false
			continue
		}
		if done {
			logger.Printf("automations: upgrade step: workspace %s: already paused by an earlier attempt — skipped", name)
			continue
		}
		logger.Printf("automations: upgrade step: workspace %s: paused %d automation(s), cancelled %d queued run(s) — Automations was turned off before the update", name, paused, cancelled)
	}
	if !ok {
		logger.Println("automations: upgrade step failed — automations not started this run; the next start retries")
		return false
	}
	if err := config.RemoveLegacyAutomationsKey(configPath); err != nil {
		logger.Printf("automations: upgrade step: removing %s: %v — automations not started this run; the next start retries", config.LegacyAutomationsKey, err)
		return false
	}
	for _, name := range names {
		if err := os.Remove(filepath.Join(dataRoot, name, automationsUpgradeMarker)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			logger.Printf("automations: upgrade step: workspace %s: removing the upgrade marker: %v (harmless: the key is gone)", name, err)
		}
	}
	return true
}

// pauseWorkspaceOnce pauses the workspace in dir unless its
// automationsUpgradeMarker exists (done = true), then writes the marker. A
// marker it cannot check or write is an error: the key stays.
func pauseWorkspaceOnce(dir string, now time.Time) (paused, cancelled int, done bool, err error) {
	marker := filepath.Join(dir, automationsUpgradeMarker)
	if _, err := os.Stat(marker); err == nil {
		return 0, 0, true, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return 0, 0, false, fmt.Errorf("checking the upgrade marker: %w", err)
	}
	paused, cancelled, err = pauseWorkspaceAutomations(filepath.Join(dir, "watchtower.db"), now)
	if err != nil {
		return 0, 0, false, err
	}
	if err := fsutil.WriteFileAtomic(marker, []byte(now.UTC().Format(time.RFC3339)+"\n"), 0o600); err != nil {
		return 0, 0, false, fmt.Errorf("writing the upgrade marker: %w", err)
	}
	return paused, cancelled, false, nil
}

// pauseWorkspaceAutomations opens the database at path, pauses its enabled
// recipes and cancels its queued non-dry runs in one transaction.
func pauseWorkspaceAutomations(path string, now time.Time) (paused, cancelled int, err error) {
	database, err := db.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer database.Close()
	return database.PauseAutomationsForUpgrade(automationsUpgradePauseReason, now)
}
