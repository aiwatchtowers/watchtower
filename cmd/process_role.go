package cmd

import (
	"strconv"
	"strings"
)

// hookCommands are the subcommands Claude Code and Codex hooks run (the
// hook specs in internal/devpack): their DB work is timed against an
// agent's hook budget, so lock metrics name them apart from the CLI.
var hookCommands = map[string]bool{
	"workbench brief":         true,
	"workbench check":         true,
	"workbench ask-guard":     true,
	"workbench session-state": true,
}

// roleFor names this process in lock-metrics events from its arguments,
// resolving the command the way cobra's Execute will. It runs before
// Execute rather than in the root's PersistentPreRunE because the hook
// subcommands replace that with a no-op.
func roleFor(args []string) string {
	c, _, err := rootCmd.Find(args)
	if err != nil {
		return processRole("", args)
	}
	return processRole(strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), args)
}

// processRole maps a command path below the root ("" for the root itself)
// and the raw args to a role: "daemon" (sync --daemon), "mcp",
// "hook:<subcommand>", "cli:<command path>", or "cli" for the root.
func processRole(path string, args []string) string {
	switch {
	case path == "sync" && daemonFlag(args):
		return "daemon"
	case path == "mcp":
		return "mcp"
	case hookCommands[path]:
		return "hook:" + path[strings.LastIndexByte(path, ' ')+1:]
	case path == "":
		return "cli"
	}
	return "cli:" + path
}

// daemonFlag reports whether args set --daemon.
func daemonFlag(args []string) bool { return boolFlag(args, "--daemon") }

// boolFlag reports whether args set the bool flag name ("--daemon"), the
// last occurrence winning as pflag does; args after "--" are positional.
func boolFlag(args []string, name string) bool {
	on := false
	for _, a := range args {
		if a == "--" {
			break
		}
		if a == name {
			on = true
		} else if v, ok := strings.CutPrefix(a, name+"="); ok {
			b, err := strconv.ParseBool(v)
			on = err == nil && b
		}
	}
	return on
}

// flagValue returns the last value args give the flag name ("--surface"),
// as "--surface x" or "--surface=x"; "" when unset.
func flagValue(args []string, name string) string {
	v := ""
	for i, a := range args {
		if a == "--" {
			break
		}
		if a == name && i+1 < len(args) {
			v = args[i+1]
		} else if s, ok := strings.CutPrefix(a, name+"="); ok {
			v = s
		}
	}
	return v
}

// surfaceFor is the ledger surface (llm_calls.surface) of a process's calls
// that name none in their context: the AI chat commands and chat MCP
// servers are "chat", workbench commands, the workbench MCP server and the
// agent hooks are "workbench", and everything else — the daemon, an
// automation's agent() server, other commands — is "watchtower".
func surfaceFor(role string, args []string) string {
	switch {
	case role == "cli:ai session", role == "cli:ai query":
		return "chat"
	case role == "mcp":
		if w := flagValue(args, "--workbench"); w != "" && w != "0" {
			return "workbench"
		}
		if boolFlag(args, "--chat") {
			if flagValue(args, "--surface") == "automation" {
				return "watchtower"
			}
			return "chat"
		}
	case strings.HasPrefix(role, "cli:workbench"), strings.HasPrefix(role, "cli:terminal"),
		strings.HasPrefix(role, "hook:"):
		return "workbench"
	}
	return "watchtower"
}
