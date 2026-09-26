package sync

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// SyncProgress is the live "what is the daemon doing right now" heartbeat,
// written next to last_sync.json while a sync runs. last_sync.json answers
// "when did a sync last finish"; this file answers "is one running, and how
// far along" — the question the tray could not answer before, because Progress
// lives in the daemon's memory and nothing outside the process could see it.
//
// Consumers must treat a stale file as "not syncing": the daemon can be killed
// mid-sync, leaving Active true forever. UpdatedAt is what makes that
// detectable — see StaleAfter.
type SyncProgress struct {
	Active          bool      `json:"active"`
	Phase           string    `json:"phase"`
	Detail          string    `json:"detail,omitempty"`
	MessagesFetched int       `json:"messages_fetched"`
	StartedAt       time.Time `json:"started_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// StaleAfter is how long a heartbeat may go unrefreshed before a reader should
// stop believing its Active flag. Generous against the write interval: a sync
// phase that blocks on one slow API call still refreshes the file, so silence
// this long means the writer is gone, not busy.
const StaleAfter = 2 * time.Minute

// IsStale reports whether the heartbeat is too old to be trusted as live.
func (p SyncProgress) IsStale(now time.Time) bool {
	return now.Sub(p.UpdatedAt) > StaleAfter
}

// IsSyncing reports whether a sync is genuinely in progress: active and fresh.
func (p SyncProgress) IsSyncing(now time.Time) bool {
	return p.Active && !p.IsStale(now)
}

// ProgressFromSnapshot renders a live heartbeat from a progress snapshot.
func ProgressFromSnapshot(snap Snapshot) SyncProgress {
	return SyncProgress{
		Active:          true,
		Phase:           snap.Phase.String(),
		Detail:          progressDetail(snap),
		MessagesFetched: snap.MessagesFetched,
		StartedAt:       snap.StartTime,
		UpdatedAt:       time.Now(),
	}
}

// IdleProgress is the heartbeat written when no sync is running.
func IdleProgress() SyncProgress {
	return SyncProgress{UpdatedAt: time.Now()}
}

// progressDetail is the one-line "how far along" text for the active phase,
// kept short enough for a menu-bar line.
func progressDetail(snap Snapshot) string {
	switch snap.Phase {
	case PhaseMetadata:
		if snap.ChannelsTotal > 0 {
			return fmt.Sprintf("%d/%d channels", snap.ChannelsDone, snap.ChannelsTotal)
		}
		if snap.UsersTotal > 0 {
			return fmt.Sprintf("%d/%d users", snap.UsersDone, snap.UsersTotal)
		}
	case PhaseDiscovery:
		if snap.DiscoveryTotalPages > 0 {
			return fmt.Sprintf("page %d/%d", snap.DiscoveryPages, snap.DiscoveryTotalPages)
		}
	case PhaseMessages:
		if snap.MsgChannelsTotal > 0 {
			return fmt.Sprintf("%d/%d channels", snap.MsgChannelsDone, snap.MsgChannelsTotal)
		}
	case PhaseUsers:
		if snap.UserProfilesTotal > 0 {
			return fmt.Sprintf("%d/%d profiles", snap.UserProfilesDone, snap.UserProfilesTotal)
		}
	case PhaseDone:
		// Nothing left to count — the phase name alone is the whole status.
	}
	return ""
}

// WriteSyncProgress writes the heartbeat atomically. Unlike WriteSyncResult
// (written once per sync) this file is rewritten every few seconds while a
// reader — the tray — polls it, so a torn read is a real possibility without
// the temp-file-and-rename dance.
func WriteSyncProgress(path string, p SyncProgress) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// ReadSyncProgress reads the heartbeat file.
func ReadSyncProgress(path string) (*SyncProgress, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p SyncProgress
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	return &p, nil
}
