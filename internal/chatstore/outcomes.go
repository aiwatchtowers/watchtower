package chatstore

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const outcomesHeader = "=== ACTIONS SINCE YOUR LAST MESSAGE ==="

// outcomesBlockTx is AgentActionFeed.outcomesBlock(after:): the conversation's
// proposals decided or applied at or after the previous owner message
// (after, Unix seconds, truncated to the second as the Mac's formatter
// writes it), rendered for the model; "" when nothing changed. The shared
// fixture testdata/outcomes_block_cases.json pins it against
// AgentActionQueries.fetchDecidedAfter + AgentToolsContract.actionsSinceLastTurnBlock.
func outcomesBlockTx(tx *sql.Tx, conv int64, after float64) (string, error) {
	floor := outcomesFloor(after)
	rows, err := tx.Query(`SELECT id, tool, status, result_json, error FROM agent_actions
		WHERE conversation_id = ? AND (decided_at >= ? OR applied_at >= ?)
		ORDER BY created_at ASC, id ASC`, conv, floor, floor)
	if err != nil {
		return "", fmt.Errorf("reading action outcomes: %w", err)
	}
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var id int64
		var tool, status, result, failure string
		if err := rows.Scan(&id, &tool, &status, &result, &failure); err != nil {
			return "", fmt.Errorf("reading action outcomes: %w", err)
		}
		line := "- #" + strconv.FormatInt(id, 10) + " " + tool + ": " + status
		if status == "applied" && result != "" {
			line += " — " + result
		} else if failure != "" {
			line += " — " + failure
		}
		lines = append(lines, line)
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("reading action outcomes: %w", err)
	}
	if len(lines) == 0 {
		return "", nil
	}
	return outcomesHeader + "\n" + strings.Join(lines, "\n"), nil
}

// outcomesFloor is AgentActionFeed.timestampString: UTC, whole seconds.
func outcomesFloor(after float64) string {
	sec := int64(after)
	if float64(sec) > after { // floor, not toward zero, for a pre-1970 value
		sec--
	}
	return time.Unix(sec, 0).UTC().Format("2006-01-02T15:04:05Z")
}
