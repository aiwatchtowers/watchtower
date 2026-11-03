package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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

// TestHubRecordingListJSONKeys: `hub recording list --json` is {ready, jobs},
// jobs an array of {upload_id, status, phase, percent, audio_path, event_id,
// started_at, error_class}
// (pinned, Desktop's start
// read); no sidecar yet is an empty array; refused under an agent marker
// (the paths lead to plaintext audio).
func TestHubRecordingListJSONKeys(t *testing.T) {
	dir := hubTestDir(t)
	out, err := runHub(t, "recording", "list", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ready":false,"jobs":[]}`, out, "no sidecar yet is not an empty queue")

	queueJob(t, dir, "u-1")
	st, err := state.Open(dir)
	require.NoError(t, err)
	started := time.Unix(1_800_000_000, 0)
	require.NoError(t, st.QueueRecordingFrom("u-2", "aabb", state.RecordingOrigin{EventID: "evt-1", StartedAt: started}, time.Now()))
	require.NoError(t, st.Close())
	_, err = runHub(t, "recording", "claim", "--upload", "u-2")
	require.NoError(t, err)
	_, err = runHub(t, "recording", "progress", "--upload", "u-2", "--phase", "transcribing", "--percent", "40")
	require.NoError(t, err)
	out, err = runHub(t, "recording", "list", "--json")
	require.NoError(t, err)
	var answer struct {
		Ready bool             `json:"ready"`
		Jobs  []map[string]any `json:"jobs"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &answer), out)
	assert.ElementsMatch(t, []string{"ready", "jobs"}, hubKeysOf(decodeKeys(t, out)))
	assert.True(t, answer.Ready)
	rows := answer.Jobs
	require.Len(t, rows, 2)
	byID := map[string]map[string]any{}
	for _, r := range rows {
		assert.ElementsMatch(t, []string{"upload_id", "status", "phase", "percent", "audio_path", "event_id", "started_at", "error_class"}, hubKeysOf(r))
		byID[r["upload_id"].(string)] = r
	}
	assert.Equal(t, "queued", byID["u-1"]["status"])
	assert.Equal(t, "", byID["u-1"]["phase"])
	assert.Nil(t, byID["u-1"]["percent"])
	assert.Equal(t, filepath.Join(dir, "recordings", "u-1.m4a"), byID["u-1"]["audio_path"])
	assert.Equal(t, "claimed", byID["u-2"]["status"])
	assert.Equal(t, "transcribing", byID["u-2"]["phase"])
	assert.EqualValues(t, 40, byID["u-2"]["percent"])
	assert.Equal(t, "", byID["u-1"]["event_id"])
	assert.Nil(t, byID["u-1"]["started_at"])
	assert.Equal(t, "evt-1", byID["u-2"]["event_id"])
	assert.EqualValues(t, 1_800_000_000, byID["u-2"]["started_at"])

	t.Setenv(agentEnvMarkers[0], "1")
	_, err = runHub(t, "recording", "list", "--json")
	assert.Error(t, err)
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
	// A headless host has no app: nothing may beat there.
	live, _ := hubLiveCLI(t, linuxProbe())
	_, err = runHub(t, "desktop", "heartbeat")
	assert.ErrorContains(t, err, "no Watchtower app")
	_, err = os.Stat(live)
	assert.True(t, errors.Is(err, fs.ErrNotExist), "a refused heartbeat created the live dir")
}

// TestDesktopHeartbeatAcceptedOnALiveDesktopHost: with no test-mode dir, a
// desktop host's Desktop beats into its live hub (once the Swift hub's state
// is adopted, or with none), after which `hub recordings on` is accepted and
// a claimed job's audio is in the transcriber's <app support>/recordings.
func TestDesktopHeartbeatAcceptedOnALiveDesktopHost(t *testing.T) {
	hubOnGOOS(t, "darwin")
	live, _ := hubLiveCLI(t, desktopAppProbe())
	out, err := runHub(t, "desktop", "heartbeat", "--json")
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"desktop_at"}, hubKeysOf(decodeKeys(t, out)))
	st, err := state.Open(live)
	require.NoError(t, err)
	fresh, seen, err := st.DesktopHost(time.Now())
	require.NoError(t, st.Close())
	require.NoError(t, err)
	assert.True(t, fresh && seen)

	out, err = runHub(t, "recordings", "on", "--json")
	require.NoError(t, err)
	assert.Equal(t, "on", decodeKeys(t, out)["recordings"])

	queueJob(t, live, "u-1")
	out, err = runHub(t, "recording", "claim", "--upload", "u-1", "--json")
	require.NoError(t, err)
	support, err := config.AppSupportDir()
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(support, "recordings", "u-1.m4a"), decodeKeys(t, out)["audio_path"])
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
