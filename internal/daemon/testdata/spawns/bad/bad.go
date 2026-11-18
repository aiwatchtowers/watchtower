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
