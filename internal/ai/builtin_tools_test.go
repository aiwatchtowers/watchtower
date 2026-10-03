package ai

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/claude"
)

// approvedChatBuiltins pins, per chat run, every Claude Code built-in tool the
// model may see. Changing it is an owner decision: a built-in here is
// reachable from prompt-injected synced content.
//   - ToolSearch (every chat): loads the deferred watchtower tool schemas;
//   - WebSearch (warm `ai session` only, the main chat): public web search,
//     the SessionDisallowedTools rule — WebFetch stays hidden everywhere.
var approvedChatBuiltins = map[string][]string{
	"one-shot ai query": {"ToolSearch"},
	"warm ai session":   {"ToolSearch", "WebSearch"},
}

// chatBuiltinRuns is each chat run's built-in allowlist (--tools) and deny
// list (--disallowedTools), as buildArgs and cmd/ai_session.go pass them.
var chatBuiltinRuns = map[string]struct{ tools, deny string }{
	"one-shot ai query": {ChatBuiltinTools, DisallowedTools},
	"warm ai session":   {SessionBuiltinTools, SessionDisallowedTools},
}

const builtinsSnapshot = "testdata/claude_builtins.txt"

// knownBuiltins reads the pinned snapshot of the CLI's built-in tool names.
func knownBuiltins(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(builtinsSnapshot)
	require.NoError(t, err)
	var names []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "#") {
			names = append(names, line)
		}
	}
	require.NotEmpty(t, names)
	return names
}

// exposedBuiltins is what a run shows the model out of the built-ins in
// names: allowed by --tools and not hidden by --disallowedTools.
func exposedBuiltins(names []string, tools, deny string) []string {
	allow, hidden := strings.Split(tools, ","), strings.Split(deny, ",")
	var out []string
	for _, n := range names {
		if slices.Contains(allow, n) && !slices.Contains(hidden, n) {
			out = append(out, n)
		}
	}
	return out
}

// TestChatBuiltins_OnlyApprovedNamesExposed: every chat run exposes exactly
// its approved built-ins, out of every built-in the CLI is known to have — a
// new built-in in the snapshot is not exposed unless --tools names it. Every
// --tools name must be a known built-in (a typo or a CLI rename would
// otherwise silently drop a tool the chat relies on).
func TestChatBuiltins_OnlyApprovedNamesExposed(t *testing.T) {
	known := knownBuiltins(t)
	for run, r := range chatBuiltinRuns {
		for _, n := range strings.Split(r.tools, ",") {
			assert.Contains(t, known, n, "%s: --tools names %q, which is not a known built-in", run, n)
			assert.Contains(t, approvedChatBuiltins[run], n, "%s: --tools names unapproved %q", run, n)
		}
		assert.ElementsMatch(t, approvedChatBuiltins[run], exposedBuiltins(known, r.tools, r.deny),
			"%s: exposed built-ins differ from the approved set", run)
	}
	assert.NotContains(t, strings.Split(ChatBuiltinTools, ","), WebSearchTool,
		"web search is the warm main-chat session's alone")
	assert.NotContains(t, strings.Split(SessionBuiltinTools, ","), "WebFetch",
		"WebFetch (arbitrary URL fetch, the exfiltration channel) is never allowed")
}

// TestChatBuiltins_DenyListCoversSnapshot: the deny list, defence in depth
// behind --tools, hides every known built-in a run does not approve, so even
// a CLI that ignored --tools would expose nothing new.
func TestChatBuiltins_DenyListCoversSnapshot(t *testing.T) {
	known := knownBuiltins(t)
	for run, r := range chatBuiltinRuns {
		hidden := strings.Split(r.deny, ",")
		for _, n := range known {
			if !slices.Contains(approvedChatBuiltins[run], n) {
				assert.Contains(t, hidden, n, "%s: built-in %q is neither approved nor in the deny list", run, n)
			}
		}
	}
}

// TestBuildArgs_ToolsAllowlist: every one-shot spawn — fresh, resumed, or
// with the prompt on stdin — passes the built-in allowlist exactly once.
func TestBuildArgs_ToolsAllowlist(t *testing.T) {
	cases := map[string]struct{ msg, session string }{
		"fresh":   {"hi", ""},
		"resume":  {"hi", "sess-1"},
		"stdin":   {"-dash-led", ""},
		"chatMCP": {"hi", ""},
	}
	for name, c := range cases {
		cl := NewClient("sonnet", "/tmp/w.db", "")
		if name == "chatMCP" {
			cl.SetMCPArgs([]string{"--chat", "--surface", "target"})
			cl.SetExternalMCPServers([]ExternalMCPServer{{Name: "acme", Kind: "stdio", Command: "x",
				AllowTools: []string{"getIssue"}, DenyTools: []string{"createIssue"}}})
		}
		args, _, err := cl.buildArgs("sys", c.msg, "stream-json", c.session)
		require.NoError(t, err, name)
		assertFlagValue(t, args, "--tools", ChatBuiltinTools)
		n := 0
		for _, a := range args {
			if a == "--tools" {
				n++
			}
		}
		assert.Equal(t, 1, n, "%s: --tools passed once", name)
	}
}

// liveCheckEnv opts into TestChatBuiltins_LiveCLI ("check" or "update"); see
// scripts/check-claude-builtins.sh.
const liveCheckEnv = "WATCHTOWER_CHECK_CLAUDE_BUILTINS"

// TestChatBuiltins_LiveCLI checks the locally installed claude CLI (opt-in,
// never in CI): its full built-in set must be in the pinned snapshot ("update"
// adds the missing names), and launched with each chat run's real argv it
// must expose exactly that run's approved built-ins. The CLI has no offline tool
// listing, so each launch is a real `claude -p` run read up to its init
// event and then killed.
func TestChatBuiltins_LiveCLI(t *testing.T) {
	mode := os.Getenv(liveCheckEnv)
	if mode == "" {
		t.Skipf("set %s=check (or update) to compare against the installed claude CLI", liveCheckEnv)
	}
	bin := claude.FindBinary("")
	require.NotEmpty(t, bin, "claude CLI not found")

	all := builtinNames(liveInitTools(t, bin, []string{"-p", "ok", "--output-format", "stream-json", "--verbose",
		"--model", "haiku", "--tools", "default", "--setting-sources", "project,local", "--strict-mcp-config"}))
	require.NotEmpty(t, all, "the CLI reported no built-in tools")
	known := knownBuiltins(t)
	var missing []string
	for _, n := range all {
		if !slices.Contains(known, n) {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 && mode == "update" {
		addToSnapshot(t, missing)
		t.Logf("added to %s: %v — add them to the deny list too", builtinsSnapshot, missing)
	} else {
		assert.Empty(t, missing, "built-ins missing from %s (rerun with update, then extend the deny list)", builtinsSnapshot)
	}

	cl := NewClient("haiku", "", "")
	base, _, err := cl.buildArgs("sys", "ok", "stream-json", "")
	require.NoError(t, err)
	for run, r := range chatBuiltinRuns {
		args := slices.Clone(base)
		setFlag(t, args, "--tools", r.tools)
		setFlag(t, args, "--disallowedTools", r.deny)
		exposed := builtinNames(liveInitTools(t, bin, args))
		// Two-way: an unapproved built-in exposed fails, and so does an
		// approved one missing (a CLI dropping or renaming ToolSearch).
		assert.ElementsMatch(t, approvedChatBuiltins[run], exposed, "%s: built-ins the CLI exposes", run)
		t.Logf("%s exposes %v", run, exposed)
	}
}

// addToSnapshot adds names to the snapshot file, keeping its header comment
// and its names sorted.
func addToSnapshot(t *testing.T, names []string) {
	t.Helper()
	raw, err := os.ReadFile(builtinsSnapshot)
	require.NoError(t, err)
	var header []string
	for _, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			header = append(header, line)
		}
	}
	all := append(knownBuiltins(t), names...)
	slices.Sort(all)
	all = slices.Compact(all)
	out := strings.Join(append(header, all...), "\n") + "\n"
	require.NoError(t, os.WriteFile(builtinsSnapshot, []byte(out), 0o644))
}

// setFlag replaces the value following flag in args.
func setFlag(t *testing.T, args []string, flag, value string) {
	t.Helper()
	i := slices.Index(args, flag)
	require.GreaterOrEqual(t, i, 0, "flag %s missing", flag)
	args[i+1] = value
}

// builtinNames drops MCP tools (mcp__<server>__<tool>) from an init tool list.
func builtinNames(tools []string) []string {
	var out []string
	for _, n := range tools {
		if !strings.HasPrefix(n, "mcp__") {
			out = append(out, n)
		}
	}
	return out
}

// liveInitTools launches the CLI in an empty directory, returns the tool list
// of its stream-json init event and kills the process group right after. The
// group is killed and reaped on every path, timeout included. The launch
// leaves no CLI state behind: --no-session-persistence writes no transcript,
// and the per-cwd project directory the CLI still creates under
// ~/.claude/projects is removed at cleanup.
func liveInitTools(t *testing.T, bin string, args []string) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, append(slices.Clone(args), "--no-session-persistence")...)
	cmd.Dir = t.TempDir()
	removeCLIProjectDir(t, cmd.Dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.Stdin = strings.NewReader("")
	out, err := cmd.StdoutPipe()
	require.NoError(t, err)
	errLog, err := os.Create(filepath.Join(t.TempDir(), "stderr.log"))
	require.NoError(t, err)
	cmd.Stderr = errLog
	require.NoError(t, cmd.Start())
	defer func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
		_ = errLog.Close()
	}()

	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	for sc.Scan() {
		var ev struct {
			Type    string   `json:"type"`
			Subtype string   `json:"subtype"`
			Tools   []string `json:"tools"`
		}
		if json.Unmarshal(sc.Bytes(), &ev) == nil && ev.Type == "system" && ev.Subtype == "init" {
			return ev.Tools
		}
	}
	stderr, _ := os.ReadFile(errLog.Name())
	t.Fatalf("no init event from %s %v (scan err %v); stderr: %s", bin, args, sc.Err(), stderr)
	return nil
}

// nonProjectDirChars is what the CLI replaces with '-' when it names a cwd's
// directory under ~/.claude/projects (/private/tmp/a_b/001 →
// -private-tmp-a-b-001).
var nonProjectDirChars = regexp.MustCompile(`[^A-Za-z0-9]`)

// removeCLIProjectDir removes, at cleanup, the directory the CLI creates under
// ~/.claude/projects for the temp cwd dir — named after both its symlinked and
// its resolved path (macOS /var → /private/var). The names derive from the
// test's own unique temp dir, so no other project's state is touched.
func removeCLIProjectDir(t *testing.T, dir string) {
	t.Helper()
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	paths := []string{dir}
	if resolved, err := filepath.EvalSymlinks(dir); err == nil && resolved != dir {
		paths = append(paths, resolved)
	}
	t.Cleanup(func() {
		for _, p := range paths {
			name := nonProjectDirChars.ReplaceAllString(p, "-")
			if err := os.RemoveAll(filepath.Join(home, ".claude", "projects", name)); err != nil {
				t.Logf("removing the CLI project dir for %s: %v", p, err)
			}
		}
	})
}
