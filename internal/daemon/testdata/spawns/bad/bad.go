package spawns

import (
	"context"
	"os"
	"os/exec"

	"watchtower/internal/aiconsent"
)

// bareSpawn starts a model command with the daemon's own environment: the
// child cannot tell which background unit started it.
func bareSpawn() error {
	return exec.Command("watchtower", "digest", "generate").Start()
}

// childEnv is fine: the checker must not report it.
func childEnv(ctx context.Context) error {
	cmd := exec.Command("watchtower", "digest", "generate")
	cmd.Env = append(aiconsent.OwnerEnv(os.Environ()), aiconsent.ChildEnv(ctx)...)
	return cmd.Start()
}

// mixed holds one good and one bad spawn of each kind: each is judged by its
// own env, never by another spawn's in the same function.
func mixed(ctx context.Context) {
	_, _ = os.StartProcess("/usr/local/bin/watchtower", nil, &os.ProcAttr{Env: aiconsent.ChildEnv(ctx)})
	_, _ = os.StartProcess("/usr/local/bin/watchtower", nil, &os.ProcAttr{Env: os.Environ()})
	attr := &os.ProcAttr{}
	attr.Env = aiconsent.ChildEnv(ctx)
	_, _ = os.StartProcess("/usr/local/bin/watchtower", nil, attr)
	good := &exec.Cmd{Path: "/usr/local/bin/watchtower", Env: aiconsent.ChildEnv(ctx)}
	bad := &exec.Cmd{Path: "/usr/local/bin/watchtower"}
	_, _ = good.Output(), bad.Output()
}
