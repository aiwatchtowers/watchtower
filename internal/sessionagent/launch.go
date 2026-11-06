package sessionagent

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// The environment names an agent's start command reads (TerminalLaunch's
// twins on the Desktop).
const (
	// FirstPromptEnv carries a new session's first prompt; only /bin/sh
	// reads it, and `env -u` drops it before the agent runs.
	FirstPromptEnv = "WATCHTOWER_FIRST_PROMPT"
	// LaunchScriptEnv carries the /bin/sh script a launch-args agent's start
	// runs (Caps.LaunchHooks: Codex).
	LaunchScriptEnv = "WATCHTOWER_CODEX_COMMAND"
)

// LaunchArgs is how an agent whose hooks arrive with its launch flags
// (Caps.LaunchHooks) starts for a workbench terminal session, as `workbench
// launch-args` resolved it: Binary with Args, with PathPrepend put in front
// of PATH so a node shim finds node next to it.
type LaunchArgs struct {
	Binary      string   `json:"binary"`
	PathPrepend string   `json:"path_prepend"`
	Args        []string `json:"args"`
}

// Start is one agent start a workbench terminal launch runs.
type Start struct {
	// SessionID is the id the app chose for a new session (Caps.AppSessionID),
	// or the stored id a resume reopens; "" for a new session of an agent
	// that mints its own. The caller has checked it is a lowercase canonical
	// UUID: it is interpolated into a shell command.
	SessionID string
	// Prompt is a new session's first prompt; nil for none.
	Prompt *string
	Resume bool
	// Binary is `workbench launch-args`' resolution for an agent with
	// Caps.LaunchHooks; nil when there is none.
	Binary *LaunchArgs
}

// LaunchCommand is what an agent adds to the owner's login shell for one
// start.
type LaunchCommand struct {
	// Command is the login shell's `-c` command.
	Command string
	// Env is the NAME=value entries the start needs ahead of its prompt.
	Env []string
	// Prompt is the FirstPromptEnv value for a start with a prompt; "" for
	// none.
	Prompt string
	// Runs is false when the agent has no binary to run: Command exits 127
	// ("not found") and no setup command runs before it.
	Runs bool
}

// ShellQuote wraps v in POSIX single quotes; each single quote inside is
// written as quote, backslash, quote, quote (the shell idiom for a quote).
func ShellQuote(v string) string {
	return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
}

// LoadSession is terminal_sessions row id with its stored transcript path
// when the row's agent keeps the path its SessionStart reported
// (Adapter.StoresTranscriptPath): Codex's rows; a Claude row's readers find
// the transcript by id, and a shell has none. A missing row wraps
// db.ErrTerminalSessionNotFound.
func LoadSession(d *db.DB, id int64) (*db.TerminalSession, error) {
	s, err := d.GetTerminalSession(id)
	if err != nil {
		return nil, err
	}
	if a, ok := Of(s.Kind); ok && a.StoresTranscriptPath() {
		if s.TranscriptPath, err = d.TerminalTranscriptPath(id); err != nil {
			return nil, fmt.Errorf("reading terminal session %d transcript path: %w", id, err)
		}
	}
	return s, nil
}
