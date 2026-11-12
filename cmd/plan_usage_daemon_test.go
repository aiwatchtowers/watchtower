package cmd

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"

	"github.com/stretchr/testify/require"
)

// Run the production provider in a fresh process: Codex's login-shell PATH is
// cached, so changing it in the test runner would affect unrelated tests.
func TestPlanProviders_CodexRuntimePATH(t *testing.T) {
	if os.Getenv("WT_PLAN_USAGE_PATH_HELPER") == "1" {
		cfg, err := config.Load(flagConfig)
		require.NoError(t, err)
		database, err := openDBFromConfig()
		require.NoError(t, err)
		defer database.Close()
		for _, provider := range newPlanProviders(database, cfg, nil) {
			if provider.Name != "codex" {
				continue
			}
			require.NoError(t, provider.Refresh(context.Background()))
			status, err := database.GetCodexPlanUsageStatus()
			require.NoError(t, err)
			require.NotNil(t, status)
			require.Equal(t, "ok", status.State)
			require.Equal(t, "pro", status.Plan)
			require.Contains(t, status.LimitsJSON, `"percent":37`)
			return
		}
		t.Fatal("Codex provider missing")
	}

	home := t.TempDir()
	binDir := filepath.Join(home, "runtime")
	require.NoError(t, os.MkdirAll(binDir, 0700))
	// The CLI needs an interpreter outside the app's minimal PATH, as an
	// npm-installed Codex needs node from nvm/volta/fnm.
	cli := filepath.Join(home, "codex")
	require.NoError(t, os.WriteFile(cli, []byte("#!/usr/bin/env wt-test-node\n"), 0700))
	runtime := `#!/bin/sh
while IFS= read -r message; do
  case "$message" in
    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{"userAgent":"fake/0"}}' ;;
    *'"method":"account/read"'*) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"}}}' ;;
    *'"method":"account/rateLimits/read"'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":300}}}}' ;;
  esac
done
`
	require.NoError(t, os.WriteFile(filepath.Join(binDir, "wt-test-node"), []byte(runtime), 0700))
	loginShell := filepath.Join(home, "login-shell")
	require.NoError(t, os.WriteFile(loginShell, []byte("#!/bin/sh\nprintf '%s\\n' \"$WT_PLAN_USAGE_RUNTIME_PATH\"\n"), 0700))
	configDir := filepath.Join(home, ".config", "watchtower")
	require.NoError(t, os.MkdirAll(configDir, 0700))
	configPath := filepath.Join(configDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\ncodex_path: "+cli+"\nplan_usage:\n  enabled: true\n"), 0600))

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPlanProviders_CodexRuntimePATH$")
	child.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1", "WT_PLAN_USAGE_PATH_HELPER=1",
		"HOME="+home, "CODEX_HOME="+filepath.Join(home, ".codex"), "SHELL="+loginShell,
		"PATH=/usr/bin:/bin", "WT_PLAN_USAGE_RUNTIME_PATH="+binDir+":/usr/bin:/bin")
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	child.Cancel = func() error { return syscall.Kill(-child.Process.Pid, syscall.SIGKILL) }
	t.Cleanup(func() {
		if child.Process != nil {
			_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
		}
	})
	output, err := child.CombinedOutput()
	require.NoError(t, err, "%s", output)
}
