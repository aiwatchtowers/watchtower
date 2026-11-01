package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/state/swiftfixture"
)

const (
	adoptHubID  = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
	adoptPhone  = "0B0B0B0B-0B0B-4B0B-8B0B-0B0B0B0B0B0B"
	adoptUpdate = 1_700_000_000.0
)

// swiftMobileHub builds a Swift-shaped MobileHub/ beside the test hub dir:
// one phone, one recording being transcribed (its audio in the
// transcriber's folder, here the hub dir's recordings/) and one done.
func swiftMobileHub(t *testing.T, hubDir string) string {
	t.Helper()
	root := filepath.Dir(hubDir)
	mobile, pending := filepath.Join(root, "MobileHub"), filepath.Join(hubDir, "recordings")
	require.NoError(t, os.MkdirAll(mobile, 0o700))
	require.NoError(t, os.MkdirAll(pending, 0o700))
	db, err := swiftfixture.Create(filepath.Join(mobile, state.FileName), adoptHubID, swiftfixture.Schema)
	require.NoError(t, err)
	defer func() { _ = db.Close() }()
	_, err = db.Exec(`INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, start_sessions_granted) VALUES (?, 'phone', 'shared', '_acme', 1700000000, 0)`, adoptPhone)
	require.NoError(t, err)
	audio := filepath.Join(pending, "acme sync.m4a")
	require.NoError(t, os.WriteFile(audio, []byte("audio"), 0o600))
	_, err = db.Exec(`INSERT INTO phone_recordings (upload_id, audio_path, status, updated_at) VALUES ('rec-1', ?, 'transcribing', ?), ('rec-2', '', 'done', ?)`,
		audio, adoptUpdate, adoptUpdate)
	require.NoError(t, err)
	return mobile
}

func withStdin(t *testing.T, s string) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(s))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
}

const adoptSettings = `{"enabled":true,"start_session_allows":{"` + adoptPhone + `":true}}`

func TestHubAdoptJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	mobile := swiftMobileHub(t, dir)

	out, err := runHub(t, "adopt", "--status", "--json", "--mobile-hub", mobile)
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"step", "imported", "error", "hub_id", "identity", "swift_state", "pending_recordings"}, hubKeysOf(m))
	assert.Equal(t, adoptHubID, m["hub_id"])
	assert.Equal(t, "none", m["identity"])
	assert.Equal(t, "present", m["swift_state"])
	pending, _ := m["pending_recordings"].([]any)
	require.Len(t, pending, 1)
	p, _ := pending[0].(map[string]any)
	assert.ElementsMatch(t, []string{"upload_id", "audio_name"}, hubKeysOf(p))
	assert.Equal(t, "rec-1", p["upload_id"])
	assert.Equal(t, "acme sync.m4a", p["audio_name"])
	imported, _ := m["imported"].(map[string]any)
	assert.ElementsMatch(t, []string{"devices", "jobs", "skipped", "audio_left"}, hubKeysOf(imported))

	withStdin(t, adoptSettings)
	out, err = runHub(t, "adopt", "--settings-stdin", "--json", "--mobile-hub", mobile)
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"step", "imported", "error"}, hubKeysOf(m))
	assert.Equal(t, "done", m["step"])
	assert.Equal(t, "", m["error"])
	imported, _ = m["imported"].(map[string]any)
	assert.Equal(t, map[string]any{"devices": 1.0, "jobs": 2.0, "skipped": 0.0, "audio_left": 0.0}, imported)

	st, err := state.Open(dir)
	require.NoError(t, err)
	v, _, err := st.Meta(state.MetaEnabled)
	require.NoError(t, err)
	assert.Equal(t, "1", v)
	d, ok, err := st.Device(adoptPhone)
	require.NoError(t, err)
	require.True(t, ok)
	assert.True(t, d.StartSessionsGranted)
	require.NoError(t, st.Close())
	b, err := os.ReadFile(filepath.Join(dir, "recordings", "rec-1.m4a"))
	require.NoError(t, err)
	assert.Equal(t, "audio", string(b))

	out, err = runHub(t, "adopt", "--status", "--json", "--mobile-hub", mobile)
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.Equal(t, "done", m["step"])
	assert.Equal(t, "absent", m["swift_state"])
	assert.Equal(t, adoptHubID, m["hub_id"])
	assert.Equal(t, []any{}, m["pending_recordings"])

	// A second adoption is refused, its JSON still printed.
	withStdin(t, adoptSettings)
	out, err = runHub(t, "adopt", "--settings-stdin", "--json", "--mobile-hub", mobile)
	require.Error(t, err)
	assert.Equal(t, "already_adopted", decodeKeys(t, out)["error"])

	_, err = runHub(t, "adopt", "--mobile-hub", mobile)
	assert.ErrorContains(t, err, "--status or --settings-stdin")
}

func TestAdoptIsRefusedUnderAnAgentMarker(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		for _, args := range [][]string{{"--settings-stdin"}, {"--status", "--json"}} {
			t.Run(marker+"/"+args[0], func(t *testing.T) {
				dir := hubTestDir(t)
				mobile := swiftMobileHub(t, dir)
				t.Setenv(marker, "1")
				withStdin(t, adoptSettings)
				_, err := runHub(t, append([]string{"adopt", "--mobile-hub", mobile}, args...)...)
				require.Error(t, err)
				assert.Contains(t, err.Error(), "under an AI agent")
				assert.Contains(t, err.Error(), marker)
				_, err = os.Stat(filepath.Join(dir, state.FileName))
				assert.True(t, os.IsNotExist(err), "nothing adopted")
				_, err = os.Stat(filepath.Join(mobile, state.FileName))
				assert.NoError(t, err, "the Swift state is untouched")
			})
		}
	}
}

func TestHubStatusKeptRecordings(t *testing.T) {
	dir := hubTestDir(t)
	mobile := swiftMobileHub(t, dir)
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.NotContains(t, decodeKeys(t, out), "kept_recordings", "no sidecar")

	withStdin(t, adoptSettings)
	_, err = runHub(t, "adopt", "--settings-stdin", "--mobile-hub", mobile)
	require.NoError(t, err)
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	kept, ok := decodeKeys(t, out)["kept_recordings"].(map[string]any)
	require.True(t, ok, out)
	assert.ElementsMatch(t, []string{"count", "remove_at", "dir"}, hubKeysOf(kept))
	assert.Equal(t, 1.0, kept["count"])
	assert.Equal(t, filepath.Join(dir, "recordings"), kept["dir"])
	// 31 days from the adoption.
	removeAt, err := time.Parse(time.RFC3339Nano, kept["remove_at"].(string))
	require.NoError(t, err)
	assert.WithinDuration(t, time.Now().Add(31*24*time.Hour), removeAt, time.Minute)

	// The prune removes the job and its audio: the key goes.
	st, err := state.Open(dir)
	require.NoError(t, err)
	n, err := st.PruneRecordingJobs(filepath.Join(dir, "recordings"), time.Now().Add(time.Second))
	require.NoError(t, err)
	assert.Equal(t, 2, n)
	require.NoError(t, st.Close())
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.NotContains(t, decodeKeys(t, out), "kept_recordings")
}

// TestHubStatusMidAdoption: a sidecar not migrated yet (a kill right after
// the rename) never fails hub status; kept_recordings is just absent.
func TestHubStatusMidAdoption(t *testing.T) {
	dir := hubTestDir(t)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	db, err := swiftfixture.Create(filepath.Join(dir, state.FileName), adoptHubID, swiftfixture.Schema)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO hub_meta (key, value) VALUES ('adopt_step', 'migrate')`)
	require.NoError(t, err)
	require.NoError(t, db.Close())
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.NotContains(t, decodeKeys(t, out), "kept_recordings")
}
