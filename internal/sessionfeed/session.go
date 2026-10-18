package sessionfeed

import (
	"context"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
)

// Dirs are where the agents keep their transcripts: Claude Code's projects
// directory (~/.claude/projects) and the Codex home.
type Dirs struct{ ClaudeProjects, CodexHome string }

// SessionConversations lists the conversations of terminal session id in
// ledger order whose transcripts exist. codex reads Codex rollouts, with
// storedPath the transcript path its hook reported; otherwise Claude Code
// transcripts are searched under folder and its git worktrees.
func SessionConversations(ctx context.Context, d *db.DB, id int64, codex bool, folder, storedPath string, dirs Dirs) ([]Conversation, error) {
	ledger, err := d.ListTerminalAgentSessions(id)
	if err != nil {
		return nil, err
	}
	var convs []Conversation
	if codex {
		for _, l := range ledger {
			if p, ok := LocateCodex(dirs.CodexHome, l.AgentSessionID, storedPath); ok {
				convs = append(convs, Conversation{AgentSessionID: l.AgentSessionID, Path: p, Codex: true})
			}
		}
		return convs, nil
	}
	roots := append([]string{folder}, agentlog.WorktreeRoots(ctx, folder)...)
	ids := make([]string, 0, len(ledger))
	for _, l := range ledger {
		ids = append(ids, l.AgentSessionID)
	}
	located := LocateAll(dirs.ClaudeProjects, roots, ids)
	for _, l := range ledger {
		if p, ok := located[l.AgentSessionID]; ok {
			convs = append(convs, Conversation{AgentSessionID: l.AgentSessionID, Path: p})
		}
	}
	return convs, nil
}
