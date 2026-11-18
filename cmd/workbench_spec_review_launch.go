package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"watchtower/internal/aiconsent"
	"watchtower/internal/config"
	"watchtower/internal/tools"
)

// specReviewExe names the binary the reviewer runs; tests replace it so a
// test binary never launches itself.
var specReviewExe = os.Executable

// specReviewStart starts the reviewer; tests replace it to see the command
// without starting it.
var specReviewStart = (*exec.Cmd).Start

// specReviewLauncher returns the launcher ask_owner starts the independent
// spec reviewer with (docs/features/spec-review.md). That first launch is
// part of the owner's session (D20 of #1886): it passes this process's own
// origin, none in the owner's.
func specReviewLauncher(cfg *config.Config) tools.SpecReviewLauncher {
	return func(askID int64) error {
		exe, err := specReviewExe()
		if err != nil {
			return fmt.Errorf("locating the watchtower binary: %w", err)
		}
		return LaunchSpecReview(exe, askID, filepath.Join(cfg.WorkspaceDir(), "logs"), processOriginEnv())
	}
}

// processOriginEnv is the origin env of this process's own default (no ctx
// mark): nil for the owner's process, EnvOrigin (and EnvAdmitted) for one a
// background unit started — e.g. an automation's shell() running `spec-review
// start` — so the reviewer it launches stays that unit's.
func processOriginEnv() []string { return aiconsent.ChildEnv(context.Background()) }

// LaunchSpecReview starts `workbench spec-review run --ask N` detached in its
// own session, its output appended to <logDir>/spec-review.log. It does not
// wait for the reviewer, which outlives the call that started it. The child
// gets this process's environment less the agent markers and any inherited
// AI origin, plus originEnv: aiconsent.ChildEnv of a background launch (the
// daemon sweep's relaunch), nil for the owner's.
func LaunchSpecReview(exe string, askID int64, logDir string, originEnv []string) error {
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return fmt.Errorf("creating log dir: %w", err)
	}
	logFile, err := os.OpenFile(filepath.Join(logDir, "spec-review.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("opening spec-review log: %w", err)
	}
	defer logFile.Close()
	c := exec.Command(exe, "workbench", "spec-review", "run", "--ask", strconv.FormatInt(askID, 10))
	c.Stdout, c.Stderr = logFile, logFile
	c.Env = append(envWithoutAgentMarkers(aiconsent.OwnerEnv(os.Environ())), originEnv...)
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := specReviewStart(c); err != nil {
		return fmt.Errorf("starting the reviewer: %w", err)
	}
	// Reaped in the background so a finished reviewer is no zombie of this
	// long-lived server; ask_owner never waits for it.
	go func() { _ = c.Wait() }()
	return nil
}

// envWithoutAgentMarkers drops the variables that make a process look like
// part of an agent session (agentEnvMarkers), so the reviewer is not taken
// for the author's session.
func envWithoutAgentMarkers(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		drop := false
		for _, m := range agentEnvMarkers {
			if name == m {
				drop = true
				break
			}
		}
		if !drop {
			out = append(out, kv)
		}
	}
	return out
}
