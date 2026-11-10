package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/state"
)

// failJob claims and fails a queued job, as Desktop's transcriber does.
func failJob(t *testing.T, id string) {
	t.Helper()
	_, err := runHub(t, "recording", "claim", "--upload", id)
	require.NoError(t, err)
	_, err = runHub(t, "recording", "finish", "--upload", id, "--error", "not_audio")
	require.NoError(t, err)
}

// TestHubRecordingDiscardJSONKeys: `hub recording discard --json` pins
// {upload_id, discarded}; the job and the audio the hub kept are gone.
func TestHubRecordingDiscardJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	failJob(t, "u-1")
	audio := filepath.Join(dir, "recordings", "u-1.m4a")
	require.NoError(t, os.MkdirAll(filepath.Dir(audio), 0o700))
	require.NoError(t, os.WriteFile(audio, []byte("audio"), 0o600))

	out, err := runHub(t, "recording", "discard", "--upload", "u-1", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"upload_id", "discarded"}, hubKeysOf(m))
	assert.Equal(t, "u-1", m["upload_id"])
	assert.Equal(t, true, m["discarded"])
	_, err = os.Stat(audio)
	assert.True(t, os.IsNotExist(err), "the audio is gone")
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	ok, err := st.HasRecording("u-1")
	require.NoError(t, err)
	assert.False(t, ok, "the job is gone")
}

// TestHubRecordingDiscardRefusesAJobThatIsNotFailed: a queued job is
// refused and kept; an unknown one says so; --upload is required.
func TestHubRecordingDiscardRefusesAJobThatIsNotFailed(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	_, err := runHub(t, "recording", "discard", "--upload", "u-1", "--json")
	assert.ErrorContains(t, err, "not in a state")
	_, err = runHub(t, "recording", "discard", "--upload", "nope", "--json")
	assert.ErrorContains(t, err, "no recording job")
	_, err = runHub(t, "recording", "discard")
	assert.ErrorContains(t, err, "usage")
}

// TestHubRecordingDiscardRefusedUnderAnAgentMarker: an owner verb (it
// deletes the only copy of a recording): refused under every agent marker,
// nothing deleted.
func TestHubRecordingDiscardRefusedUnderAnAgentMarker(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			dir := hubTestDir(t)
			queueJob(t, dir, "u-1")
			failJob(t, "u-1")
			t.Setenv(marker, "1")
			_, err := runHub(t, "recording", "discard", "--upload", "u-1")
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			st, err := state.Open(dir)
			require.NoError(t, err)
			defer func() { _ = st.Close() }()
			ok, err := st.HasRecording("u-1")
			require.NoError(t, err)
			assert.True(t, ok, "nothing discarded")
		})
	}
}

// TestHubStatusJSONCarriesTheHubName: `hub status --json` names the hub as
// phones show it — hub name's value once set, else the host name.
func TestHubStatusJSONCarriesTheHubName(t *testing.T) {
	hubTestDir(t)
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.NotEmpty(t, m["name"], "a default name before any is set")
	_, err = runHub(t, "name", "Work Mac")
	require.NoError(t, err)
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, "Work Mac", decodeKeys(t, out)["name"])
}
