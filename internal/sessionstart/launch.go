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

	"watchtower/internal/devpack"
	"watchtower/internal/sessionagent"
)

// The environment names a launch sets (TerminalLaunch's twins).
const (
	// SessionRowEnv names the terminal_sessions row an agent runs in (Go
	// terminalSessionEnv, read by the SessionStart hook).
	SessionRowEnv = "WATCHTOWER_TERMINAL_SESSION_ID"
	// AutomationRunEnv names the automation run that started the session
	// (AGENT-07, Go RunEnvMarker).
	AutomationRunEnv = "WATCHTOWER_AUTOMATION_RUN_ID"
	// FirstPromptEnv carries a new session's first prompt (the session
	// adapter's sessionagent.FirstPromptEnv).
	FirstPromptEnv = sessionagent.FirstPromptEnv
	// SetupCommandEnv carries the owner's worktree setup command verbatim.
	SetupCommandEnv = "WATCHTOWER_WORKTREE_SETUP"
	// CodexCommandEnv carries the /bin/sh script a Codex launch runs
	// (sessionagent.LaunchScriptEnv).
	CodexCommandEnv = sessionagent.LaunchScriptEnv
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

// Mode is how a session starts: a new agent (Resume false), a resumed agent
// (Resume true), or the owner's plain login shell (Agent "").
type Mode struct {
	// Agent is an agent kind (terminal_sessions.kind), or "" for a shell.
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
// SessionRowEnv (0 = none). The agent's start command comes from its
// session adapter (sessionagent.Adapter.LaunchCommand); an agent whose hooks
// arrive with its launch flags runs as `launch-args` resolved it (codex),
// and with codex nil there is no binary and the launch exits 127, as on the
// Desktop. setup, when not blank, runs before a new agent start only.
// Unlike the Swift twin, Launch validates what reaches the shell: an
// unknown agent or a session id that is not a lowercase canonical UUID is
// an error.
func Launch(m Mode, row int64, dir, shell string, codex *devpack.LaunchArgs, setup string) (Spec, error) {
	agent, err := m.validate()
	if err != nil {
		return Spec{}, err
	}
	executable := shell
	if !strings.HasPrefix(shell, "/") {
		executable = FallbackShell
	}
	spec := Spec{Executable: executable, Args: []string{"-l"}, Dir: dir, Row: row}
	if agent == nil {
		return spec, nil
	}
	cmd := agent.LaunchCommand(sessionagent.Start{SessionID: m.SessionID, Prompt: m.Prompt, Resume: m.Resume,
		Binary: codex})
	withSetup := strings.TrimSpace(setup) != "" && !m.Resume && cmd.Runs
	command := cmd.Command
	if withSetup {
		command = SetupPrefix + command
	}
	spec.Args = append(spec.Args, "-c", command)
	if row != 0 {
		spec.Env = append(spec.Env, SessionRowEnv+"="+strconv.FormatInt(row, 10))
	}
	spec.Env = append(spec.Env, cmd.Env...)
	if m.Prompt != nil && !m.Resume {
		spec.Env = append(spec.Env, FirstPromptEnv+"="+cmd.Prompt)
	}
	if withSetup {
		spec.Env = append(spec.Env, SetupCommandEnv+"="+setup)
	}
	if m.AutomationRunID != 0 {
		spec.Env = append(spec.Env, AutomationRunEnv+"="+strconv.FormatInt(m.AutomationRunID, 10))
	}
	return spec, nil
}

// validate checks m and returns its agent's adapter, nil for a shell.
func (m Mode) validate() (sessionagent.Adapter, error) {
	if m.Agent == "" {
		if m.Resume || m.SessionID != "" || m.Prompt != nil {
			return nil, errors.New("a shell takes no session id, prompt or resume")
		}
		return nil, nil
	}
	agent, ok := sessionagent.Of(m.Agent)
	if !ok {
		return nil, fmt.Errorf("unknown agent kind %q", m.Agent)
	}
	needsID := m.Resume || agent.Caps().AppSessionID
	if (needsID || m.SessionID != "") && !IsValidSessionID(m.SessionID) {
		return nil, errors.New("the session id is not a lowercase canonical UUID")
	}
	if m.Resume && m.Prompt != nil {
		return nil, errors.New("a resume takes no first prompt")
	}
	return agent, nil
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
