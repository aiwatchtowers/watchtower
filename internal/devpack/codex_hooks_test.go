package devpack

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pelletier/go-toml/v2"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

var updateCodexGolden = flag.Bool("update", false, "rewrite testdata/codex_launch_args.golden")

// goldenWatchtowerBin is the watchtower path the golden launch args are built
// for: the CLI store path, with the space the quoting must survive.
const goldenWatchtowerBin = "/Users/example/Library/Application Support/Watchtower/bin/watchtower"

type codexHookGroup struct {
	Matcher string `toml:"matcher"`
	Hooks   []struct {
		Type    string `toml:"type"`
		Command string `toml:"command"`
		Timeout int    `toml:"timeout"`
	} `toml:"hooks"`
}

// decodeTOMLValue decodes value as the right side of `v = value`, strictly.
func decodeTOMLValue[T any](t *testing.T, value string, into *T) {
	t.Helper()
	var doc struct {
		V T `toml:"v"`
	}
	dec := toml.NewDecoder(strings.NewReader("v = " + value + "\n"))
	dec.DisallowUnknownFields()
	require.NoError(t, dec.Decode(&doc), "value %s", value)
	*into = doc.V
}

// splitOverride splits a "-c" pair's value into key and TOML value.
func splitOverride(t *testing.T, kv string) (string, string) {
	t.Helper()
	k, v, ok := strings.Cut(kv, "=")
	require.True(t, ok, "override %q has no '='", kv)
	return k, v
}

func TestCodexHookSet_GoldenOrderAndTimeouts(t *testing.T) {
	type row struct {
		event, matcher string
		timeout, group int
	}
	want := []row{
		{"SessionStart", "", 10, 0}, {"UserPromptSubmit", "", 5, 0}, {"PermissionRequest", "", 5, 0},
		{"PostToolUse", "", 5, 0}, {"SubagentStart", "", 5, 0}, {"SubagentStop", "", 5, 0},
		{"PreToolUse", "request_user_input", 5, 0}, {"Stop", "", 15, 0}, {"Stop", "", 30, 1},
	}
	hooks := CodexHookSet("/usr/local/bin/watchtower")
	got := make([]row, 0, len(hooks))
	for _, h := range hooks {
		got = append(got, row{h.Event, h.Matcher, h.TimeoutSec, h.Group})
	}
	assert.Equal(t, want, got)
	assert.Equal(t, "/usr/local/bin/watchtower workbench check --agent codex --stop-hook", hooks[7].Command)
	assert.Equal(t, "/usr/local/bin/watchtower workbench ask-guard --agent codex --stop", hooks[8].Command)

	assertCodexLaunchArgsGolden(t)
}

// assertCodexLaunchArgsGolden pins the full launch argv, one arg per line.
func assertCodexLaunchArgsGolden(t *testing.T) {
	t.Helper()
	codexBin := filepath.Join(t.TempDir(), "codex")
	require.NoError(t, os.WriteFile(codexBin, []byte("#!/bin/sh\n"), 0o755))
	la, err := CodexLaunchArgs(&config.Config{}, goldenWatchtowerBin, 7, func() (string, error) { return codexBin, nil })
	require.NoError(t, err)
	got := strings.Join(la.Args, "\n") + "\n"
	path := filepath.Join("testdata", "codex_launch_args.golden")
	if *updateCodexGolden {
		require.NoError(t, os.WriteFile(path, []byte(got), 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run with -update to create")
	assert.Equal(t, string(want), got)
}

func TestCodexHookSet_CommandsAreWorkbenchAgnostic(t *testing.T) {
	for _, h := range CodexHookSet("/usr/local/bin/watchtower") {
		assert.NotContains(t, h.Command, "--workbench", h.Event)
		assert.NotContains(t, h.Command, "--project", h.Event)
		assert.Contains(t, h.Command, " --agent codex", h.Event)
	}
	// The workbench changes the MCP flags only, never the hook flags.
	a, err := CodexLaunchArgs(nil, "/w", 1, fakeCodex(t))
	require.NoError(t, err)
	b, err := CodexLaunchArgs(nil, "/w", 2, fakeCodex(t))
	require.NoError(t, err)
	hooksOnly := func(args []string) []string { return args[len(args)-2*8:] }
	assert.Equal(t, hooksOnly(a.Args), hooksOnly(b.Args))
}

func fakeCodex(t *testing.T) func() (string, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "codex")
	require.NoError(t, os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755))
	return func() (string, error) { return p, nil }
}

// TestCodexHookSet_BinWithSpacesIsQuoted runs every hook command through
// /bin/sh after a TOML round trip: the shell quoting nested in the TOML
// string must hand the binary its exact path and arguments.
func TestCodexHookSet_BinWithSpacesIsQuoted(t *testing.T) {
	for _, dirName := range []string{"Application Support", `it's "here"`, `back\slash $HOME`} {
		t.Run(dirName, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), dirName, "bin")
			require.NoError(t, os.MkdirAll(dir, 0o755))
			bin := filepath.Join(dir, "watchtower")
			require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\nprintf '%s|' \"$0\" \"$@\"\n"), 0o755))
			assertHookCommandsRun(t, bin)
		})
	}
}

func assertHookCommandsRun(t *testing.T, bin string) {
	t.Helper()
	hooks := CodexHookSet(bin)
	overrides := CodexHookOverrides(hooks)
	i := 0
	for j := 1; j < len(overrides); j += 2 {
		_, value := splitOverride(t, overrides[j])
		var groups []codexHookGroup
		decodeTOMLValue(t, value, &groups)
		for _, g := range groups {
			for _, h := range g.Hooks {
				out, err := exec.Command("/bin/sh", "-c", h.Command).Output()
				require.NoError(t, err, h.Command)
				wantArgs := strings.TrimPrefix(hooks[i].Command, shellQuote(bin)+" ")
				assert.Equal(t, bin+"|"+strings.ReplaceAll(wantArgs, " ", "|")+"|", string(out))
				i++
			}
		}
	}
	assert.Equal(t, len(hooks), i)
}

func TestCodexHookOverrides_ParseAsTOML(t *testing.T) {
	hooks := CodexHookSet("/usr/local/bin/watchtower")
	overrides := CodexHookOverrides(hooks)
	require.Len(t, overrides, 2*8, "one -c pair per event")
	i := 0
	for j := 0; j < len(overrides); j += 2 {
		require.Equal(t, "-c", overrides[j])
		key, value := splitOverride(t, overrides[j+1])
		var groups []codexHookGroup
		decodeTOMLValue(t, value, &groups)
		for gi, g := range groups {
			require.Len(t, g.Hooks, 1)
			want := hooks[i]
			assert.Equal(t, "hooks."+want.Event, key)
			assert.Equal(t, want.Group, gi)
			assert.Equal(t, want.Matcher, g.Matcher)
			assert.Equal(t, "command", g.Hooks[0].Type)
			assert.Equal(t, want.Command, g.Hooks[0].Command)
			assert.Equal(t, want.TimeoutSec, g.Hooks[0].Timeout)
			i++
		}
	}
	assert.Equal(t, len(hooks), i)
	// No matcher key at all on an unmatched group (codex reads "" as a matcher).
	assert.NotContains(t, overrides[1], "matcher")
}

func TestCodexHookOverrides_Degenerate(t *testing.T) {
	assert.Empty(t, CodexHookOverrides(nil))
	// Two handlers of one event and group share the group, in order.
	got := CodexHookOverrides([]CodexHook{
		{Event: "Stop", Command: "a", TimeoutSec: 1, Group: 1},
		{Event: "Stop", Command: "b", TimeoutSec: 2, Group: 0},
		{Event: "Stop", Command: "c", TimeoutSec: 3, Group: 1},
	})
	assert.Equal(t, []string{"-c",
		`hooks.Stop=[{hooks=[{type="command",command="b",timeout=2}]},` +
			`{hooks=[{type="command",command="a",timeout=1},{type="command",command="c",timeout=3}]}]`}, got)
}

func TestTOMLString_EscapesRoundTrip(t *testing.T) {
	for _, s := range []string{"", `a"b`, `c:\path`, "tab\there", "nl\nx", "bell\a", "del\x7f", "ünï"} {
		var got string
		decodeTOMLValue(t, tomlString(s), &got)
		assert.Equal(t, s, got)
	}
}

func TestCodexMCPOverrides_IncludeApproveAndAgentFlag(t *testing.T) {
	bin := `/Users/example/Library/Application Support/it's/watchtower`
	overrides := CodexMCPOverrides(bin, 42)
	require.Len(t, overrides, 8)
	values := map[string]string{}
	for j := 0; j < len(overrides); j += 2 {
		require.Equal(t, "-c", overrides[j])
		k, v := splitOverride(t, overrides[j+1])
		values[k] = v
	}
	var command, mode string
	var args, envVars []string
	decodeTOMLValue(t, values["mcp_servers.watchtower-workbench.command"], &command)
	decodeTOMLValue(t, values["mcp_servers.watchtower-workbench.args"], &args)
	decodeTOMLValue(t, values["mcp_servers.watchtower-workbench.default_tools_approval_mode"], &mode)
	decodeTOMLValue(t, values["mcp_servers.watchtower-workbench.env_vars"], &envVars)
	assert.Equal(t, bin, command, "the MCP command is exec'd, not shell-run: no shell quoting")
	assert.Equal(t, []string{"mcp", "--workbench", "42", "--agent", "codex"}, args)
	assert.Equal(t, "approve", mode)
	// Codex starts MCP servers with a filtered environment.
	assert.Equal(t, []string{"WATCHTOWER_TERMINAL_SESSION_ID"}, envVars)
}

func TestCodexLaunchArgs_Resolution(t *testing.T) {
	configured := fakeCodex(t)
	cfgPath, _ := configured()
	found := fakeCodex(t)
	foundPath, _ := found()
	missing := func() (string, error) { t.Fatal("find must not run when codex_path names a file"); return "", nil }

	la, err := CodexLaunchArgs(&config.Config{CodexPath: cfgPath}, "/w", 1, missing)
	require.NoError(t, err)
	assert.Equal(t, cfgPath, la.Binary)
	assert.Equal(t, filepath.Dir(cfgPath), la.PathPrepend)
	assert.Equal(t, "--no-daemon", la.Args[0])

	for _, stale := range []string{"", "/nonexistent/codex", "codex", filepath.Dir(foundPath)} {
		la, err = CodexLaunchArgs(&config.Config{CodexPath: stale}, "/w", 1, found)
		require.NoError(t, err, stale)
		assert.Equal(t, foundPath, la.Binary, stale)
	}
}

func TestCodexLaunchArgs_NotFound(t *testing.T) {
	for name, find := range map[string]func() (string, error){
		"bare codex": func() (string, error) { return "codex", nil },
		"empty":      func() (string, error) { return "", nil },
		"gone":       func() (string, error) { return "/nonexistent/codex", nil },
		"a dir":      func() (string, error) { return t.TempDir(), nil },
		"error":      func() (string, error) { return "", ErrCodexNotFound },
	} {
		_, err := CodexLaunchArgs(&config.Config{}, "/w", 1, find)
		assert.ErrorIs(t, err, ErrCodexNotFound, name)
	}
}
