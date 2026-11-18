package spawns

import (
	"os"
	"os/exec"
)

// launch passes the caller's origin env on.
func launch(exe string, originEnv []string) error {
	c := exec.Command(exe, "workbench", "spec-review", "run")
	c.Env = append(os.Environ(), originEnv...)
	return c.Start()
}
