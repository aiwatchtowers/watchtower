package agentfiles

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSubagentsDir(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"/tmp/p/-tmp-w/0000.jsonl", "/tmp/p/-tmp-w/0000/subagents"},
		{"relative/0000.jsonl", ""},
		{"/tmp/p/0000.txt", ""},
		{"", ""},
		{"/.jsonl", ""},
	} {
		if got := SubagentsDir(tc.in); got != tc.want {
			t.Errorf("SubagentsDir(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSubagentParent(t *testing.T) {
	dir := t.TempDir()
	write := func(id, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "agent-"+id+".meta.json"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("a01", `{"agentType":"general-purpose","description":"x","spawnDepth":1}`)
	write("a02", `{"agentType":"codex-wrapper","parentAgentId":"a01","spawnDepth":2}`)
	write("a03", `{"parentAgentId":"a03"}`)
	write("a04", `{"parentAgentId":"../x"}`)
	write("a05", `not json`)
	write("a06", `{"parentAgentId":7}`)
	write("a07", `{"parentAgentId":"`+strings.Repeat("b", int(maxMetaBytes))+`"}`)
	if err := os.Symlink(filepath.Join(dir, "agent-a02.meta.json"), filepath.Join(dir, "agent-a08.meta.json")); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ dir, id, want string }{
		{dir, "a01", ""},
		{dir, "a02", "a01"},
		{dir, "a03", ""},    // itself
		{dir, "a04", ""},    // not a plain id
		{dir, "a05", ""},    // invalid
		{dir, "a06", ""},    // not a string
		{dir, "a07", ""},    // too large
		{dir, "a08", ""},    // a symlink
		{dir, "a09", ""},    // missing
		{dir, "../a02", ""}, // a path, never followed
		{"", "a02", ""},
	} {
		if got := SubagentParent(tc.dir, tc.id); got != tc.want {
			t.Errorf("SubagentParent(%q) = %q, want %q", tc.id, got, tc.want)
		}
	}
}
