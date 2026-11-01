package cmd

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/identity"
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
		for _, args := range [][]string{{"--settings-stdin"}, {"--status", "--json"}, {"--keys-stdin", "--json"}, {"--confirm-deleted", "--json"}} {
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

// adoptedWithKeys adopts swiftMobileHub's state through the CLI and reseals
// the sidecar's keys under a fresh Swift-shaped identity (the fixture's
// rows hold none); it returns the keys' stdin payload.
func adoptedWithKeys(t *testing.T, dir string) string {
	t.Helper()
	mobile := swiftMobileHub(t, dir)
	withStdin(t, adoptSettings)
	_, err := runHub(t, "adopt", "--settings-stdin", "--mobile-hub", mobile)
	require.NoError(t, err)
	return resealedKeys(t, dir)
}

func resealedKeys(t *testing.T, dir string) string {
	t.Helper()
	var sig, kx, wrap [32]byte
	for _, b := range [][]byte{sig[:], kx[:], wrap[:]} {
		_, err := rand.Read(b)
		require.NoError(t, err)
	}
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM hub_epochs`); err != nil {
			return err
		}
		_, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, state.MetaKMetaSealed)
		return err
	}))
	id, err := identity.FromSwift(sig[:], kx[:], wrap[:])
	require.NoError(t, err)
	_, err = identity.NewKeyring(id, st, nil)
	require.NoError(t, err)
	b, err := json.Marshal(adopt.KeysPayload{HubSig: sig[:], HubKX: kx[:], Wrap: wrap[:]})
	require.NoError(t, err)
	return string(b)
}

func TestHubAdoptKeysStdin(t *testing.T) {
	dir := hubTestDir(t)
	payload := adoptedWithKeys(t, dir)

	_, err := runHub(t, "adopt", "--confirm-deleted", "--json")
	require.Error(t, err, "confirm before adopted")

	withStdin(t, payload)
	out, err := runHub(t, "adopt", "--keys-stdin", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, []string{"identity"}, hubKeysOf(m))
	assert.Equal(t, "adopted", m["identity"])
	assert.NotContains(t, out, payload[10:30], "no key text in the answer")
	// Test mode keeps the identity in the hub dir's file, never the Keychain.
	info, err := os.Stat(filepath.Join(dir, identity.FileName))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	out, err = runHub(t, "adopt", "--status", "--json")
	require.NoError(t, err)
	assert.Equal(t, "adopted", decodeKeys(t, out)["identity"])

	out, err = runHub(t, "adopt", "--confirm-deleted", "--json")
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"identity": "confirmed"}, decodeKeys(t, out))

	// A repeat hand-over answers adopted at once.
	withStdin(t, "{}")
	out, err = runHub(t, "adopt", "--keys-stdin", "--json")
	require.NoError(t, err)
	assert.Equal(t, "adopted", decodeKeys(t, out)["identity"])
}

func TestHubAdoptWrongKeys(t *testing.T) {
	dir := hubTestDir(t)
	adoptedWithKeys(t, dir)
	other := resealedKeys(t, filepath.Join(t.TempDir(), "other")) // another sidecar's keys
	withStdin(t, other)
	out, err := runHub(t, "adopt", "--keys-stdin", "--json")
	require.Error(t, err)
	assert.Equal(t, map[string]any{"identity": "wrong_keys"}, decodeKeys(t, out))
	_, err = os.Stat(filepath.Join(dir, identity.StagedFileName))
	assert.True(t, os.IsNotExist(err), "the staged copy is deleted")
}

func TestHubAdoptKeysWithoutASidecar(t *testing.T) {
	dir := hubTestDir(t)
	withStdin(t, "{}")
	out, err := runHub(t, "adopt", "--keys-stdin", "--json")
	require.Error(t, err)
	assert.Equal(t, map[string]any{"identity": "no_sidecar"}, decodeKeys(t, out))
	_, err = os.Stat(filepath.Join(dir, state.FileName))
	assert.True(t, os.IsNotExist(err), "no sidecar created")
}

func TestKeysStdinAndSettingsStdinAreSeparateCalls(t *testing.T) {
	dir := hubTestDir(t)
	mobile := swiftMobileHub(t, dir)
	for _, args := range [][]string{
		{"--settings-stdin", "--keys-stdin"},
		{"--keys-stdin", "--confirm-deleted"},
		{"--status", "--keys-stdin"},
		{"--settings-stdin", "--confirm-deleted"},
	} {
		withStdin(t, adoptSettings)
		_, err := runHub(t, append([]string{"adopt", "--json", "--mobile-hub", mobile}, args...)...)
		require.Error(t, err, args)
		assert.ErrorContains(t, err, "one per call")
	}
	_, err := os.Stat(filepath.Join(dir, state.FileName))
	assert.True(t, os.IsNotExist(err), "nothing adopted")
}
