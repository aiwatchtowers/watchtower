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

// daemonFlag reports whether args set --daemon, the last occurrence
// winning as pflag does; args after "--" are positional.
func daemonFlag(args []string) bool {
	on := false
	for _, a := range args {
		if a == "--" {
			break
		}
		if a == "--daemon" {
			on = true
		} else if v, ok := strings.CutPrefix(a, "--daemon="); ok {
			b, err := strconv.ParseBool(v)
			on = err == nil && b
		}
	}
	return on
}
