package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

// sessionWake wakes the daemon after a session report landed, so the run's
// wait reads it now rather than on its next poll. Tests swap it.
var sessionWake = wakeAutomations

// session-launched / session-ended are how the Desktop reports the session
// it opened for a session() step (spec §13). Only the Desktop reports: both
// need the owner's confirmation (AGENT-07, requireOwnerConfirmation), since an agent
// could otherwise attach a session of its own to, or end, a step the
// owner's run waits on.
func init() {
	launched := newAutomationsSubcommand("session-launched",
		"Attach the session the Desktop launched to its waiting session() step", cobra.NoArgs, runAutomationsSessionLaunched)
	launched.Flags().Int64Var(&autoFlags.Step, "step", 0, "the session() step id (required)")
	launched.Flags().Int64Var(&autoFlags.Session, "session", 0, "the terminal session id (required)")
	ended := newAutomationsSubcommand("session-ended",
		"Report a session() step the Desktop could not launch, or whose session stopped", cobra.NoArgs, runAutomationsSessionEnded)
	ended.Flags().Int64Var(&autoFlags.Step, "step", 0, "the session() step id (required)")
	ended.Flags().StringVar(&autoFlags.Status, "status", "", "stopped or launch_failed (required)")
	ended.Flags().StringVar(&autoFlags.Error, "error", "", "why the launch failed")
	for _, c := range []*cobra.Command{launched, ended} {
		c.Flags().BoolVar(&autoFlags.JSON, "json", false, "output as JSON")
	}
	automationsCmd.AddCommand(launched, ended)
}

func runAutomationsSessionLaunched(cmd *cobra.Command, _ []string) error {
	if err := requireOwnerConfirmation("report a session() step's session", ""); err != nil {
		return err
	}
	if autoFlags.Step <= 0 || autoFlags.Session <= 0 {
		return fmt.Errorf("--step and --session are required (positive ids)")
	}
	step, session := autoFlags.Step, autoFlags.Session
	return reportSessionStep(cmd, "attached", func(d *db.DB) (bool, error) {
		return d.AttachAutomationSessionStep(step, session)
	}, fmt.Sprintf("Attached session %d to step %d.", session, step),
		fmt.Sprintf("Step %d is not waiting for a session launch; nothing attached.", step))
}

func runAutomationsSessionEnded(cmd *cobra.Command, _ []string) error {
	if err := requireOwnerConfirmation("end a session() step", ""); err != nil {
		return err
	}
	if autoFlags.Step <= 0 {
		return fmt.Errorf("--step is required (a positive id)")
	}
	status := autoFlags.Status
	if status != db.SessionStepStopped && status != db.SessionStepLaunchFailed {
		return fmt.Errorf("--status must be %s or %s", db.SessionStepStopped, db.SessionStepLaunchFailed)
	}
	step, errText := autoFlags.Step, autoFlags.Error
	return reportSessionStep(cmd, "ended", func(d *db.DB) (bool, error) {
		return d.EndAutomationSessionStep(step, status, errText)
	}, fmt.Sprintf("Step %d ended (%s).", step, status),
		fmt.Sprintf("Step %d is not waiting for a session; nothing changed.", step))
}

// reportSessionStep runs write, prints {key: landed} (or done/skipped) and,
// when it landed, wakes the daemon; a failed wake is a note on stderr.
func reportSessionStep(cmd *cobra.Command, key string, write func(*db.DB) (bool, error), done, skipped string) error {
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	landed, err := write(database)
	if err != nil {
		return err
	}
	if landed {
		running, wakeErr := sessionWake(cfg)
		if note, _ := wakeNote(running, wakeErr, "daemon not running; the run reads this when it does"); note != "" {
			fmt.Fprintln(cmd.ErrOrStderr(), note)
		}
	}
	if autoFlags.JSON {
		return writeJSON(cmd.OutOrStdout(), map[string]bool{key: landed})
	}
	msg := skipped
	if landed {
		msg = done
	}
	fmt.Fprintln(cmd.OutOrStdout(), msg)
	return nil
}
