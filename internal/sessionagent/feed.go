package sessionagent

import (
	"context"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// ReadSession is the entries of `workbench session-feed --session S --json`
// read whole (no cursor), or with toolUseID set those of `--subagent T`: the
// one reader the CLI and the hub's session_chat slice share. The session's
// conversations come from its agent's adapter. A missing session wraps
// db.ErrTerminalSessionNotFound; a shell session is refused.
func ReadSession(ctx context.Context, d *db.DB, sessionID int64, toolUseID string, dirs sessionfeed.Dirs) ([]sessionfeed.Entry, error) {
	sess, err := LoadSession(d, sessionID)
	if err != nil {
		return nil, fmt.Errorf("session %d: %w", sessionID, err)
	}
	a, ok := Of(sess.Kind)
	if !ok {
		return nil, fmt.Errorf("session %d is not an agent session", sessionID)
	}
	convs, err := a.Conversations(ctx, d, sessionID, sess.FolderPath, sess.TranscriptPath.String, dirs)
	if err != nil {
		return nil, err
	}
	if toolUseID != "" {
		res, _, err := sessionfeed.FindSubagent(convs, toolUseID)
		if err != nil {
			return nil, err
		}
		return res.Entries, nil
	}
	var lookup sessionfeed.AskLookup
	if sess.WorkbenchID.Valid {
		lookup = sessionfeed.AskLookupFor(d, sess.WorkbenchID.Int64)
	}
	feed, err := sessionfeed.Build(convs, nil, lookup)
	if err != nil {
		return nil, err
	}
	return feed.Entries, nil
}
