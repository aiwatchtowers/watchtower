package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/planusage"
	"watchtower/internal/tools"
)

// specReviewLauncher returns the launcher ask_owner starts the independent
// spec reviewer with (docs/features/spec-review.md). It skips, rather than
// launches, when the Claude plan is near its limit: the reviewer is
// background work and the ask is filed either way.
func specReviewLauncher(cfg *config.Config, database *db.DB) tools.SpecReviewLauncher {
	return func(askID int64) error {
		if cfg.AI.Provider == "claude" {
			// An unreadable status does not block (planusage.NearLimit's rule).
			if st, err := database.GetPlanUsageStatus(); err == nil && planusage.NearLimit(st) {
				return tools.ErrSpecReviewSkipped{Reason: "plan near limit"}
			}
		}
		exe, err := os.Executable()
		if err != nil {
			return fmt.Errorf("locating the watchtower binary: %w", err)
		}
		return LaunchSpecReview(exe, askID, filepath.Join(cfg.WorkspaceDir(), "logs"))
	}
}

// LaunchSpecReview starts `workbench spec-review run --ask N` detached in its
// own session, its output appended to <logDir>/spec-review.log. It does not
// wait: the reviewer outlives the MCP server call that started it.
func LaunchSpecReview(exe string, askID int64, logDir string) error {
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
	c.Env = envWithoutAgentMarkers(os.Environ())
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return fmt.Errorf("starting the reviewer: %w", err)
	}
	return c.Process.Release()
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
