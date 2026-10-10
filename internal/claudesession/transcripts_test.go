package claudesession

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const otherID = "00000000-0000-4000-8000-000000000999"

func touch(t *testing.T, path string, mtime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func TestLatestSubagentWriteNewestAgentFileWins(t *testing.T) {
	configDir := t.TempDir()
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	projects := filepath.Join(configDir, "projects")
	touch(t, filepath.Join(projects, "-tmp-a", busyID, "subagents", "agent-a.jsonl"), base)
	touch(t, filepath.Join(projects, "-tmp-b", busyID, "subagents", "agent-b.jsonl"), base.Add(10*time.Minute))
	// Newer, but not an agent transcript.
	touch(t, filepath.Join(projects, "-tmp-a", busyID, "subagents", "notes.txt"), base.Add(20*time.Minute))
	// Newer, but another session's.
	touch(t, filepath.Join(projects, "-tmp-a", otherID, "subagents", "agent-c.jsonl"), base.Add(30*time.Minute))

	got, ok := LatestSubagentWrite(configDir, busyID)
	if !ok || !got.Equal(base.Add(10*time.Minute)) {
		t.Errorf("LatestSubagentWrite = %v, %v; want %v, true", got, ok, base.Add(10*time.Minute))
	}

	if _, ok := LatestSubagentWrite(configDir, idleID); ok {
		t.Error("session without subagent transcripts: found")
	}
	if _, ok := LatestSubagentWrite(t.TempDir(), busyID); ok {
		t.Error("no projects dir: found")
	}
}

// An id that is not a session id never reaches the glob: the files the
// escaped pattern would match exist, yet nothing is found.
func TestLatestSubagentWriteRejectsAnInvalidSessionID(t *testing.T) {
	configDir := t.TempDir()
	projects := filepath.Join(configDir, "projects")
	now := time.Now()
	// projects/*/../x/subagents → projects/x/subagents.
	touch(t, filepath.Join(projects, "x", "subagents", "agent-a.jsonl"), now)
	// projects/*/a/b/subagents.
	touch(t, filepath.Join(projects, "p", "a", "b", "subagents", "agent-a.jsonl"), now)

	for _, id := range []string{"../x", "a/b", "", "*", busyID + "/.."} {
		if got, ok := LatestSubagentWrite(configDir, id); ok {
			t.Errorf("LatestSubagentWrite(%q) = %v, true; want not found", id, got)
		}
	}
}
