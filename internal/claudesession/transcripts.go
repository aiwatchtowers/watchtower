package claudesession

import (
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/terminal"
)

// LatestSubagentWrite returns the newest mtime among the session's subagent
// transcripts, <config dir>/projects/*/<session id>/subagents/agent-*.jsonl.
// The project folder is globbed, not derived from the cwd, so Claude Code's
// folder-name escaping is never re-implemented. An id that is not a session
// id (a path escape) or no transcript at all is (_, false).
func LatestSubagentWrite(configDir, sessionID string) (time.Time, bool) {
	if !terminal.IsSessionID(sessionID) || configDir == "" {
		return time.Time{}, false
	}
	matches, _ := filepath.Glob(filepath.Join(configDir, "projects", "*", sessionID, "subagents", "agent-*.jsonl"))
	var latest time.Time
	for _, m := range matches {
		info, err := os.Lstat(m)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		if info.ModTime().After(latest) {
			latest = info.ModTime()
		}
	}
	return latest, !latest.IsZero()
}
