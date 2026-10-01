package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

func TestDbCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "db" {
			found = true
			break
		}
	}
	assert.True(t, found, "db command should be registered")
}

func TestDbMigrateSubcommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range dbCmd.Commands() {
		if cmd.Name() == "migrate" {
			found = true
			break
		}
	}
	assert.True(t, found, "db migrate subcommand should be registered")
}

func TestDbMigrate(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	err := dbMigrateCmd.RunE(dbMigrateCmd, nil)
	require.NoError(t, err)
}

func TestDbMigrate_RequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	err := dbMigrateCmd.RunE(dbMigrateCmd, nil)
	assert.Error(t, err)
}

// TestDbMigrate_FailsOnUnrepairableSchemaDrift: a table missing under a
// recorded goose version whose migration cannot be replayed safely makes
// `db migrate` exit non-zero, naming the table and its migration.
func TestDbMigrate_FailsOnUnrepairableSchemaDrift(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	_, err = database.Exec(`PRAGMA foreign_keys = OFF`)
	require.NoError(t, err)
	_, err = database.Exec(`DROP TABLE google_accounts`)
	require.NoError(t, err)
	require.NoError(t, database.Close())

	err = dbMigrateCmd.RunE(dbMigrateCmd, nil)
	var drift *db.SchemaDriftError
	require.ErrorAs(t, err, &drift)
	assert.Contains(t, err.Error(), "google_accounts (00043_google_accounts.sql)")
}
