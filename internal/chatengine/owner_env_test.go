package chatengine

import (
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/aiconsent"
)

// captureCmd swaps startCmd for one that records each command and starts
// nothing.
func captureCmd(t *testing.T) *[]*exec.Cmd {
	t.Helper()
	var built []*exec.Cmd
	orig := startCmd
	startCmd = func(c *exec.Cmd) error {
		built = append(built, c)
		return errors.New("not started in a test")
	}
	t.Cleanup(func() { startCmd = orig })
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
		t.Fatal("execStart reported a start")
	}
	e := &Engine{c: Config{Exe: "watchtower"}}
	if _, err := e.listenStart([]string{"ai", "session", "--listen", filepath.Join(t.TempDir(), "s.sock")}); err == nil {
		t.Fatal("listenStart reported a start")
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
