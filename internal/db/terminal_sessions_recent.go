package db

import (
	"database/sql"
	"fmt"
	"time"
)

// RecentWorkbenchSession is an agent terminal session of a workbench, as the
// instruction-suggestion miner reads it. AgentSessionID and TranscriptPath
// are "" when NULL.
type RecentWorkbenchSession struct {
	ID, WorkbenchID                                  int64
	Kind, FolderPath, AgentSessionID, TranscriptPath string
}

// ListWorkbenchTerminalSessionsSince lists the agent sessions (claude, codex)
// bound to a workbench and active at or after since, oldest id first.
func (db *DB) ListWorkbenchTerminalSessionsSince(since time.Time) ([]RecentWorkbenchSession, error) {
	rows, err := db.Query(`SELECT id, project_id, kind, folder_path, claude_session_id, agent_transcript_path
		FROM terminal_sessions
		WHERE project_id IS NOT NULL AND kind IN ('claude','codex') AND last_active_at >= ?
		ORDER BY id`, since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("listing recent workbench sessions: %w", err)
	}
	defer rows.Close()
	var out []RecentWorkbenchSession
	for rows.Next() {
		var s RecentWorkbenchSession
		var sid, path sql.NullString
		if err := rows.Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.FolderPath, &sid, &path); err != nil {
			return nil, fmt.Errorf("scanning recent workbench session: %w", err)
		}
		s.AgentSessionID, s.TranscriptPath = sid.String, path.String
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing recent workbench sessions: %w", err)
	}
	return out, nil
}
