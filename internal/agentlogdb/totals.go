package agentlogdb

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// OpenExisting opens the agentlog.db at path for a read-only caller (`usage
// llm`): no directory, file or migration is created, and a statement that
// writes fails (db.OpenExisting). A statement waits at most busy for a lock.
func OpenExisting(path string, busy time.Duration) (*DB, error) {
	d, err := db.OpenExisting(path, busy)
	if err != nil {
		return nil, err
	}
	return &DB{d.DB}, nil
}

// Totals is the agent sessions' API usage in a period: Sessions counts the
// sessions with at least one API call in it; Unpriced counts the calls whose
// model had no price (cost_estimated: their cost_usd is 0, so CostUSD is a
// lower bound when it is above zero).
type Totals struct {
	Sessions, Calls, Unpriced, Input, CacheRead, CacheWrite, Output int64
	CostUSD                                                         float64
}

// eventTSLayout formats a bound for agent_log_events.ts, which keeps Claude
// Code's millisecond timestamps ("…T10:00:00.123Z"): a whole-second bound
// written as "…T10:00:00Z" would sort after them.
const eventTSLayout = "2006-01-02T15:04:05.000Z"

// TotalsSince sums the API calls made at or after since in the sessions of
// the given workbenches; no workbench is a zero total.
func (d *DB) TotalsSince(since time.Time, projectIDs []int64) (Totals, error) {
	var t Totals
	if len(projectIDs) == 0 {
		return t, nil
	}
	args := []any{since.UTC().Format(eventTSLayout)}
	for _, id := range projectIDs {
		args = append(args, id)
	}
	q := `SELECT COUNT(DISTINCT e.session_uuid), COUNT(*), COALESCE(SUM(e.cost_estimated), 0),
		COALESCE(SUM(e.input_tokens), 0), COALESCE(SUM(e.cache_read_tokens), 0),
		COALESCE(SUM(e.cache_write_5m_tokens + e.cache_write_1h_tokens), 0),
		COALESCE(SUM(e.output_tokens), 0), COALESCE(SUM(e.cost_usd), 0)
		FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
		WHERE e.kind = 'api_call' AND e.ts >= ?
		AND s.project_id IN (?` + strings.Repeat(",?", len(projectIDs)-1) + `)`
	if err := d.QueryRow(q, args...).Scan(&t.Sessions, &t.Calls, &t.Unpriced, &t.Input, &t.CacheRead,
		&t.CacheWrite, &t.Output, &t.CostUSD); err != nil {
		return Totals{}, fmt.Errorf("agent log totals: %w", err)
	}
	return t, nil
}
