// Package sessionstart builds how a workbench terminal session starts — the
// login-shell argv and environment (Launch) and where it runs, the folder or
// its own git worktree (Place, Prepare) — for the Go hub (spec 2026-10-31
// §11). It is a dual path of the Desktop's TerminalLaunch and
// SessionStartPlacement (WatchtowerCore): testdata/launch_cases.json and
// testdata/placement_cases.json are written from the Swift types
// (WT_E2E_REGENERATE=1) and read by both sides' tests.
package sessionstart

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/agentkind"
	"watchtower/internal/devpack"
)

// The environment names a launch sets (TerminalLaunch's twins).
const (
	// SessionRowEnv names the terminal_sessions row an agent runs in (Go
	// terminalSessionEnv, read by the SessionStart hook).
	SessionRowEnv = "WATCHTOWER_TERMINAL_SESSION_ID"
	// AutomationRunEnv names the automation run that started the session
	// (AGENT-07, Go RunEnvMarker).
	AutomationRunEnv = "WATCHTOWER_AUTOMATION_RUN_ID"
	// FirstPromptEnv carries a new session's first prompt; only /bin/sh
	// reads it, and `env -u` drops it before the agent runs.
	FirstPromptEnv = "WATCHTOWER_FIRST_PROMPT"
	// SetupCommandEnv carries the owner's worktree setup command verbatim.
	SetupCommandEnv = "WATCHTOWER_WORKTREE_SETUP"
	// CodexCommandEnv carries the /bin/sh script a Codex launch runs.
	CodexCommandEnv = "WATCHTOWER_CODEX_COMMAND"
)

// FallbackShell is the login shell when none (or a relative one) is given.
const FallbackShell = "/bin/zsh"

// FirstRunPrompt is the first session of a new workbench.
const FirstRunPrompt = "Set up this Watchtower workbench using the " + devpack.WorkbenchSkillName + " skill."

// SetupPrefix is prepended to a new agent start's login-shell command: a
// fixed literal with only its own pair of single quotes, so every login
// shell hands it to /bin/sh as is. The command runs in a subshell; a
// failure is reported and the agent starts anyway.
const SetupPrefix = "/bin/sh -c '" +
	`echo "watchtower: running the worktree setup command…"; ` +
	`( eval "$` + SetupCommandEnv + `" ); s=$?; ` +
	`[ "$s" -eq 0 ] || echo "watchtower: the worktree setup command failed (exit $s); starting the agent anyway."` +
	"'; "

// codexLoginCommand is the login shell's command for Codex: /bin/sh reads the
// script from CodexCommandEnv, so only /bin/sh ever parses values.
const codexLoginCommand = `exec /bin/sh -c 'eval "$` + CodexCommandEnv + `"'`

// Mode is how a session starts: a new agent (Resume false), a resumed agent
// (Resume true), or the owner's plain login shell (Agent "").
type Mode struct {
	// Agent is agentkind.Claude, agentkind.Codex, or "" for a shell.
	Agent string
	// SessionID: a new Claude session's id the app chose (required); a
	// new Codex session has none (Codex mints its own); a resume's stored
	// id (required). Always a lowercase canonical UUID.
	SessionID string
	// Prompt is a new agent's first prompt; nil for none.
	Prompt *string
	Resume bool
	// AutomationRunID reaches every agent launch as AutomationRunEnv; 0 =
	// none. A shell never carries it.
	AutomationRunID int64
}

// Spec is one launch: the login shell, its argv after the executable, the
// working directory, the NAME=value entries added to the environment, and
// the terminal_sessions row (0 = none) the session host keys it by.
type Spec struct {
	Executable string
	Args       []string
	Dir        string
	Env        []string
	Row        int64
}

// Launch is TerminalLaunch.make's twin. shell is the owner's login shell
// (FallbackShell when empty or relative); row reaches an agent launch as
// SessionRowEnv (0 = none). A Codex mode runs codex as `launch-args`
// resolved it; with codex nil there is no binary and the launch exits 127
// ("Codex was not found"), as on the Desktop. setup, when not blank, runs
// before a new agent start only. Unlike the Swift twin, Launch validates
// what reaches the shell: an unknown agent or a session id that is not a
// lowercase canonical UUID is an error.
func Launch(m Mode, row int64, dir, shell string, codex *devpack.LaunchArgs, setup string) (Spec, error) {
	if err := m.validate(); err != nil {
		return Spec{}, err
	}
	executable := shell
	if !strings.HasPrefix(shell, "/") {
		executable = FallbackShell
	}
	agent := agentkind.Kind(m.Agent)
	var args []string
	switch {
	case m.Agent == "":
		args = []string{"-l"}
	case agent == agentkind.Claude && m.Resume:
		args = []string{"-l", "-c", "exec claude --resume " + m.SessionID}
	case agent == agentkind.Claude && m.Prompt == nil:
		args = []string{"-l", "-c", "exec claude --session-id " + m.SessionID}
	case agent == agentkind.Claude:
		// `env -u` keeps the prompt out of everything Claude Code runs;
		// /bin/sh reads the variable whatever the login shell.
		args = []string{"-l", "-c", "exec /bin/sh -c 'exec env -u " + FirstPromptEnv + " claude --session-id " +
			m.SessionID + ` "$` + FirstPromptEnv + `"'`}
	case codex == nil:
		args = []string{"-l", "-c", "exit 127"}
	default:
		args = []string{"-l", "-c", codexLoginCommand}
	}
	withSetup := strings.TrimSpace(setup) != "" && m.Agent != "" && !m.Resume &&
		(codex != nil || agent == agentkind.Claude)
	if withSetup {
		args[len(args)-1] = SetupPrefix + args[len(args)-1]
	}
	spec := Spec{Executable: executable, Args: args, Dir: dir, Row: row}
	if row != 0 && m.Agent != "" {
		spec.Env = append(spec.Env, SessionRowEnv+"="+strconv.FormatInt(row, 10))
	}
	if agent == agentkind.Codex && codex != nil {
		spec.Env = append(spec.Env, CodexCommandEnv+"="+codexScript(*codex, m))
	}
	if m.Prompt != nil && !m.Resume {
		prompt := *m.Prompt
		if agent == agentkind.Claude {
			prompt = positionalPrompt(prompt)
		}
		spec.Env = append(spec.Env, FirstPromptEnv+"="+prompt)
	}
	if withSetup {
		spec.Env = append(spec.Env, SetupCommandEnv+"="+setup)
	}
	if m.AutomationRunID != 0 && m.Agent != "" {
		spec.Env = append(spec.Env, AutomationRunEnv+"="+strconv.FormatInt(m.AutomationRunID, 10))
	}
	return spec, nil
}

func (m Mode) validate() error {
	if m.Agent == "" {
		if m.Resume || m.SessionID != "" || m.Prompt != nil {
			return errors.New("a shell takes no session id, prompt or resume")
		}
		return nil
	}
	kind, ok := agentkind.Parse(m.Agent)
	if !ok {
		return fmt.Errorf("unknown agent kind %q", m.Agent)
	}
	needsID := m.Resume || kind == agentkind.Claude
	if (needsID || m.SessionID != "") && !IsValidSessionID(m.SessionID) {
		return errors.New("the session id is not a lowercase canonical UUID")
	}
	if m.Resume && m.Prompt != nil {
		return errors.New("a resume takes no first prompt")
	}
	return nil
}

// codexScript is `<binary> <launch-args…> [resume '<id>'] [-- "$PROMPT"]`,
// every value single-quoted, with path_prepend ahead of PATH. Nothing but
// `--` and the prompt follows `resume <id>`.
func codexScript(codex devpack.LaunchArgs, m Mode) string {
	words := []string{"exec", "env", "-u", FirstPromptEnv, "-u", CodexCommandEnv, ShellQuote(codex.Binary)}
	for _, a := range codex.Args {
		words = append(words, ShellQuote(a))
	}
	if m.Resume {
		words = append(words, "resume", ShellQuote(m.SessionID))
	}
	if m.Prompt != nil && !m.Resume {
		words = append(words, "--", `"$`+FirstPromptEnv+`"`)
	}
	path := ""
	if codex.PathPrepend != "" {
		path = "PATH=" + ShellQuote(codex.PathPrepend) + `:"$PATH" `
	}
	return path + strings.Join(words, " ")
}

// ShellQuote is POSIX single quotes, with a `'` inside written `'\”`.
func ShellQuote(v string) string {
	return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
}

// positionalPrompt gives a prompt starting with "-" a leading space, so
// claude never reads it as a flag.
func positionalPrompt(p string) string {
	if strings.HasPrefix(p, "-") {
		return " " + p
	}
	return p
}

// IsValidSessionID accepts a lowercase canonical UUID only, any version (Claude
// Code's v4, Codex's v7) — the id is interpolated into a shell command.
func IsValidSessionID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
				return false
			}
		}
	}
	return true
}
