package sessionhost

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// The codex rollout watch (spec 2026-11-05 §3.5, decision C, board #972):
// Codex fires no Stop on a failed turn and has no StopFailure hook, so the
// session host — which owns the terminal and outlives the app — reads each
// hosted codex session's rollout while its row reads `working`, and writes
// the failure (PROJ-11's Error state) or the interrupt (`waiting`) through
// the hooks' own write path. When it cannot read the rollout it marks the
// row not watched instead of leaving a silent `working`.

// CodexWatchEvery is how often a watch stats its rollout.
const CodexWatchEvery = 2 * time.Second

// CodexMissingGiveUp is how long a rollout may be missing before the row is
// marked not watched (`missing`); the app's bridge uses it too.
const CodexMissingGiveUp = 30 * time.Second

// codexUnreadableTicks is how many ticks in a row with an undecodable tail
// mark the row not watched (`unreadable`).
const codexUnreadableTicks = 3

// CodexUnreadableGiveUp is how long an unchanged rollout with an
// undecodable tail lasts before the row is marked not watched: the watch's
// codexUnreadableTicks, for the app's bridge, which keeps no ticks.
const CodexUnreadableGiveUp = codexUnreadableTicks * CodexWatchEvery

// CodexWatchStore is the database side of a watch: the row it reads each
// tick and the two writes. RecordTurn writes a failed or aborted turn the
// way the hooks do (recordAgentState, only over `working`, stamped with the
// rollout line's time); SetIssue is db.SetAgentWatchIssue (false on a
// repeat or when a guard held it back). Close releases the store when the
// session ends.
type CodexWatchStore interface {
	Row(id int64) (db.CodexWatchRow, error)
	RecordTurn(row db.CodexWatchRow, turn sessionfeed.CodexTurn) error
	SetIssue(id int64, issue string, at time.Time) (bool, error)
	Close() error
}

// CodexWatch is one hosted codex session's rollout watch.
type CodexWatch struct {
	row       int64
	store     CodexWatchStore
	codexHome string
	logf      func(format string, args ...any)
	locate    func(codexHome, sessionID, storedPath string) (string, bool)
	read      func(path string) (sessionfeed.CodexTurn, error)

	// arm is reset whenever the row stops reading `working`, its issue
	// clears or its transcript path changes.
	arm codexArm
	// logged holds the database errors already logged, by what failed:
	// one line each for the watch's life.
	logged map[string]bool
}

// codexArm is one arm's state of a CodexWatch.
type codexArm struct {
	armed        bool
	storedPath   string // the row's agent_transcript_path this arm follows
	path         string // the file read: storedPath, or what LocateCodex found
	located      bool   // LocateCodex was tried this arm
	missingSince time.Time
	file         fileStamp // the file as last read; zero = never read
	clean        bool      // the last read was complete: an unchanged file is not read again
	undecodable  int       // ticks in a row with an undecodable tail or a failed read
	lastTurnAt   time.Time // the newest failed/aborted turn the store took
}

// fileStamp is what tells a rollout changed between two ticks.
type fileStamp struct {
	ino  uint64
	size int64
	mod  time.Time
}

// NewCodexWatch is the watch of terminal session row over store, reading
// rollouts under codexHome and logging through logf.
func NewCodexWatch(row int64, store CodexWatchStore, codexHome string, logf func(string, ...any)) *CodexWatch {
	return &CodexWatch{row: row, store: store, codexHome: codexHome, logf: logf,
		locate: sessionfeed.LocateCodex, read: sessionfeed.CodexLastTurn, logged: map[string]bool{}}
}

// run ticks every interval until ctx ends or the row is gone, then closes
// the store.
func (w *CodexWatch) run(ctx context.Context, every time.Duration, now func() time.Time) {
	defer func() {
		if err := w.store.Close(); err != nil {
			w.logf("session-host: codex watch: session %d: closing the database: %v", w.row, err)
		}
	}()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if w.Tick(now()) {
				return
			}
		}
	}
}

// disarm forgets the arm's state.
func (w *CodexWatch) disarm() { w.arm = codexArm{} }

// Tick is one step of §3.5's table at now; done is true once the row is
// gone (or is no codex row), and the watch ends.
func (w *CodexWatch) Tick(now time.Time) (done bool) {
	r, err := w.store.Row(w.row)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return true
	}
	if err != nil {
		w.logOnce("reading the row", err)
		return false
	}
	if !agentkind.SessionCapsOf(r.Kind).RolloutWatch {
		return true
	}
	if r.State != "working" || r.Finished || r.Failed || r.WatchIssue != "" || r.TranscriptPath == "" || r.SessionID == "" {
		w.disarm() // not armed: hooks alone drive the row; armed again when it works
		return false
	}
	if !w.arm.armed || r.TranscriptPath != w.arm.storedPath {
		w.disarm()
		w.arm.armed, w.arm.storedPath, w.arm.path = true, r.TranscriptPath, r.TranscriptPath
	}
	st, err := os.Stat(w.arm.path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		w.missing(r, now)
		return false
	case errors.Is(err, fs.ErrPermission):
		w.giveUp(db.WatchIssuePermission, now)
		return false
	case err != nil:
		w.unreadableTick(now)
		return false
	}
	w.arm.missingSince = time.Time{}
	stamp := stampOf(st)
	if w.arm.file != (fileStamp{}) && (stamp.ino != w.arm.file.ino || stamp.size < w.arm.file.size) {
		// Rotated: replaced or rewritten shorter. Read it from the start.
		w.arm.file, w.arm.clean, w.arm.undecodable, w.arm.lastTurnAt = fileStamp{}, false, 0, time.Time{}
	}
	if w.arm.clean && stamp == w.arm.file {
		return false
	}
	w.readTurn(r, stamp, now)
	return false
}

// missing is a tick with no file: one LocateCodex per arm, then the 30 s
// give-up.
func (w *CodexWatch) missing(r db.CodexWatchRow, now time.Time) {
	if w.arm.missingSince.IsZero() {
		w.arm.missingSince = now
	}
	if !w.arm.located {
		w.arm.located = true
		if p, ok := w.locate(w.codexHome, r.SessionID, r.TranscriptPath); ok && p != w.arm.path {
			w.arm.path, w.arm.file, w.arm.clean = p, fileStamp{}, false
			return
		}
	}
	if now.Sub(w.arm.missingSince) >= CodexMissingGiveUp {
		w.giveUp(db.WatchIssueMissing, now)
	}
}

func (w *CodexWatch) readTurn(r db.CodexWatchRow, stamp fileStamp, now time.Time) {
	turn, err := w.read(w.arm.path)
	var wi *sessionfeed.WatchIssueError
	if errors.As(err, &wi) {
		switch wi.Issue {
		case db.WatchIssuePermission, db.WatchIssueCompressed:
			w.giveUp(wi.Issue, now)
		case db.WatchIssueMissing:
			w.missing(r, now)
		default:
			w.unreadableTick(now)
		}
		return
	}
	if err != nil {
		w.unreadableTick(now)
		return
	}
	w.arm.file = stamp
	if turn.TailUndecodable {
		w.arm.clean = false
		w.unreadableTick(now)
	} else {
		w.arm.clean, w.arm.undecodable = true, 0
	}
	if !turn.Failed && !turn.Aborted {
		return
	}
	if turn.At.IsZero() {
		// A turn that ended with no readable time cannot be ordered against
		// the row's state, so it is never written: the row is not watched.
		w.giveUp(db.WatchIssueUnreadable, now)
		return
	}
	if !turn.At.After(w.arm.lastTurnAt) {
		return
	}
	if err := w.store.RecordTurn(r, turn); err != nil {
		w.logOnce("recording the turn", err)
		w.arm.clean = false // read again next tick: the write is retried
		return
	}
	w.arm.lastTurnAt = turn.At
}

func (w *CodexWatch) unreadableTick(now time.Time) {
	w.arm.undecodable++
	if w.arm.undecodable >= codexUnreadableTicks {
		w.giveUp(db.WatchIssueUnreadable, now)
	}
}

// giveUp marks the row not watched; one log line per row and issue, with
// the row id and the class only (FILES-01). A stored verdict ends the arm:
// a hook may clear the issue before the next tick, and the next prompt then
// starts a fresh arm, never this one's expired grace.
func (w *CodexWatch) giveUp(issue string, now time.Time) {
	ok, err := w.store.SetIssue(w.row, issue, now)
	if err != nil {
		w.logOnce("marking the row not watched", err)
		return
	}
	w.disarm()
	if ok {
		w.logf("session-host: codex watch: session %d not watched (%s)", w.row, issue)
	}
}

// logOnce logs an error once per what for the watch's life. The error is
// the database's, never the rollout's (a rollout read failure is a class,
// not a message).
func (w *CodexWatch) logOnce(what string, err error) {
	if w.logged[what] {
		return
	}
	w.logged[what] = true
	w.logf("session-host: codex watch: session %d: %s: %v", w.row, what, err)
}

func stampOf(st os.FileInfo) fileStamp {
	s := fileStamp{size: st.Size(), mod: st.ModTime()}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		s.ino = uint64(sys.Ino) //nolint:unconvert // Ino's width differs by platform
	}
	return s
}

// codexHomeOf is the launch's Codex home: CODEX_HOME from its environment
// when absolute (Codex's own rule), else ~/.codex.
func codexHomeOf(env []string) string {
	for i := len(env) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(env[i], "CODEX_HOME="); ok {
			if filepath.IsAbs(v) {
				return v
			}
			break
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

// DBWatchStore is the CodexWatchStore over a workspace database: the row
// read and the not-watched write are the db package's; RecordTurn is the
// caller's (the hooks' write path lives in cmd), and Close closes DB.
type DBWatchStore struct {
	DB     *db.DB
	Record func(d *db.DB, row db.CodexWatchRow, turn sessionfeed.CodexTurn) error
}

// Row reads the row for the watch.
func (s *DBWatchStore) Row(id int64) (db.CodexWatchRow, error) { return s.DB.GetCodexWatchRow(id) }

// RecordTurn writes a failed or aborted turn through Record.
func (s *DBWatchStore) RecordTurn(row db.CodexWatchRow, turn sessionfeed.CodexTurn) error {
	return s.Record(s.DB, row, turn)
}

// SetIssue marks the row not watched (db.SetAgentWatchIssue).
func (s *DBWatchStore) SetIssue(id int64, issue string, at time.Time) (bool, error) {
	return s.DB.SetAgentWatchIssue(id, issue, at)
}

// Close closes the database.
func (s *DBWatchStore) Close() error { return s.DB.Close() }
