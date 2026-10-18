package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/pressly/goose/v3"
)

// Migration 00125 (agent analytics parser v2, #298) is a Go migration so it
// tolerates columns that already exist: a branch build applied these columns
// inside goose under its own version 124 (main's 00124 is review_checks), so
// such a file records 124 with agent_log_events.spawned_agent_id and
// background present, and the plain ALTERs failed every open with
// "duplicate column" (#667). Each column is added only when
// pragma_table_info lacks it; a present one must match the definition below,
// or the migration fails. The statements are the ones the SQL file ran, so
// the resulting schema is unchanged. SQLite has no ADD COLUMN IF NOT EXISTS.
func init() {
	goose.AddNamedMigrationContext("00125_agent_analytics_history.go", up00125, down00125)
}

// goMigrationTouches names, per registered Go migration, the tables and
// views it changes. The schema-drift check reads migrations as SQL text, so
// this is how it learns what a Go migration touches; loadMigrations refuses a
// Go migration missing here.
var goMigrationTouches = map[int64][]string{
	125: {"agent_log_events", "agent_log_session_totals"},
}

// columns00125 are the columns 00125 adds, with the pragma_table_info type
// and default a column already present must have (both are NOT NULL).
var columns00125 = []struct{ name, ddl, typ, dflt string }{
	{"spawned_agent_id", `ALTER TABLE agent_log_events ADD COLUMN spawned_agent_id TEXT NOT NULL DEFAULT ''`, "TEXT", "''"},
	{"background", `ALTER TABLE agent_log_events ADD COLUMN background INTEGER NOT NULL DEFAULT 0`, "INTEGER", "0"},
}

// ownerTurns00125 is the owner_turns expression 00125 installs.
const ownerTurns00125 = `SUM(CASE WHEN kind = 'owner_turn' AND trigger NOT IN ('notification','hook') THEN 1 ELSE 0 END)`

// sessionTotalsView00125 builds agent_log_session_totals; ownerTurns is the
// owner_turns expression, the only part 00125 changes.
func sessionTotalsView00125(ownerTurns string) string {
	return `CREATE VIEW agent_log_session_totals AS
SELECT session_uuid,
  SUM(CASE WHEN kind = 'api_call' THEN 1 ELSE 0 END)   AS api_calls,
  SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
  SUM(cache_read_tokens) AS cache_read_tokens,
  SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
  SUM(cache_write_1h_tokens) AS cache_write_1h_tokens,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_estimated) AS cost_estimated_calls,
  ` + ownerTurns + ` AS owner_turns,
  SUM(CASE WHEN kind = 'tool' THEN 1 ELSE 0 END)       AS tool_calls,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'error' THEN 1 ELSE 0 END)       AS tool_errors,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'denied' THEN 1 ELSE 0 END)      AS tool_denials,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'interrupted' THEN 1 ELSE 0 END) AS tool_interrupts,
  SUM(CASE WHEN kind = 'skill' THEN 1 ELSE 0 END)      AS skill_activations,
  SUM(CASE WHEN kind = 'compaction' THEN 1 ELSE 0 END) AS compactions,
  SUM(lines_added) AS lines_added, SUM(lines_removed) AS lines_removed
FROM agent_log_events GROUP BY session_uuid`
}

func up00125(ctx context.Context, tx *sql.Tx) error {
	for _, c := range columns00125 {
		if err := addColumn00125(ctx, tx, c.name, c.ddl, c.typ, c.dflt); err != nil {
			return err
		}
	}
	return execAll(ctx, tx,
		`DROP VIEW agent_log_session_totals`,
		sessionTotalsView00125(ownerTurns00125),
	)
}

// addColumn00125 runs ddl unless the column exists; an existing one must be
// typ NOT NULL DEFAULT dflt.
func addColumn00125(ctx context.Context, tx *sql.Tx, name, ddl, typ, dflt string) error {
	var gotType string
	var notNull int
	var gotDflt sql.NullString
	err := tx.QueryRowContext(ctx,
		`SELECT type, "notnull", dflt_value FROM pragma_table_info('agent_log_events') WHERE name = ?`,
		name).Scan(&gotType, &notNull, &gotDflt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		if _, err := tx.ExecContext(ctx, ddl); err != nil {
			return fmt.Errorf("adding agent_log_events.%s: %w", name, err)
		}
		return nil
	case err != nil:
		return fmt.Errorf("checking agent_log_events.%s: %w", name, err)
	case gotType != typ || notNull != 1 || !gotDflt.Valid || gotDflt.String != dflt:
		return fmt.Errorf("agent_log_events.%s already exists as %s (notnull=%d, default %q); "+
			"migration 00125 needs %s NOT NULL DEFAULT %s", name, gotType, notNull, gotDflt.String, typ, dflt)
	}
	return nil
}

func down00125(ctx context.Context, tx *sql.Tx) error {
	return execAll(ctx, tx,
		`DROP VIEW agent_log_session_totals`,
		sessionTotalsView00125(`SUM(CASE WHEN kind = 'owner_turn' THEN 1 ELSE 0 END)`),
		`ALTER TABLE agent_log_events DROP COLUMN background`,
		`ALTER TABLE agent_log_events DROP COLUMN spawned_agent_id`,
	)
}

func execAll(ctx context.Context, tx *sql.Tx, stmts ...string) error {
	for _, s := range stmts {
		if _, err := tx.ExecContext(ctx, s); err != nil {
			return fmt.Errorf("executing %q: %w", firstLine(s), err)
		}
	}
	return nil
}
