package sessionagent

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// SessionRead is one ReadSession pass: the feed's entries, the live
// snapshot of the conversation read (nil with LiveErr set when that read
// failed or passed liveReadTimeout; nil and no error when there is no
// conversation or its file does not exist yet) and every file and directory
// the pass read, absolute and without repeats (a watcher of them sees every
// change the next pass would reflect).
type SessionRead struct {
	Entries []sessionfeed.Entry
	Live    *sessionfeed.Live
	LiveErr error
	Paths   []string
}

// liveReadTimeout bounds the live snapshot inside a ReadSession pass, so a
// stalled one still returns the fresh entries (with LiveErr).
const liveReadTimeout = 10 * time.Second

// errLiveTimedOut is LiveErr of a snapshot that passed liveReadTimeout.
var errLiveTimedOut = errors.New("live snapshot timed out")

// liveOf takes the live snapshot (a test seam).
var liveOf = sessionfeed.LiveOf

// ReadSession is the entries of `workbench session-feed --session S --json`
// read whole (no cursor), or with toolUseID set those of `--subagent T`,
// with that output's live snapshot (`live`; the subagent's own sidechain for
// T) and read paths (`paths`) taken at now — the same sessionfeed.ReadChat
// the CLI runs. The hub's session_chat slice reads a session with it. The
// session's conversations come from its agent's adapter. A missing session
// wraps db.ErrTerminalSessionNotFound; a shell session is refused. A failed
// live read is LiveErr, never the error.
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
	var lookup sessionfeed.AskLookup
	if toolUseID == "" && sess.WorkbenchID.Valid {
		lookup = sessionfeed.AskLookupFor(d, sess.WorkbenchID.Int64)
	}
	return readChat(ctx, convs, lookup, toolUseID, now)
}

// readChat is ReadSession past the session lookup.
func readChat(ctx context.Context, convs []sessionfeed.Conversation, lookup sessionfeed.AskLookup, toolUseID string, now time.Time) (SessionRead, error) {
	read, err := sessionfeed.ReadChat(convs, sessionfeed.ReadOptions{Asks: lookup, Subagent: toolUseID, Now: now, LiveOf: boundedLiveOf(ctx)})
	if err != nil {
		return SessionRead{}, err
	}
	out := SessionRead{Live: read.Live, LiveErr: read.LiveErr, Paths: read.Paths}
	if read.Subagent != nil {
		out.Entries = read.Subagent.Entries
	} else {
		out.Entries = read.Feed.Entries
	}
	if errors.Is(out.LiveErr, fs.ErrNotExist) {
		out.LiveErr = nil // a conversation not written yet: nothing to show, nothing failed
	}
	return out, nil
}

// liveInFlight is the conversations (path, sidechain) whose snapshot is
// still running, the stalled ones a pass gave up on included: one snapshot
// per conversation at most, so a stuck file system never piles up readers.
var liveInFlight = struct {
	sync.Mutex
	m map[string]bool
}{m: map[string]bool{}}

// boundedLiveOf is liveOf given up after liveReadTimeout or when ctx ends
// (the snapshot itself runs on, and its result is dropped). While a snapshot
// of the same conversation still runs, it starts none and returns
// errLiveTimedOut at once.
func boundedLiveOf(ctx context.Context) func(sessionfeed.Conversation, bool, time.Time) (*sessionfeed.Live, error) {
	read := liveOf
	return func(c sessionfeed.Conversation, sidechain bool, now time.Time) (*sessionfeed.Live, error) {
		key := strconv.FormatBool(sidechain) + ":" + c.Path
		liveInFlight.Lock()
		if liveInFlight.m[key] {
			liveInFlight.Unlock()
			return nil, errLiveTimedOut
		}
		liveInFlight.m[key] = true
		liveInFlight.Unlock()
		type result struct {
			live *sessionfeed.Live
			err  error
		}
		done := make(chan result, 1)
		go func() {
			l, err := read(c, sidechain, now)
			liveInFlight.Lock()
			delete(liveInFlight.m, key)
			liveInFlight.Unlock()
			done <- result{l, err}
		}()
		t := time.NewTimer(liveReadTimeout)
		defer t.Stop()
		select {
		case r := <-done:
			return r.live, r.err
		case <-t.C:
			return nil, errLiveTimedOut
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
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
