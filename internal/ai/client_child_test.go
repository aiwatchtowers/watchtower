package ai

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/providers"
)

// stubResult is a minimal valid `--output-format json` envelope.
const stubResult = `printf '%s' '{"type":"result","result":"ok","usage":{}}'` + "\n"

func TestBuildArgs_WatchtowerToolsPerTool(t *testing.T) {
	c := NewClient("m", "", "")
	c.SetWatchtowerTools([]string{"list_jira_issues", "create_target"})
	args, _, err := buildArgsT(t, c, "sys", "hi", "json")
	require.NoError(t, err)
	assert.Equal(t, "mcp__watchtower__list_jira_issues,mcp__watchtower__create_target",
		flagValue(t, args, "--allowedTools"))

	// A hostile name cannot inject a comma-separated token.
	c.SetWatchtowerTools([]string{"ok,Bash", "a b"})
	args, _, err = buildArgsT(t, c, "sys", "hi", "json")
	require.NoError(t, err)
	got := flagValue(t, args, "--allowedTools")
	assert.Equal(t, "mcp__watchtower__ok_Bash,mcp__watchtower__a_b", got)
	assert.Len(t, strings.Split(got, ","), 2)
}

func TestBuildArgs_WatchtowerToolsEmptyGrantsNone(t *testing.T) {
	for _, names := range [][]string{nil, {}} {
		c := NewClient("m", "", "")
		c.SetWatchtowerTools(names)
		args, _, err := buildArgsT(t, c, "sys", "hi", "json")
		require.NoError(t, err)
		assert.Equal(t, "", flagValue(t, args, "--allowedTools"))
	}
	// External tokens follow with no leading comma.
	c := NewClient("m", "", "")
	c.SetWatchtowerTools(nil)
	c.SetExternalMCPServers([]ExternalMCPServer{{Name: "github", AllowTools: []string{"get_issue"}}})
	args, _, err := buildArgsT(t, c, "sys", "hi", "json")
	require.NoError(t, err)
	assert.Equal(t, "mcp__github__get_issue", flagValue(t, args, "--allowedTools"))
}

func TestBuildArgs_MaxTurns(t *testing.T) {
	c := NewClient("m", "", "")
	c.SetMaxTurns(7)
	args, _, err := buildArgsT(t, c, "sys", "hi", "json")
	require.NoError(t, err)
	assert.Equal(t, "7", flagValue(t, args, "--max-turns"))
}

func TestBuildArgs_DefaultsUnchanged(t *testing.T) {
	c := NewClient("m", "", "")
	args, stdin, err := buildArgsT(t, c, "sys", "hi", "json")
	require.NoError(t, err)
	assert.Equal(t, "hi", stdin)
	assert.NotContains(t, args, "--max-turns")
	assert.Equal(t, []string{
		"-p",
		"--output-format", "json",
		"--model", "m",
		"--allowedTools", "mcp__watchtower",
		"--tools", c.builtinTools(),
		"--disallowedTools", DisallowedTools,
		"--setting-sources", c.settingSources(),
		"--strict-mcp-config",
		"--no-session-persistence",
		"--system-prompt-file", flagValue(t, args, "--system-prompt-file"),
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
	for l := range strings.SplitSeq(strings.TrimSpace(string(data)), "\n") {
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

// runGroupStub runs QuerySync over a stub that starts a grandchild and
// waits, ends ctx (end, once the stub runs) and returns the call's error
// once QuerySync has returned and the whole group has exited. A background
// job of a non-interactive sh ignores SIGINT, so the grace timer may be what
// ends the sleep; the test's grace is short.
func runGroupStub(t *testing.T, ctx context.Context, end func()) error {
	t.Helper()
	setGroupKillGrace(t, 10*time.Millisecond)
	g := newGroupFIFO(t)
	c := NewClient("m", "", "")
	c.claudeCmd = writeMockClaude(t, g.prefix()+"sleep 60 &\nwait\n")
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	g.waitPID(t)
	end()
	err := <-done
	g.waitGone(t) // the sleep it left behind goes with it
	return err
}

func TestCLIAgent_ProcessGroupKilledOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	err := runGroupStub(t, ctx, cancel)
	require.Error(t, err)
	assert.Equal(t, providers.Cancelled, failureCategory(t, err))
}

func TestCLIAgent_ProcessGroupKilledOnDeadline(t *testing.T) {
	// The deadline fires once the stub runs; no real clock behind it.
	ctx := newFiredDeadline()
	err := runGroupStub(t, ctx, ctx.fire)
	require.Error(t, err)
	assert.Equal(t, providers.Timeout, failureCategory(t, err))
}

// A group that ignores SIGINT is SIGKILLed after the grace (GroupKillGrace in
// production, which stays under the automation sandbox's 2 s AbandonGrace),
// so the call returns with the whole group dead. The test's grace is short:
// what it checks is that the timer's SIGKILL is what ends the group.
func TestCLIAgent_SIGINTIgnoringGroupKilledWithinGrace(t *testing.T) {
	require.Less(t, GroupKillGrace, 2*time.Second, "the grace stays under the sandbox's AbandonGrace")
	setGroupKillGrace(t, 10*time.Millisecond)
	g := newGroupFIFO(t)
	c := NewClient("m", "", "")
	c.claudeCmd = writeMockClaude(t, "trap '' INT\n"+g.prefix()+"sleep 60 &\nwait\nsleep 60\n")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	g.waitPID(t)
	cancel()
	require.Error(t, <-done)
	g.waitGone(t)
}

// A cancelled group whose leader exits at once on SIGINT while a grandchild
// ignores it is killed when the call returns, not when the kill timer would
// have fired: ConfigureChild's reap sends the pending SIGKILL and stops the
// timer, so nothing signals the group id after the call. The grace is an
// hour here, so a group that is gone was ended by the reap.
func TestCLIAgent_GroupReapedWhenWaitReturns(t *testing.T) {
	setGroupKillGrace(t, time.Hour)
	g := newGroupFIFO(t)
	script := "trap 'exit 1' INT\n" + g.prefix() + "(trap '' INT; exec sleep 60) >/dev/null 2>&1 </dev/null &\nwait\n"
	c := NewClient("m", "", "")
	c.claudeCmd = writeMockClaude(t, script)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := c.QuerySync(ctx, "sys", "hi", "")
		done <- err
	}()
	g.waitPID(t)
	cancel()
	require.Error(t, <-done)
	g.waitGone(t) // the SIGINT-ignoring grandchild did not outlive the call
}

func failureCategory(t *testing.T, err error) providers.ErrorCategory {
	t.Helper()
	var f *providers.Failure
	require.ErrorAs(t, err, &f)
	return f.Category
}
