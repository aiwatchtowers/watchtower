package cmd

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/state"
)

func runHub(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"hub"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	for _, c := range hubCmd.Commands() {
		for _, sub := range append(c.Commands(), c) {
			// Local flags only: resetting the inherited root flags would point
			// flagConfig at the default (the developer's real) config path for
			// every later test in the package.
			sub.LocalFlags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
		}
	}
	return out.String(), err
}

func hubTestDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "hubtest-x")
	t.Setenv(hubDirEnv, dir)
	for _, m := range agentEnvMarkers { // the suite may itself run under an agent
		t.Setenv(m, "")
	}
	hubOnGOOS(t, "darwin")
	return dir
}

// hubOnGOOS runs the hub verbs as on goos for the test: the Desktop verbs
// are a Mac's only, and the suite also runs on Linux CI.
func hubOnGOOS(t *testing.T, goos string) {
	t.Helper()
	prev := hubGOOS
	hubGOOS = goos
	t.Cleanup(func() { hubGOOS = prev })
}

func queueJob(t *testing.T, dir, id string) {
	t.Helper()
	st, err := state.Open(dir)
	require.NoError(t, err)
	require.NoError(t, st.QueueRecording(id, "aabb", time.Now()))
	require.NoError(t, st.Close())
}

func decodeKeys(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

func hubKeysOf(m map[string]any) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

func TestDesktopHeartbeatJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	out, err := runHub(t, "desktop", "heartbeat", "--json")
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"desktop_at"}, hubKeysOf(decodeKeys(t, out)))
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	fresh, seen, err := st.DesktopHost(time.Now())
	require.NoError(t, err)
	assert.True(t, fresh && seen)
}

func TestHubRecordingClaimFinishJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	out, err := runHub(t, "recording", "claim", "--upload", "u-1", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"upload_id", "audio_path", "status"}, hubKeysOf(m))
	assert.Equal(t, "claimed", m["status"])
	assert.Equal(t, filepath.Join(dir, "recordings", "u-1.m4a"), m["audio_path"])

	out, err = runHub(t, "recording", "finish", "--upload", "u-1", "--transcript", "42", "--json")
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"upload_id", "status", "transcript_id"}, hubKeysOf(m))
	assert.Equal(t, "done", m["status"])
	assert.EqualValues(t, 42, m["transcript_id"])
}

// TestHubRecordingProgressJSONKeys: `hub recording progress --json` pins
// {upload_id, status, phase, percent}; percent is null outside transcribing.
func TestHubRecordingProgressJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	_, err := runHub(t, "recording", "claim", "--upload", "u-1")
	require.NoError(t, err)
	out, err := runHub(t, "recording", "progress", "--upload", "u-1", "--phase", "transcribing", "--percent", "40", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.ElementsMatch(t, []string{"upload_id", "status", "phase", "percent"}, hubKeysOf(m))
	assert.Equal(t, "u-1", m["upload_id"])
	assert.Equal(t, "claimed", m["status"])
	assert.Equal(t, "transcribing", m["phase"])
	assert.EqualValues(t, 40, m["percent"])

	out, err = runHub(t, "recording", "progress", "--upload", "u-1", "--phase", "diarizing", "--json")
	require.NoError(t, err)
	m = decodeKeys(t, out)
	assert.Equal(t, "diarizing", m["phase"])
	assert.Nil(t, m["percent"])

	_, err = runHub(t, "recording", "progress", "--upload", "u-1", "--phase", "summarizing", "--percent", "5")
	assert.ErrorContains(t, err, "malformed")
	_, err = runHub(t, "recording", "progress", "--upload", "u-1")
	assert.ErrorContains(t, err, "usage")
}

// TestDesktopOpsRefusedUnderAnAgentMarker: the Desktop's progress verb is
// refused under every agent marker and writes nothing (desktop_view and
// desktop_watch have no CLI verb: the 0600 socket is Desktop's alone).
func TestDesktopOpsRefusedUnderAnAgentMarker(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			dir := hubTestDir(t)
			queueJob(t, dir, "u-1")
			_, err := runHub(t, "recording", "claim", "--upload", "u-1")
			require.NoError(t, err)
			t.Setenv(marker, "1")
			_, err = runHub(t, "recording", "progress", "--upload", "u-1", "--phase", "diarizing")
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			assert.Contains(t, err.Error(), marker)
			st, err := state.Open(dir)
			require.NoError(t, err)
			defer func() { _ = st.Close() }()
			job, err := st.RecordingJob("u-1")
			require.NoError(t, err)
			assert.Empty(t, job.Phase, "no progress written")
		})
	}
}

func TestHubRecordingFinishWithAnErrorStoresItsClassOnly(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	_, err := runHub(t, "recording", "claim", "--upload", "u-1")
	require.NoError(t, err)
	out, err := runHub(t, "recording", "finish", "--upload", "u-1", "--error", "Could not read /Users/x/a b.m4a", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Equal(t, "failed", m["status"])
	assert.Nil(t, m["transcript_id"])
	st, err := state.Open(dir)
	require.NoError(t, err)
	defer func() { _ = st.Close() }()
	job, err := st.RecordingJob("u-1")
	require.NoError(t, err)
	assert.Equal(t, "other", job.ErrorClass)
}

func TestHubRecordingVerbUsage(t *testing.T) {
	dir := hubTestDir(t)
	queueJob(t, dir, "u-1")
	_, err := runHub(t, "recording", "finish", "--upload", "u-1")
	assert.Error(t, err)
	_, err = runHub(t, "recording", "finish", "--upload", "u-1", "--transcript", "1", "--error", "x")
	assert.Error(t, err)
	_, err = runHub(t, "recording", "claim", "--upload", "nope", "--json")
	assert.ErrorContains(t, err, "no recording job")
	t.Setenv(hubDirEnv, "")
	_, err = runHub(t, "desktop", "heartbeat")
	assert.ErrorContains(t, err, hubDirEnv)
}

func TestDesktopHeartbeatRefusedUnderAnAgentMarker(t *testing.T) {
	verbs := [][]string{
		{"desktop", "heartbeat"},
		{"recording", "claim", "--upload", "u-1"},
		{"recording", "finish", "--upload", "u-1", "--transcript", "1"},
	}
	for _, marker := range agentEnvMarkers {
		for _, v := range verbs {
			t.Run(marker+"/"+v[0]+" "+v[1], func(t *testing.T) {
				dir := hubTestDir(t)
				queueJob(t, dir, "u-1")
				t.Setenv(marker, "1")
				_, err := runHub(t, v...)
				require.Error(t, err)
				assert.Contains(t, err.Error(), "under an AI agent")
				assert.Contains(t, err.Error(), marker)
				st, err := state.Open(dir)
				require.NoError(t, err)
				defer func() { _ = st.Close() }()
				_, seen, _ := st.DesktopHost(time.Now())
				assert.False(t, seen, "no heartbeat written")
				job, _ := st.RecordingJob("u-1")
				assert.Equal(t, state.RecordingQueued, job.Status)
			})
		}
	}
}
