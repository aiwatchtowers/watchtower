package spawns

import (
	"context"
	"os"
	"os/exec"

	"watchtower/internal/aiconsent"
)

func childEnv(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "watchtower", "digest", "generate")
	cmd.Env = append(aiconsent.OwnerEnv(os.Environ()), aiconsent.ChildEnv(ctx)...)
	return cmd.Start()
}

func agentEnv(ctx context.Context, runID int64) error {
	c := exec.Command("claude")
	c.Env = automationAgentEnv(ctx, runID)
	return c.Start()
}

func procAttr(ctx context.Context) (*os.Process, error) {
	return os.StartProcess("/usr/local/bin/watchtower", []string{"watchtower"}, &os.ProcAttr{Env: aiconsent.ChildEnv(ctx)})
}

func identity(pid string) ([]byte, error) {
	return exec.Command("ps", "-p", pid).Output()
}

var launcher = func(ctx context.Context) error {
	c := exec.Command("watchtower")
	c.Env = aiconsent.ChildEnv(ctx)
	return c.Start()
}

func automationAgentEnv(ctx context.Context, runID int64) []string { return aiconsent.ChildEnv(ctx) }
