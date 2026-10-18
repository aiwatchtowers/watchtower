package cmd

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

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
// `db migrate` exit non-zero, naming the table and its migration, after the
// prompt templates were still seeded.
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

	database, err = db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	var prompts int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM prompts`).Scan(&prompts))
	assert.Positive(t, prompts, "prompt seeding must still run on a drifted database")
}

// TestDBMigrate_NeverCompacts: `db migrate` stays within its 30 s launch
// contract — it never VACUUMs, even with a lot of free pages, and records
// no compaction.
func TestDBMigrate_NeverCompacts(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	tx, err := database.Begin()
	require.NoError(t, err)
	raw := `{"pad":"` + strings.Repeat("x", 8<<10) + `"}`
	for i := range 500 {
		_, err := tx.Exec(`INSERT INTO messages (channel_id, ts, text, raw_json) VALUES (?, ?, ?, ?)`,
			"C001", fmt.Sprintf("%d.000100", 1700000000+i), fmt.Sprintf("message %d", i), raw)
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
	_, err = database.Exec(`UPDATE messages SET raw_json = '{}'`)
	require.NoError(t, err)
	_, err = database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
	require.NoError(t, err)
	var freelist int64
	require.NoError(t, database.QueryRow(`PRAGMA freelist_count`).Scan(&freelist))
	require.Positive(t, freelist, "precondition: the fixture left no free pages to compact")
	require.NoError(t, database.Close())
	info, err := os.Stat(cfg.DBPath())
	require.NoError(t, err)
	before := info.Size()

	require.NoError(t, dbMigrateCmd.RunE(dbMigrateCmd, nil))

	info, err = os.Stat(cfg.DBPath())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, info.Size(), before, "db migrate shrank the database file")
	d, err := db.OpenExisting(cfg.DBPath(), 5*time.Second)
	require.NoError(t, err)
	defer d.Close()
	var recorded int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM db_maintenance WHERE key = 'compacted_at'`).Scan(&recorded))
	assert.Zero(t, recorded, "db migrate recorded a compaction")
}
