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

// LoadSession is terminal_sessions row id with its stored transcript path
// when the row's agent keeps the path its SessionStart reported
// (Adapter.StoresTranscriptPath): Codex's rows; a Claude row's readers find
// the transcript by id, and a shell has none. A missing row is
// db.ErrTerminalSessionNotFound.
func LoadSession(d *db.DB, id int64) (*db.TerminalSession, error) {
	s, err := d.GetTerminalSession(id)
	if err != nil {
		return nil, err
	}
	if a, ok := Of(s.Kind); ok && a.StoresTranscriptPath() {
		if s.TranscriptPath, err = d.TerminalTranscriptPath(id); err != nil {
			return nil, err
		}
	}
	return s, nil
}
