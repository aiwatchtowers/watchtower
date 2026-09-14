package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"watchtower/internal/config"
)

// rotatingFile is the daemon logger's sink: an appending file that rotates
// itself once it grows past maxSize, instead of only at the next daemon
// start. A tray-launched daemon can run for weeks, so an open-time check
// alone leaves growth bounded by uptime rather than by the cap.
//
// It rotates the file the process opens ITSELF (watchtower.log). daemon.log
// cannot be bounded this way at all: the detached child receives it as an
// inherited descriptor from a parent that has already exited, so renaming
// that path leaves the child appending to the renamed inode. Keeping the
// logger off daemon.log (see logWriterFor) is what makes this possible.
//
// The size is tracked with an in-process byte counter rather than a stat per
// write: the logger is written from several goroutines (the sync heartbeat
// plus every phase), so the writer needs the mutex regardless and the counter
// then costs nothing. It is seeded from the file already on disk so a daemon
// restarting onto a nearly-full log still rotates promptly.
type rotatingFile struct {
	mu      sync.Mutex
	path    string
	maxSize int64
	f       *os.File
	n       int64 // bytes in the current generation, including what was there at open
}

// newRotatingFile opens path for appending and returns a writer that keeps it
// under maxSize. The caller owns the returned writer and must Close it.
func newRotatingFile(path string, maxSize int64) (*rotatingFile, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("opening log file: %w", err)
	}
	// Seed the counter from what is already on disk, so a daemon restarting
	// onto a nearly-full log rotates on its next write rather than a whole
	// cap later. A Stat failure on a descriptor just opened is close to
	// unreachable, but swallowing it would silently start the counter at zero
	// — exactly the bug the seeding exists to prevent — so it is reported
	// through the caller's error path instead.
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("sizing log file %s: %w", path, err)
	}
	return &rotatingFile{path: path, maxSize: maxSize, f: f, n: info.Size()}, nil
}

// newSyncLogWriter opens the daemon's own log stream, watchtower.log, behind
// a rotatingFile. This is the only construction site outside tests, so the
// file it names is the one that gets bounded.
func newSyncLogWriter(cfg *config.Config) (*rotatingFile, error) {
	syncLog := syncLogFilePath(cfg)
	if err := os.MkdirAll(filepath.Dir(syncLog), 0o755); err != nil {
		return nil, fmt.Errorf("creating log directory: %w", err)
	}
	return newRotatingFile(syncLog, maxLogSize)
}

func (r *rotatingFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	n, err := r.f.Write(p)
	r.n += int64(n)
	if err != nil {
		return n, err
	}
	if r.n <= r.maxSize {
		return n, nil
	}
	if rotErr := r.rotate(); rotErr != nil {
		// Rotation must never block a sync (rotateLogIfOversized's contract):
		// keep appending to the file we still hold, say so in that file, and
		// reset the counter so the next attempt comes a full cap later rather
		// than on every single line.
		fmt.Fprintf(r.f, "%s log rotation: %v (continuing without rotation)\n",
			time.Now().Format("2006/01/02 15:04:05"), rotErr)
		r.n = 0
	}
	return n, nil
}

// rotate renames the current generation aside and starts a fresh file.
//
// The new file is opened BEFORE the old handle is closed, deliberately: a
// close-then-reopen order that fails at the reopen would leave the logger
// holding a closed descriptor and silently drop every later line. Renaming an
// open file is fine on POSIX — the old handle keeps pointing at the renamed
// inode until it is swapped out here.
func (r *rotatingFile) rotate() error {
	if err := rotateLogIfLargerThan(r.path, r.maxSize); err != nil {
		return err
	}
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("reopening %s: %w", r.path, err)
	}
	_ = r.f.Close()
	r.f = f
	r.n = 0
	return nil
}

func (r *rotatingFile) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.f.Close()
}

// logWriterFor decides where the daemon's logger writes. The log file always
// gets every line; os.Stderr is added only under --verbose.
//
// The detached flag is accepted and deliberately ignored: it used to add
// stderr too, but a detached child's stdout and stderr ARE daemon.log
// (runSyncDetach hands the child that file), so every line landed in both
// files byte for byte. watchtower.log is now the one log stream and daemon.log
// keeps its distinct role as the stderr channel — Go runtime panics, the
// parent's rotation note, and whatever still logs to stderr instead of through
// this logger (the stdlib default logger, the Jira sub-loggers; see
// docs/backlog/2026-09-14-stray-loggers-still-write-to-daemon-log.md). Passing
// the flag keeps that decision visible at the call site and gives the guard
// test the case to pin.
//
// `--verbose --detach` still duplicates: that is the operator asking for it.
func logWriterFor(logFile io.Writer, verbose, detached bool) io.Writer {
	_ = detached
	if verbose {
		return io.MultiWriter(logFile, os.Stderr)
	}
	return logFile
}
