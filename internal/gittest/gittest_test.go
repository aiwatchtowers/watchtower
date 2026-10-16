package gittest

import (
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// TestDisableBackgroundGit_AppendsAndGitSeesIt checks that an entry already
// in GIT_CONFIG_COUNT survives and that git reads the added keys.
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

	want := map[string]string{"core.splitindex": "false"}
	for _, kv := range quietConfig {
		want[strings.ToLower(kv[0])] = kv[1]
	}
	out, err := exec.Command(bin, "config", "--list", "--show-scope").Output()
	if err != nil {
		t.Fatalf("git config --list: %v", err)
	}
	got := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		scope, kv, _ := strings.Cut(line, "\t")
		if scope != "command" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		got[k] = v
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("git sees %s=%q in the command scope, want %q (all: %v)", k, got[k], v, got)
		}
	}
}
