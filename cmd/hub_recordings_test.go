package cmd

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/state"
)

// recordingsOf reads the switch from dir's sidecar.
func recordingsOf(t *testing.T, dir string) (on, stored bool) {
	t.Helper()
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	on, stored, err = st.Recordings()
	require.NoError(t, err)
	return on, stored
}

func beatOnce(t *testing.T, dir string) {
	t.Helper()
	st, err := state.Open(dir)
	require.NoError(t, err)
	require.NoError(t, st.Heartbeat(time.Now()))
	require.NoError(t, st.Close())
}

func TestHubRecordingsJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	beatOnce(t, dir)
	out, err := runHub(t, "recordings", "off", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"recordings", "stored"}, hubKeysOf(m))
	assert.Equal(t, "off", m["recordings"])
	assert.Equal(t, true, m["stored"])
	on, stored := recordingsOf(t, dir)
	assert.False(t, on)
	assert.True(t, stored)

	out, err = runHub(t, "recordings", "on", "--json")
	require.NoError(t, err)
	assert.Equal(t, "on", decodeKeys(t, out)["recordings"])
	on, _ = recordingsOf(t, dir)
	assert.True(t, on)

	_, err = runHub(t, "recordings", "maybe")
	assert.ErrorContains(t, err, "on or off")
}

func TestRecordingsOnRefusedWithoutATranscriber(t *testing.T) {
	dir := hubTestDir(t)
	_, err := runHub(t, "recordings", "on")
	require.Error(t, err)
	assert.Equal(t, "this host has no transcriber", err.Error())
	on, stored := recordingsOf(t, dir)
	assert.False(t, on)
	assert.False(t, stored, "nothing stored")
}

func TestHubRecordingsRefusedUnderAnAgentMarker(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		for _, arg := range []string{"on", "off"} {
			t.Run(marker+"/"+arg, func(t *testing.T) {
				dir := hubTestDir(t)
				beatOnce(t, dir)
				t.Setenv(marker, "1")
				_, err := runHub(t, "recordings", arg)
				require.Error(t, err)
				assert.Contains(t, err.Error(), "under an AI agent")
				assert.Contains(t, err.Error(), marker)
				_, stored := recordingsOf(t, dir)
				assert.False(t, stored, "nothing stored")
			})
		}
	}
}

func TestHubStatusCarriesRecordings(t *testing.T) {
	dir := hubTestDir(t)
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, "off", decodeKeys(t, out)["recordings"], "no sidecar: no transcriber ever seen")
	beatOnce(t, dir)
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, "on", decodeKeys(t, out)["recordings"])
	out, err = runHub(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "recordings on")
}

func TestDesktopHeartbeatRefusedOffDarwin(t *testing.T) {
	dir := hubTestDir(t)
	hubGOOS = "linux"
	_, err := runHub(t, "desktop", "heartbeat")
	require.Error(t, err)
	assert.Equal(t, "there is no Watchtower app on Linux", err.Error())
	_, err = runHub(t, "recordings", "on")
	assert.ErrorContains(t, err, "no transcriber", "so a Linux hub never publishes on")
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	_, seen, err := st.DesktopSeenAt()
	require.NoError(t, err)
	assert.False(t, seen, "desktop_seen_at never written")
}
