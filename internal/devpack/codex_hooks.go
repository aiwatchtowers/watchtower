package devpack

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/codex"
	"watchtower/internal/config"
)

// ErrCodexNotFound means no codex binary could be resolved: neither
// codex_path from config nor the binary lookup gave an absolute path to a
// file. `workbench launch-args` turns it into exit code 3 and
// {"error":"codex_not_found"}.
var ErrCodexNotFound = errors.New("codex binary not found")

// CodexMCPServerName is the MCP server name the workbench mounts in codex.
// Codex names its tools mcp__<name with '-' as '_'>__<tool>.
const CodexMCPServerName = "watchtower-workbench"

// codexSessionEnvVar is the environment variable that names the terminal
// session row. Codex hands it to every hook command, but starts an MCP server
// with a filtered environment, so the MCP launch overrides list it in
// env_vars.
const codexSessionEnvVar = "WATCHTOWER_TERMINAL_SESSION_ID"

// codexNoUpdateCheck keeps codex's startup update notice off screen.
const codexNoUpdateCheck = "check_for_update_on_startup=false"

// CodexHook is one hook handler of the codex workbench hook set. Group is the
// index of the matcher group within Event; codex's trust key for a
// launch-flag hook is /<session-flags>/config.toml:<event_snake>:<group>:<handler>,
// so Event, Group and the handler's place in its group must stay stable.
type CodexHook struct {
	Event, Matcher, Command string
	TimeoutSec, Group       int
}

// codexHookRows is spec §4.3's hook table, in its fixed order: the command
// suffix after the quoted watchtower binary. No suffix names a workbench:
// one trusted hash per event and group then covers every folder, and the
// hook finds its row through WATCHTOWER_TERMINAL_SESSION_ID.
var codexHookRows = []struct {
	event, matcher, suffix string
	timeoutSec, group      int
}{
	{"SessionStart", "", "workbench brief --agent codex", 10, 0},
	{"UserPromptSubmit", "", "workbench session-state --agent codex", 5, 0},
	{"PermissionRequest", "", "workbench session-state --agent codex", 5, 0},
	{"PostToolUse", "", "workbench session-state --agent codex", 5, 0},
	{"SubagentStart", "", "workbench session-state --agent codex", 5, 0},
	{"SubagentStop", "", "workbench session-state --agent codex", 5, 0},
	{"PreToolUse", "request_user_input", "workbench ask-guard --agent codex --pre-tool-use", 5, 0},
	{"Stop", "", "workbench check --agent codex --stop-hook", 15, 0},
	{"Stop", "", "workbench ask-guard --agent codex --stop", 30, 1},
}

// CodexHookSet is the codex workbench hook set for the watchtower binary bin,
// in spec §4.3's order. The launch flags and the installer's trust step both
// build from it, so the strings codex hashes are the strings it runs (spec
// I5). Codex runs a command through a shell, so bin is single-quoted when it
// needs to be (the CLI store sits under "Application Support").
func CodexHookSet(bin string) []CodexHook {
	hooks := make([]CodexHook, 0, len(codexHookRows))
	for _, r := range codexHookRows {
		hooks = append(hooks, CodexHook{
			Event:      r.event,
			Matcher:    r.matcher,
			Command:    shellQuote(bin) + " " + r.suffix,
			TimeoutSec: r.timeoutSec,
			Group:      r.group,
		})
	}
	return hooks
}

// CodexHookOverrides renders hooks as codex launch flags: one
// "-c", "hooks.<Event>=[…]" pair per event, events in first-appearance order,
// each value a TOML inline array of matcher groups
// [{matcher?, hooks=[{type="command", command, timeout}]}] ordered by Group.
// Hooks of one event and group become handlers of that group, in order.
func CodexHookOverrides(hooks []CodexHook) []string {
	var events []string
	groups := map[string]map[int][]CodexHook{}
	for _, h := range hooks {
		if _, ok := groups[h.Event]; !ok {
			events = append(events, h.Event)
			groups[h.Event] = map[int][]CodexHook{}
		}
		groups[h.Event][h.Group] = append(groups[h.Event][h.Group], h)
	}
	out := make([]string, 0, 2*len(events))
	for _, ev := range events {
		out = append(out, "-c", "hooks."+ev+"="+codexEventGroups(groups[ev]))
	}
	return out
}

// codexEventGroups renders one event's groups, by ascending group index.
func codexEventGroups(byGroup map[int][]CodexHook) string {
	idx := make([]int, 0, len(byGroup))
	for g := range byGroup {
		idx = append(idx, g)
	}
	slices.Sort(idx)
	parts := make([]string, 0, len(idx))
	for _, g := range idx {
		parts = append(parts, codexGroup(byGroup[g]))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func codexGroup(handlers []CodexHook) string {
	hs := make([]string, 0, len(handlers))
	for _, h := range handlers {
		hs = append(hs, fmt.Sprintf(`{type="command",command=%s,timeout=%d}`, codex.TOMLString(h.Command), h.TimeoutSec))
	}
	matcher := ""
	if m := handlers[0].Matcher; m != "" {
		matcher = "matcher=" + codex.TOMLString(m) + ","
	}
	return "{" + matcher + "hooks=[" + strings.Join(hs, ",") + "]}"
}

// CodexMCPOverrides mounts the workbench MCP server (`<bin> mcp --workbench N
// --agent codex`) as codex launch flags: "-c", "<key>=<TOML value>" pairs.
// Every tool is pre-approved (spec D3; codex otherwise asks before each MCP
// call), and WATCHTOWER_TERMINAL_SESSION_ID is passed through, since codex
// starts MCP servers with a filtered environment.
func CodexMCPOverrides(bin string, workbenchID int64) []string {
	key := "mcp_servers." + CodexMCPServerName + "."
	args := []string{"mcp", "--workbench", strconv.FormatInt(workbenchID, 10), "--agent", "codex"}
	return []string{
		"-c", key + "command=" + codex.TOMLString(bin),
		"-c", key + "args=" + codex.TOMLStringArray(args),
		"-c", key + `default_tools_approval_mode="approve"`,
		"-c", key + "env_vars=" + codex.TOMLStringArray([]string{codexSessionEnvVar}),
	}
}

// LaunchArgs is how the Desktop starts codex for a workbench terminal
// session: Binary with Args, with PathPrepend put in front of PATH so a node
// shim finds node next to it.
type LaunchArgs struct {
	Binary      string   `json:"binary"`
	PathPrepend string   `json:"path_prepend"`
	Args        []string `json:"args"`
}

// CodexLaunchArgs resolves the codex binary and builds its launch flags for
// workbench workbenchID, with bin the watchtower binary the MCP server and the
// hooks run. The binary is cfg.CodexPath when that names a file, else find's
// answer (an absolute path to a file). find returns ErrCodexNotFound (or any error) when it has none.
// Args: --no-daemon, the update check off, the MCP overrides, then the hook overrides (spec §4.2).
// The caller appends `[resume <id>] -- <prompt>`.
func CodexLaunchArgs(cfg *config.Config, bin string, workbenchID int64, find func() (string, error)) (LaunchArgs, error) {
	codexBin, err := resolveCodexBinary(cfg, find)
	if err != nil {
		return LaunchArgs{}, err
	}
	// The update notice takes Enter as consent to `npm install -g`, and the
	// Desktop types owner answers into the TUI with Enter.
	args := []string{"--no-daemon", "-c", codexNoUpdateCheck}
	args = append(args, CodexMCPOverrides(bin, workbenchID)...)
	args = append(args, CodexHookOverrides(CodexHookSet(bin))...)
	return LaunchArgs{Binary: codexBin, PathPrepend: filepath.Dir(codexBin), Args: args}, nil
}

func resolveCodexBinary(cfg *config.Config, find func() (string, error)) (string, error) {
	if cfg != nil && isAbsFile(cfg.CodexPath) {
		return cfg.CodexPath, nil
	}
	p, err := find()
	if err != nil {
		return "", err
	}
	if !isAbsFile(p) {
		// codex.FindBinary answers a bare "codex" when it finds nothing.
		return "", fmt.Errorf("%w: lookup gave %q", ErrCodexNotFound, p)
	}
	return p, nil
}

// isAbsFile: p is an absolute path to a file. A relative path would make
// PathPrepend depend on the Desktop's working directory.
func isAbsFile(p string) bool {
	if !filepath.IsAbs(p) {
		return false
	}
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}
