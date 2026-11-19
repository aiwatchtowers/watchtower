package sessionagent

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Hand-made rollout heads; ids are zero UUIDs.
const (
	tRoot  = "00000000-0000-0000-0000-00000000c0d1"
	tChild = "00000000-0000-0000-0000-00000000c0e1"
	tOther = "00000000-0000-0000-0000-00000000c0e4"
)

func childHead(id, parent string) string {
	return `{"timestamp":"2026-11-01T10:00:00Z","type":"session_meta","payload":{"id":"` + id + `","cwd":"/work",` +
		`"source":{"subagent":{"thread_spawn":{"parent_thread_id":"` + parent + `"}}}}}` + "\n" +
		`{"timestamp":"2026-11-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"x"}}` + "\n"
}

func writeChild(t *testing.T, dir, id, content string) string {
	t.Helper()
	require.NoError(t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "rollout-2026-11-01T10-00-00-"+id+".jsonl")
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))
	return p
}

// ChildImportFile (AGENTLOG-04, ask #1132): by the child's id only, its
// session_meta naming one of the given parents, never through a symlink,
// under sessions/<y>/<m>/<d> or archived_sessions.
func TestCodexTranscript_ChildImportFileChecksParentAndSymlinks(t *testing.T) {
	home := t.TempDir()
	tr := codexTranscript{row: Row{SessionID: tRoot, Home: home}}
	dated := filepath.Join(home, "sessions", "2026", "11", "01")

	_, ok, err := tr.ChildImportFile("../"+tChild, []string{tRoot})
	require.NoError(t, err)
	assert.False(t, ok, "an id that is not a thread id is never globbed")

	p := writeChild(t, dated, tChild, childHead(tChild, tRoot))
	got, ok, err := tr.ChildImportFile(tChild, []string{tRoot})
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, p, got)
	_, ok, err = tr.ChildImportFile(tChild, []string{tOther})
	require.NoError(t, err)
	assert.False(t, ok, "its session_meta names another parent")

	require.NoError(t, os.WriteFile(p, []byte(childHead(tChild, tOther)), 0o600))
	_, ok, err = tr.ChildImportFile(tChild, []string{tRoot})
	require.NoError(t, err)
	assert.False(t, ok)

	// A symlinked match is refused.
	require.NoError(t, os.Remove(p))
	target := writeChild(t, t.TempDir(), tChild, childHead(tChild, tRoot))
	require.NoError(t, os.Symlink(target, p))
	_, ok, err = tr.ChildImportFile(tChild, []string{tRoot})
	require.NoError(t, err)
	assert.False(t, ok, "never through a symlink")
	require.NoError(t, os.Remove(p))

	// A first line longer than the read bound is not a meta.
	long := `{"type":"session_meta","payload":{"id":"` + tChild + `","parent_thread_id":"` + tRoot + `","pad":"` +
		string(make([]byte, childMetaBytes)) + `"}}` + "\n"
	writeChild(t, dated, tChild, long)
	_, ok, err = tr.ChildImportFile(tChild, []string{tRoot})
	require.NoError(t, err)
	assert.False(t, ok)
	require.NoError(t, os.Remove(p))

	// An archived child is found; a child of a linked sibling too.
	archived := writeChild(t, filepath.Join(home, "archived_sessions"), tChild, childHead(tChild, tOther))
	got, ok, err = tr.ChildImportFile(tChild, []string{tRoot, tOther})
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, archived, got)

	// A match that cannot be opened is an error, not "not found".
	require.NoError(t, os.Chmod(archived, 0o000))
	t.Cleanup(func() { _ = os.Chmod(archived, 0o600) })
	_, ok, err = tr.ChildImportFile(tChild, []string{tRoot, tOther})
	assert.False(t, ok)
	assert.Error(t, err)
}
