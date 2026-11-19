package tower

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"

	"watchtower/internal/fsutil"
	"watchtower/internal/tower/api"
)

// pauseFile is the owner's pause, inside the workspace.
const pauseFile = "sync.paused"

// PausePath is the file that holds the owner's pause: <workspace>/sync.paused.
// The daemon alone writes it (sync.pause and sync.resume); present means
// paused. It is not in config.yaml, which the app also writes, so it has one
// writer and survives a restart.
func PausePath(workspace string) string {
	return filepath.Join(workspace, pauseFile)
}

// IsPaused reports whether the owner paused sync in workspace. A file that
// cannot be checked (anything but "not there") is logged and read as not
// paused: sync goes on, as it did before the pause existed.
func IsPaused(workspace string) bool {
	_, err := os.Stat(PausePath(workspace))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		log.Printf("tower: reading the sync pause: %v (sync not held)", err)
	}
	return err == nil
}

// SetPaused pauses sync in workspace (writes the file: temp file and rename,
// mode 0600) or resumes it (removes the file; a missing one is fine).
func SetPaused(workspace string, paused bool) error {
	path := PausePath(workspace)
	if paused {
		return fsutil.WriteFileAtomic(path, []byte("paused\n"), 0o600)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("tower: removing %s: %w", pauseFile, err)
	}
	return nil
}

// RegisterPause registers sync.pause and sync.resume: guarded writes over the
// pause file (no table changes). A pause stops new sync cycles, scheduled
// automation runs and the plan-usage poll; the socket, the hub and the Inbox
// keep running (internal/daemon reads it through Daemon.SetSyncPaused).
func RegisterPause(r *Registry) {
	for name, paused := range map[string]bool{"sync.pause": true, "sync.resume": false} {
		Register(r, name, func(_ context.Context, c *Ctx, _ api.PauseRequest) (api.PauseResponse, error) {
			return c.tower.setPaused(paused)
		}, Spec{Idempotent: true})
	}
}

func (t *Tower) setPaused(paused bool) (api.PauseResponse, error) {
	if t.opts.Workspace == "" {
		return api.PauseResponse{}, Refuse(api.CodeUnsupported, "This Watchtower can't pause sync.")
	}
	if err := SetPaused(t.opts.Workspace, paused); err != nil {
		log.Printf("tower: %v", err)
		verb := "resume"
		if paused {
			verb = "pause"
		}
		return api.PauseResponse{}, Refuse(api.CodeUnsupported,
			fmt.Sprintf("Watchtower couldn't %s sync: its workspace folder isn't writable.", verb))
	}
	return api.PauseResponse{Paused: paused}, nil
}
