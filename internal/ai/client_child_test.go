package ai

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// stubResult is a minimal valid `--output-format json` envelope.
const stubResult = `printf '%s' '{"type":"result","result":"ok","usage":{}}'` + "\n"

func TestBuildArgs_WatchtowerToolsPerTool(t *testing.T) {
	c := NewClient("m", "", "")
	c.SetWatchtowerTools([]string{"list_jira_issues", "create_target"})
	args, _, err := c.buildArgs("sys", "hi", "json", "")
	require.NoError(t, err)
	assert.Equal(t, "mcp__watchtower__list_jira_issues,mcp__watchtower__create_target",
		flagValue(t, args, "--allowedTools"))

	// A hostile name cannot inject a comma-separated token.
	c.SetWatchtowerTools([]string{"ok,Bash", "a b"})
	args, _, err = c.buildArgs("sys", "hi", "json", "")
	require.NoError(t, err)
	got := flagValue(t, args, "--allowedTools")
	assert.Equal(t, "mcp__watchtower__ok_Bash,mcp__watchtower__a_b", got)
	assert.Len(t, strings.Split(got, ","), 2)
}

func TestBuildArgs_MaxTurns(t *testing.T) {
	c := NewClient("m", "", "")
	c.SetMaxTurns(7)
	args, _, err := c.buildArgs("sys", "hi", "json", "")
	require.NoError(t, err)
	assert.Equal(t, "7", flagValue(t, args, "--max-turns"))
}

func TestBuildArgs_DefaultsUnchanged(t *testing.T) {
	c := NewClient("m", "", "")
	args, stdin, err := c.buildArgs("sys", "hi", "json", "")
	require.NoError(t, err)
	assert.Empty(t, stdin)
	assert.NotContains(t, args, "--max-turns")
	assert.Equal(t, []string{
		"-p", "hi",
		"--output-format", "json",
		"--model", "m",
		"--allowedTools", "mcp__watchtower",
		"--tools", c.builtinTools(),
		"--disallowedTools", DisallowedTools,
		"--setting-sources", c.settingSources(),
		"--strict-mcp-config",
		"--system-prompt", "sys",
	}, args)
}

func TestQuerySync_ChildEnvReplacesEnviron(t *testing.T) {
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("SLACK_TOKEN", "xoxp-fake")
	out := filepath.Join(t.TempDir(), "env.txt")
	c := NewClient("m", "", "")
	c.claudeCmd = writeMockClaude(t, "env > "+out+"\n"+stubResult)
	c.SetChildEnv([]string{"HOME=/tmp/acme-home", "FOO=bar"})

	_, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	require.NoError(t, err)

	data, err := os.ReadFile(out)
	require.NoError(t, err)
	var got []string
	for _, l := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		// the shell adds these itself
		if strings.HasPrefix(l, "PWD=") || strings.HasPrefix(l, "SHLVL=") || strings.HasPrefix(l, "_=") || strings.HasPrefix(l, "OLDPWD=") {
			continue
		}
		got = append(got, l)
	}
	require.Len(t, got, 3, "env: %v", got)
	assert.Contains(t, got, "HOME=/tmp/acme-home")
	assert.Contains(t, got, "FOO=bar")
	assert.Equal(t, 1, countPrefix(got, "PATH="))
	assert.NotContains(t, strings.Join(got, "\n"), "SLACK_TOKEN")
	assert.NotContains(t, strings.Join(got, "\n"), "CLAUDECODE")
}

func countPrefix(l []string, p string) int {
	n := 0
	for _, s := range l {
		if strings.HasPrefix(s, p) {
			n++
		}
	}
	return n
}

// groupStub starts-a-grandchild script: records its pgid-leader pid and the
// grandchild's pid, then waits. Cleanup kills the whole group.
func groupStub(t *testing.T) (script, pidFile string) {
	t.Helper()
	dir := t.TempDir()
	pidFile = filepath.Join(dir, "pid")
	script = "echo $$ > " + pidFile + ".tmp; mv " + pidFile + ".tmp " + pidFile + "\nsleep 60 &\nwait\n"
	t.Cleanup(func() {
		if pid := readPid(pidFile); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return script, pidFile
}

func readPid(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

func waitPid(t *testing.T, path string) int {
	t.Helper()
	require.Eventually(t, func() bool { return readPid(path) > 0 }, 5*time.Second, 20*time.Millisecond)
	return readPid(path)
}

func requireGroupGone(t *testing.T, pgid int) {
	t.Helper()
	require.Eventually(t, func() bool {
		return syscall.Kill(-pgid, 0) == syscall.ESRCH
	}, 10*time.Second, 50*time.Millisecond, "process group %d still alive", pgid)
}

func runGroupStub(t *testing.T, ctx context.Context, cancel context.CancelFunc, group bool) int {
	t.Helper()
	script, pidFile := groupStub(t)
	c := NewClient("m", "", "")
	c.claudeCmd = writeMockClaude(t, script)
	c.SetProcessGroup(group)
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	pgid := waitPid(t, pidFile)
	if cancel != nil {
		cancel()
	}
	select {
	case err := <-done:
		require.Error(t, err)
	case <-time.After(15 * time.Second):
		t.Fatal("QuerySync did not return")
	}
	return pgid
}

func TestCLIAgent_ProcessGroupKilledOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	requireGroupGone(t, runGroupStub(t, ctx, cancel, true))
}

func TestCLIAgent_ProcessGroupKilledOnDeadline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	requireGroupGone(t, runGroupStub(t, ctx, nil, true))
}
