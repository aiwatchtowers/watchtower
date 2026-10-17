package db

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/pressly/goose/v3"
)

// Migration 00125 (agent analytics parser v2, #298) is a Go migration so it
// tolerates columns that already exist: an earlier dev build added
// agent_log_events.spawned_agent_id and background outside goose, and on
// such a database the plain ALTERs failed with "duplicate column" and the
// file never opened again (#667). Each column is added only when
// pragma_table_info lacks it; the statements are the ones the SQL file ran,
// so the resulting schema is unchanged. SQLite has no ADD COLUMN IF NOT
// EXISTS.
func init() {
	goose.AddNamedMigrationContext("00125_agent_analytics_history.go", up00125, down00125)
}

var columns00125 = []struct{ name, ddl string }{
	{"spawned_agent_id", `ALTER TABLE agent_log_events ADD COLUMN spawned_agent_id TEXT NOT NULL DEFAULT ''`},
	{"background", `ALTER TABLE agent_log_events ADD COLUMN background INTEGER NOT NULL DEFAULT 0`},
}

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
		var n int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM pragma_table_info('agent_log_events') WHERE name = ?`, c.name).Scan(&n); err != nil {
			return fmt.Errorf("checking agent_log_events.%s: %w", c.name, err)
		}
		if n > 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, c.ddl); err != nil {
			return fmt.Errorf("adding agent_log_events.%s: %w", c.name, err)
		}
	}
	return execAll(ctx, tx,
		`DROP VIEW agent_log_session_totals`,
		sessionTotalsView00125(`SUM(CASE WHEN kind = 'owner_turn' AND trigger NOT IN ('notification','hook') THEN 1 ELSE 0 END)`),
	)
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
			return err
		}
	}
	return nil
}
