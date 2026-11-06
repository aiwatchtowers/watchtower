package daemon

import (
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// fakeCLIEnv names the folder whose <name>.response file the fake CLI prints.
const fakeCLIEnv = "WATCHTOWER_DAEMON_FAKE_CLI_DIR"

// runFakeCLIIfAsked turns the test binary into a fake provider CLI when it is
// started through a fakeCLI link: it drains stdin, prints the response stored
// for the name it was called by, and exits. TestMain calls it first.
func runFakeCLIIfAsked() {
	dir := os.Getenv(fakeCLIEnv)
	if dir == "" {
		return
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
	out, err := os.ReadFile(filepath.Join(dir, filepath.Base(os.Args[0])+".response"))
	if err != nil {
		os.Exit(2)
	}
	_, _ = os.Stdout.Write(out)
	os.Exit(0)
}

// fakeCLI returns a path that runs as a provider CLI printing response. It is
// a symlink to the running test binary, not a fresh script: macOS checks every
// new executable on its first run, which costs up to a second per file.
func fakeCLI(t *testing.T, name, response string) string {
	t.Helper()
	dir := os.Getenv(fakeCLIEnv)
	if dir == "" {
		dir = t.TempDir()
		t.Setenv(fakeCLIEnv, dir)
	}
	self, err := os.Executable()
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, name+".response"), []byte(response), 0o600))
	bin := filepath.Join(dir, name)
	require.NoError(t, os.Symlink(self, bin))
	return bin
}
