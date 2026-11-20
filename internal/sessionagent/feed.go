package sessionagent

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// SessionRead is one ReadSession pass: the feed's entries, the live
// snapshot of the conversation read (nil with LiveErr set when it failed,
// nil and no error when the session has no conversation yet) and every file
// and directory the pass read, absolute and without repeats (a watcher of
// them sees every change the next pass would reflect).
type SessionRead struct {
	Entries []sessionfeed.Entry
	Live    *sessionfeed.Live
	LiveErr error
	Paths   []string
}

// ReadSession is the entries of `workbench session-feed --session S --json`
// read whole (no cursor), or with toolUseID set those of `--subagent T`,
// with that output's live snapshot (`live`; the subagent's own sidechain for
// T) and read paths (`paths`) taken at now: the hub's session_chat slice
// reads a session with it. The session's conversations come from its
// agent's adapter. A missing session wraps db.ErrTerminalSessionNotFound; a
// shell session is refused. A failed live read is LiveErr, never the error.
func ReadSession(ctx context.Context, d *db.DB, sessionID int64, toolUseID string, dirs sessionfeed.Dirs, now time.Time) (SessionRead, error) {
	sess, err := LoadSession(d, sessionID)
	if err != nil {
		return SessionRead{}, fmt.Errorf("session %d: %w", sessionID, err)
	}
	a, ok := Of(sess.Kind)
	if !ok {
		return SessionRead{}, fmt.Errorf("session %d is not an agent session", sessionID)
	}
	convs, err := a.Conversations(ctx, d, sessionID, sess.FolderPath, sess.TranscriptPath.String, dirs)
	if err != nil {
		return SessionRead{}, err
	}
	if toolUseID != "" {
		res, path, reads, err := sessionfeed.FindSubagentReads(convs, toolUseID)
		if err != nil {
			return SessionRead{}, err
		}
		codex := strings.HasPrefix(toolUseID, "codex:")
		live, liveErr := sessionfeed.LiveOf(sessionfeed.Conversation{
			Path: path, Codex: codex, AgentSessionID: strings.TrimPrefix(toolUseID, "codex:"),
		}, !codex, now)
		return SessionRead{Entries: res.Entries, Live: live, LiveErr: liveErr, Paths: readPaths([]string{path}, live.Paths(), reads)}, nil
	}
	var lookup sessionfeed.AskLookup
	if sess.WorkbenchID.Valid {
		lookup = sessionfeed.AskLookupFor(d, sess.WorkbenchID.Int64)
	}
	feed, err := sessionfeed.Build(convs, nil, lookup)
	if err != nil {
		return SessionRead{}, err
	}
	out := SessionRead{Entries: feed.Entries}
	if len(convs) > 0 {
		out.Live, out.LiveErr = sessionfeed.LiveOf(convs[len(convs)-1], false, now)
	}
	out.Paths = readPaths(feed.Paths, out.Live.Paths())
	return out, nil
}

// readPaths joins read lists in order, absolute and without repeats
// (`session-feed --json`'s paths).
func readPaths(lists ...[]string) []string {
	var out []string
	seen := map[string]bool{}
	for _, l := range lists {
		for _, p := range l {
			if abs, err := filepath.Abs(p); err == nil {
				p = abs
			}
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out
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
