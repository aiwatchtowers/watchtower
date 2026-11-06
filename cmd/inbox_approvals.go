package cmd

import (
	"errors"
	"fmt"
	"log"

	"github.com/spf13/cobra"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// inboxApprovalsCmd groups the hidden approval plumbing of the Inbox's Needs
// approval folder; no owner types it.
var inboxApprovalsCmd = &cobra.Command{
	Use:    "approvals",
	Short:  "Approval plumbing for the Inbox's Needs approval folder",
	Hidden: true,
}

var inboxApprovalsChangedRef string

// inboxApprovalsChangedCmd is the Desktop's call after one of its direct
// reminder writes (Done, Snooze — GRDB writes, STRIP-03): it queues the Needs
// approval run for the ref (builtin.Fire) and wakes the daemon. It only
// queues (AUTO-09) and prints nothing; with no daemon running the run waits
// for one.
var inboxApprovalsChangedCmd = &cobra.Command{
	Use:   "changed",
	Short: "Queue the Needs approval run for an approval that changed",
	Args:  cobra.NoArgs,
	RunE:  runInboxApprovalsChanged,
}

func init() {
	inboxCmd.AddCommand(inboxApprovalsCmd)
	inboxApprovalsCmd.AddCommand(inboxApprovalsChangedCmd)
	inboxApprovalsChangedCmd.Flags().StringVar(&inboxApprovalsChangedRef, "ref", "",
		"the approval that changed: action:<id> or reminder:<id>")
}

func runInboxApprovalsChanged(_ *cobra.Command, _ []string) error {
	ref := inboxApprovalsChangedRef
	if _, _, err := db.ParseApprovalRef(ref); err != nil {
		return err
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	if err := builtin.Fire(database, ref, approvalWake(cfg)); err != nil {
		return fmt.Errorf("queueing the Needs approval run for %s: %w", ref, err)
	}
	return nil
}

// approvalHookLogf is where a cmd process's approval hook logs (stderr; a
// test swaps it).
var approvalHookLogf = log.Printf

// approvalWakeAutomations is wakeAutomations (a test swaps it).
var approvalWakeAutomations = wakeAutomations

// approvalWake is a cmd process's approval hook wake: wakeAutomations
// (SIGUSR2 to the daemon), its error logged with no content (FILES-01). No
// daemon running, or one that cannot be woken, is not an error: the run
// starts when one does, or at its next poll.
func approvalWake(cfg *config.Config) func() {
	return func() {
		if cfg == nil {
			return
		}
		// A daemon that cannot be woken (older, or automations not wired)
		// is fine, as for wakeNote: the run starts at its next poll.
		if _, err := approvalWakeAutomations(cfg); err != nil && !errors.Is(err, errDaemonCannotWake) {
			approvalHookLogf("approval hook: waking the daemon: %v", err)
		}
	}
}

// installApprovalHook sets database's approval hook to builtin.Fire with the
// SIGUSR2 wake, unless the handle already has one (the daemon installs its
// in-process wake). buildToolRegistry calls it: every write of an approval
// in a cmd process goes through a tool registry — or, for `actions`' direct
// transitions, through the handle a registry was built on.
func installApprovalHook(cfg *config.Config, database *db.DB) {
	if database == nil || database.HasApprovalHook() {
		return
	}
	database.SetApprovalHook(builtin.ApprovalHook(database, approvalWake(cfg),
		func(format string, args ...any) { approvalHookLogf(format, args...) }))
}
