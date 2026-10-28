package llmusage

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// SpoolPath is the workspace spool every non-daemon process appends its
// calls to; the daemon imports it into llm_calls.
func SpoolPath(dir string) string { return filepath.Join(dir, "llm_calls.spool.jsonl") }

// LockSpool takes the exclusive flock on path's sidecar lock file (path +
// ".lock", created 0600), blocking until it is free. An append and the
// daemon's rename-for-import both hold it, so no appended line is lost.
func LockSpool(path string) (unlock func(), err error) {
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
