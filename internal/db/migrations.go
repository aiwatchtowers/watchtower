package db

import (
	"embed"
	"log"

	"github.com/pressly/goose/v3"
)

// CurrentSchemaFormat is the version of the on-disk migration accounting
// scheme. Bumped when the migration engine itself changes (not the schema):
//
//	1 — legacy PRAGMA user_version + manual switch in migrate() (pre-goose)
//	2 — goose, with goose_db_version as source of truth
//
// The runtime compares this to config.DB.SchemaFormat at startup and runs
// RunSchemaUpgrade once when behind.
const CurrentSchemaFormat = 2

//go:embed migrations/*.sql
var migrationsFS embed.FS

func init() {
	goose.SetBaseFS(migrationsFS)
	if err := goose.SetDialect("sqlite3"); err != nil {
		log.Fatalf("setting goose dialect: %v", err)
	}
	goose.SetLogger(goose.NopLogger())
}
