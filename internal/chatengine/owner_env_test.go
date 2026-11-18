package chatengine

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/aiconsent"
)

// captureCmd swaps newCmd for one that records the *exec.Cmd it builds and
// points it at a program that does not exist, so nothing starts.
func captureCmd(t *testing.T) *[]*exec.Cmd {
	t.Helper()
	var built []*exec.Cmd
	missing := filepath.Join(t.TempDir(), "no-such-watchtower")
	orig := newCmd
	newCmd = func(_ string, args ...string) *exec.Cmd {
		c := exec.Command(missing, args...) //nolint:gosec // G204: a test path
		built = append(built, c)
		return c
	}
	t.Cleanup(func() { newCmd = orig })
	return &built
}

// BGAI-02, Decision 3: each chat spawn serves one owner turn, so the child
// runs as owner even when the daemon hosting the engine was itself started
// by a background unit: neither consent name reaches its env.
func TestBGAI02_ChatEngineChildIsOwner(t *testing.T) {
	t.Setenv(aiconsent.EnvOrigin, "background")
	t.Setenv(aiconsent.EnvAdmitted, "x")
	built := captureCmd(t)

	if _, err := execStart("watchtower")([]string{"ai", "session"}); err == nil {
		t.Fatal("execStart started a program that does not exist")
	}
	e := &Engine{c: Config{Exe: "watchtower"}}
	if _, err := e.listenStart([]string{"ai", "session", "--listen", filepath.Join(t.TempDir(), "s.sock")}); err == nil {
		t.Fatal("listenStart started a program that does not exist")
	}

	if len(*built) != 2 {
		t.Fatalf("built %d commands, want 2 (execStart, listenStart)", len(*built))
	}
	for i, c := range *built {
		if c.Env == nil {
			t.Fatalf("command %d inherits the daemon's env (Env nil), want aiconsent.OwnerEnv", i)
		}
		for _, kv := range c.Env {
			if strings.HasPrefix(kv, aiconsent.EnvOrigin+"=") || strings.HasPrefix(kv, aiconsent.EnvAdmitted+"=") {
				t.Errorf("command %d env carries %q; a chat child is an owner turn", i, kv)
			}
		}
		if !hasEnv(c.Env, "PATH") {
			t.Errorf("command %d dropped the rest of the env", i)
		}
	}
}

func hasEnv(env []string, name string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, name+"=") {
			return true
		}
	}
	return false
}
