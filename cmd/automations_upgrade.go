package cmd

import (
	"log"
	"path/filepath"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// automationsUpgradePauseReason is the disabled_reason the one-time upgrade
// step writes on every recipe it pauses (board #671, ask #372); Desktop's
// failure watch shows it in its notice.
const automationsUpgradePauseReason = "Paused by the update: Automations was turned off. Turn it on to run it again."

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
// (db.PauseAutomationsForUpgrade); then the key is removed from configPath,
// which makes the step a no-op from the next start on.
//
// It reports whether the daemon may wire automations this run. Any failure is
// logged, keeps the key (the next start retries) and returns false: fail
// closed, no scheduler, executor or event bus for this process. A database
// that failed is not rolled back in the others — pausing twice is harmless.
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
		paused, cancelled, err := pauseWorkspaceAutomations(filepath.Join(dataRoot, name, "watchtower.db"), now)
		if err != nil {
			logger.Printf("automations: upgrade step: workspace %s: %v", name, err)
			ok = false
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
	return true
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
