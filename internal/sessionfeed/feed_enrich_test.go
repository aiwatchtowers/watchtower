package sessionfeed

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// countSidecarOpens records each sidecar transcript openSidecar opens, by
// base name.
func countSidecarOpens(t *testing.T) map[string]int {
	t.Helper()
	opens := map[string]int{}
	orig := openSidecar
	openSidecar = func(p string) (*os.File, error) { opens[filepath.Base(p)]++; return os.Open(p) }
	t.Cleanup(func() { openSidecar = orig })
	return opens
}

// twoAgentsFx is a conversation where two background agents (tu1 → ag1,
// tu2 → ag2) each finished with a handback; tu2's notice is the last entry.
func twoAgentsFx(t *testing.T) Conversation {
	t.Helper()
	dir := t.TempDir()
	notice := func(uuid, ts, tu string) string {
		return jsonLine(map[string]any{"type": "user", "uuid": uuid, "timestamp": ts,
			"message": map[string]any{"role": "user", "content": strings.Replace(taskNoticeText, "tu1", tu, 1)}})
	}
	a := writeConv(t, dir, "A", join(userStr("u1", "go"),
		assistantRec("a1", "m1", agentCall("tu1", "Explore", "one"), agentCall("tu2", "Explore", "two")),
		notice("n1", "2026-10-01T10:00:30Z", "tu1"),
		userStr("u2", "next"),
		notice("n2", "2026-10-01T10:01:30Z", "tu2")))
	side := filepath.Join(dir, "A")
	writeSub(t, side, "ag1", `{"toolUseId":"tu1","finished":true,"requestShape":"background"}`,
		handbackAt("h1", "2026-10-01T10:00:20Z", "report one"))
	writeSub(t, side, "ag2", `{"toolUseId":"tu2","finished":true,"requestShape":"background"}`,
		handbackAt("h2", "2026-10-01T10:01:20Z", "report two"))
	return a
}

func TestBuildTail_ReadsOnlySidecarsOfThePage(t *testing.T) {
	a := twoAgentsFx(t)
	opens := countSidecarOpens(t)
	f, before, err := BuildTail([]Conversation{a}, nil, nil, "", 1)
	require.NoError(t, err)
	require.Len(t, f.Entries, 1)
	require.NotNil(t, f.Entries[0].Task)
	assert.Equal(t, "report two", f.Entries[0].Task.Result)
	assert.NotEmpty(t, before)
	assert.Equal(t, map[string]int{"agent-ag2.jsonl": 1}, opens, "the dropped tu1 notice's sidecar must not be read")
	assert.Len(t, f.Subagents, 2, "the subagent list still covers the whole feed")

	// The next older page fills its own notice.
	f, _, err = BuildTail([]Conversation{a}, nil, nil, before, 2)
	require.NoError(t, err)
	assert.Equal(t, "report one", tasksOf(f)[0].Result)
}

func TestBuildTail_MatchesTailPageOfBuild(t *testing.T) {
	a := twoAgentsFx(t)
	full, err := Build([]Conversation{a}, nil, nil)
	require.NoError(t, err)
	want, wantBefore, err := TailPage(full.Entries, "", 3)
	require.NoError(t, err)
	got, gotBefore, err := BuildTail([]Conversation{a}, nil, nil, "", 3)
	require.NoError(t, err)
	assert.Equal(t, want, got.Entries)
	assert.Equal(t, wantBefore, gotBefore)
	_, _, err = BuildTail([]Conversation{a}, nil, nil, "nope", 3)
	assert.ErrorContains(t, err, "no such entry")
}

// The drill-in polls FindSubagent; its marker-only build reads no handbacks.
func TestFindSubagent_ReadsNoHandbacks(t *testing.T) {
	a := twoAgentsFx(t)
	opens := countSidecarOpens(t)
	_, _, err := FindSubagent([]Conversation{a}, "tu2")
	require.NoError(t, err)
	assert.Empty(t, opens)
}

// A sidecar that fails mid-read is logged and leaves the notice's own text;
// it is not taken as a transcript without handbacks in silence.
func TestBuild_SidecarReadErrorIsLoggedAndBestEffort(t *testing.T) {
	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	orig := openSidecar
	openSidecar = func(string) (*os.File, error) { return os.Open(t.TempDir()) } // a directory: every read fails
	t.Cleanup(func() { openSidecar = orig })
	f := oneNotice(t, bgMeta, "a report")
	assert.Equal(t, "", taskOf(t, f).Result)
	assert.Contains(t, logged.String(), "agent-ag1.jsonl")
}

// #2386 N6: a sidecar whose stat fails for a reason other than its absence is
// an error (logged by the caller), not "no handbacks".
func TestScanHandbacks_StatErrorIsReported(t *testing.T) {
	orig := lstatSidecar
	lstatSidecar = func(string) (os.FileInfo, error) { return nil, os.ErrPermission }
	t.Cleanup(func() { lstatSidecar = orig })
	_, err := scanHandbacks(filepath.Join(t.TempDir(), "agent-a.jsonl"))
	require.ErrorIs(t, err, os.ErrPermission)
}

// A missing or non-regular sidecar has no handbacks and no error.
func TestScanHandbacks_MissingOrNotRegularIsQuiet(t *testing.T) {
	dir := t.TempDir()
	hbs, err := scanHandbacks(filepath.Join(dir, "missing.jsonl"))
	require.NoError(t, err)
	assert.Empty(t, hbs)
	hbs, err = scanHandbacks(dir)
	require.NoError(t, err)
	assert.Empty(t, hbs)
}
