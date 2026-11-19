package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/fsutil"
)

// StoppedMarkerName is the workspace file that says the owner stopped the
// daemon on purpose (`watchtower sync stop`, unified chat spec §7, D11):
// the chat client then shows "stopped" with Start instead of starting the
// daemon itself. Every daemon start removes it first.
const StoppedMarkerName = "daemon.stopped"

// StoppedMarker is the marker's one JSON line.
type StoppedMarker struct {
	At time.Time `json:"at"` // RFC 3339
	By string    `json:"by"` // "cli"
}

func stoppedMarkerPath(workspaceDir string) string {
	return filepath.Join(workspaceDir, StoppedMarkerName)
}

// WriteStoppedMarker writes <workspace>/daemon.stopped (0600, one JSON
// line), replacing an older one.
func WriteStoppedMarker(workspaceDir string, at time.Time, by string) error {
	b, err := json.Marshal(StoppedMarker{At: at.UTC().Truncate(time.Second), By: by})
	if err != nil {
		return fmt.Errorf("encoding the stopped marker: %w", err)
	}
	if err := fsutil.WriteFileAtomic(stoppedMarkerPath(workspaceDir), append(b, '\n'), 0o600); err != nil {
		return fmt.Errorf("writing the stopped marker: %w", err)
	}
	return nil
}

// RemoveStoppedMarker removes the marker; an absent one is no error.
func RemoveStoppedMarker(workspaceDir string) error {
	if err := os.Remove(stoppedMarkerPath(workspaceDir)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("removing the stopped marker: %w", err)
	}
	return nil
}

// ReadStoppedMarker reads the marker; ok is false when there is none.
func ReadStoppedMarker(workspaceDir string) (StoppedMarker, bool, error) {
	b, err := os.ReadFile(stoppedMarkerPath(workspaceDir))
	if errors.Is(err, os.ErrNotExist) {
		return StoppedMarker{}, false, nil
	}
	if err != nil {
		return StoppedMarker{}, false, fmt.Errorf("reading the stopped marker: %w", err)
	}
	var m StoppedMarker
	if err := json.Unmarshal(b, &m); err != nil {
		return StoppedMarker{}, false, fmt.Errorf("reading the stopped marker: %w", err)
	}
	return m, true, nil
}
