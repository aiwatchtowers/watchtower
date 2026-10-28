package llmusage

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// SpoolPath is the workspace spool every non-daemon process appends its
// calls to; the daemon imports it into llm_calls.
func SpoolPath(dir string) string { return filepath.Join(dir, "llm_calls.spool.jsonl") }

// LockSpool takes the exclusive flock on path's sidecar lock file (path +
// ".lock", created 0600, its directory 0700 when missing — a fresh install
// has no data root yet), blocking until it is free. An append and the
// daemon's rename-for-import both hold it, so no appended line is lost.
func LockSpool(path string) (unlock func(), err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("creating spool directory: %w", err)
	}
	f, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("opening spool lock: %w", err)
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("locking spool: %w", err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

// appendSpool writes c as one JSON line to the spool under its lock.
func appendSpool(path string, c Call) error {
	line, err := json.Marshal(c)
	if err != nil {
		return err
	}
	unlock, err := LockSpool(path)
	if err != nil {
		return err
	}
	defer unlock()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(append(line, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// ImportingSuffix marks the spool file the daemon has claimed for import.
const ImportingSuffix = ".importing"

// ReadSpool returns the calls in path+ImportingSuffix and path, in that
// order, without moving or locking either (the read-only `usage llm` view).
// Missing files are empty; malformed lines are skipped.
func ReadSpool(path string) ([]Call, error) {
	var out []Call
	for _, p := range []string{path + ImportingSuffix, path} {
		calls, _, err := ParseSpoolFile(p)
		if err != nil {
			return nil, err
		}
		out = append(out, calls...)
	}
	return out, nil
}

// ParseSpoolFile reads one spool file: the calls of its well-formed lines
// and the number of malformed lines skipped (a torn last line included). A
// missing file is empty, not an error.
func ParseSpoolFile(path string) (calls []Call, skipped int, err error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, fmt.Errorf("opening spool: %w", err)
	}
	defer f.Close()
	r := bufio.NewReader(f)
	for {
		line, rerr := r.ReadBytes('\n')
		if line = bytes.TrimSpace(line); len(line) > 0 {
			var c Call
			if json.Unmarshal(line, &c) == nil && c.CallID != "" {
				calls = append(calls, c)
			} else {
				skipped++
			}
		}
		if errors.Is(rerr, io.EOF) {
			return calls, skipped, nil
		}
		if rerr != nil {
			return nil, 0, fmt.Errorf("reading spool: %w", rerr)
		}
	}
}
