package sync

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWriteReadSyncProgress_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "sync_progress.json")

	want := SyncProgress{
		Active:          true,
		Phase:           "Messages",
		Detail:          "34/105 channels",
		MessagesFetched: 1200,
		StartedAt:       time.Now().Add(-time.Minute).Round(time.Second),
		UpdatedAt:       time.Now().Round(time.Second),
	}
	require.NoError(t, WriteSyncProgress(path, want))

	got, err := ReadSyncProgress(path)
	require.NoError(t, err)
	assert.Equal(t, want.Active, got.Active)
	assert.Equal(t, want.Phase, got.Phase)
	assert.Equal(t, want.Detail, got.Detail)
	assert.Equal(t, want.MessagesFetched, got.MessagesFetched)
	assert.True(t, want.StartedAt.Equal(got.StartedAt))

	// The temp file used for the atomic rename must not be left behind — the
	// tray polls this directory and a stray .tmp would be read as garbage.
	_, err = os.Stat(path + ".tmp")
	assert.True(t, os.IsNotExist(err), "temp file should be renamed away")
}

// A daemon killed mid-sync leaves active=true in the file forever, so freshness
// — not the flag — decides whether a sync is really running.
func TestSyncProgress_StaleActiveIsNotSyncing(t *testing.T) {
	now := time.Now()
	fresh := SyncProgress{Active: true, UpdatedAt: now.Add(-10 * time.Second)}
	stale := SyncProgress{Active: true, UpdatedAt: now.Add(-StaleAfter - time.Second)}
	idle := IdleProgress()

	assert.True(t, fresh.IsSyncing(now))
	assert.False(t, stale.IsSyncing(now), "an abandoned heartbeat must not read as syncing")
	assert.True(t, stale.IsStale(now))
	assert.False(t, idle.IsSyncing(now))
}

func TestProgressFromSnapshot_PhaseDetail(t *testing.T) {
	tests := []struct {
		name string
		snap Snapshot
		want string
	}{
		{"metadata channels", Snapshot{Phase: PhaseMetadata, ChannelsDone: 12, ChannelsTotal: 105}, "12/105 channels"},
		{"metadata users", Snapshot{Phase: PhaseMetadata, UsersDone: 3, UsersTotal: 9}, "3/9 users"},
		{"discovery pages", Snapshot{Phase: PhaseDiscovery, DiscoveryPages: 12, DiscoveryTotalPages: 191}, "page 12/191"},
		{"messages channels", Snapshot{Phase: PhaseMessages, MsgChannelsDone: 34, MsgChannelsTotal: 105}, "34/105 channels"},
		{"user profiles", Snapshot{Phase: PhaseUsers, UserProfilesDone: 2400, UserProfilesTotal: 3099}, "2400/3099 profiles"},
		{"no counters yet", Snapshot{Phase: PhaseMessages}, ""},
		{"done", Snapshot{Phase: PhaseDone}, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ProgressFromSnapshot(tc.snap)
			assert.True(t, got.Active)
			assert.Equal(t, tc.snap.Phase.String(), got.Phase)
			assert.Equal(t, tc.want, got.Detail)
		})
	}
}
