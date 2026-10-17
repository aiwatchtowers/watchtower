package gittest

import (
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// TestDisableBackgroundGit_AppendsAndGitSeesIt checks that an entry already
// in GIT_CONFIG_COUNT survives and that git reads the added keys, and that
// core.fsmonitor is not among them.
func TestDisableBackgroundGit_AppendsAndGitSeesIt(t *testing.T) {
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.splitIndex")
	t.Setenv("GIT_CONFIG_VALUE_0", "false")
	// t.Setenv restores the keys DisableBackgroundGit writes.
	for i := range len(quietConfig) {
		n := strconv.Itoa(i + 1)
		t.Setenv("GIT_CONFIG_KEY_"+n, "")
		t.Setenv("GIT_CONFIG_VALUE_"+n, "")
	}
	DisableBackgroundGit()

	want := map[string]string{
		"core.splitindex":        "false",
		"maintenance.auto":       "false",
		"gc.auto":                "0",
		"gc.autodetach":          "false",
		"maintenance.autodetach": "false",
	}
	out, err := exec.Command(bin, "config", "--list", "--show-scope").Output()
	if err != nil {
		t.Fatalf("git config --list: %v", err)
	}
	got := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		scope, kv, _ := strings.Cut(line, "\t")
		if scope != "command" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		got[k] = v
	}
	if v, ok := got["core.fsmonitor"]; ok {
		t.Errorf("git sees core.fsmonitor=%q in the command scope: it would mask a repository's planted fsmonitor", v)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("git sees %s=%q in the command scope, want %q (all: %v)", k, got[k], v, got)
		}
	}
}
