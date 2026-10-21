package cmd

import (
	"errors"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// replyWake is the wake a reply sends after queueing its run; tests count it.
var replyWake = wakeAutomations

// replyVerb is the AGENT-07 gesture `automations reply` makes.
const replyVerb = "press an Inbox button"

// replyUsage is the refusal of a reply without a valid --output and --action.
const replyUsage = "usage: watchtower automations reply --output <id> --action <index>"

// replyJSON is `reply --json` — the pinned key set (plan B Task 4).
type replyJSON struct {
	RunID         int64 `json:"run_id"`
	DaemonRunning bool  `json:"daemon_running"`
}

// runAutomationsReply is the owner's press of a Reply button on an Inbox
// card (AGENT-07: refused under every agent marker, otherwise the owner's
// Confirm). It records the press and queues one trigger='reply' run in one
// transaction (AUTO-09: nothing runs here), then wakes the daemon. A press
// the card, its automation or its confirmed recipe cannot take is refused
// before the owner is asked.
func runAutomationsReply(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(replyVerb); err != nil {
		return err
	}
	outputID, index := autoFlags.Output, autoFlags.Action
	if outputID <= 0 || !cmd.Flags().Changed("action") || index < 0 {
		return errors.New(replyUsage)
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	o, a, err := loadReplyTarget(database, outputID, index)
	if err != nil {
		return err
	}
	if reason := notRunnableReason(a); reason != "" {
		return fmt.Errorf("automation %d cannot run: %s", a.ID, reason)
	}
	if err := requireInboxReply(database, a); err != nil {
		return err
	}
	if err := confirmWithOwner(replyVerb, inboxReplyConfirmDetail(database, o.ID, index)); err != nil {
		return err
	}
	runID, err := database.PressInboxOutputAction(o.ID, index, time.Now())
	if err != nil {
		return err
	}
	out := replyJSON{RunID: runID}
	var wakeErr error
	out.DaemonRunning, wakeErr = replyWake(cfg)
	// The run is queued whatever the wake did; a failed wake is a note.
	note, _ := wakeNote(out.DaemonRunning, wakeErr, daemonNotRunningNote)
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		if note != "" {
			fmt.Fprintln(cmd.ErrOrStderr(), note)
		}
		return writeJSON(w, out)
	}
	fmt.Fprintf(w, "Queued run #%d.\n", runID)
	if note != "" {
		fmt.Fprintln(w, note)
	}
	return nil
}

// loadReplyTarget reads the card and its automation and refuses, in
// PressInboxOutputAction's order, a press the card cannot take: not an
// inbox card, closed, not a Reply action, already pressed. The press
// re-checks all of it in its own transaction.
func loadReplyTarget(database *db.DB, outputID int64, index int) (*db.AutomationOutput, *db.Automation, error) {
	o, err := database.GetAutomationOutput(outputID)
	if err != nil {
		return nil, nil, err
	}
	if o.Kind != "inbox" {
		return nil, nil, fmt.Errorf("output %d is a %s output: %w", outputID, o.Kind, db.ErrOutputNotFound)
	}
	if o.DoneAt != nil || o.DismissedAt != nil {
		return nil, nil, fmt.Errorf("inbox card %d: %w", outputID, db.ErrOutputClosed)
	}
	if index >= len(o.Actions) || o.Actions[index].Kind != db.InboxActionReply {
		return nil, nil, fmt.Errorf("inbox card %d action %d: %w", outputID, index, db.ErrNotAReplyAction)
	}
	if o.PressedAt != nil {
		return nil, nil, &db.AlreadyPressedError{RunID: o.PressedRunID}
	}
	a, err := database.GetAutomation(o.AutomationID)
	if err != nil {
		return nil, nil, err
	}
	return o, a, nil
}

// requireInboxReply refuses a press when a's confirmed recipe does not hold
// inbox:reply: a press runs the confirmed text, and the executor would fail
// a reply run of a snapshot without it.
func requireInboxReply(database *db.DB, a *db.Automation) error {
	noReply := fmt.Errorf("automation %d no longer reacts to its Inbox buttons (inbox:reply)", a.ID)
	r, err := automations.ConfirmedRecipe(database, a)
	if err != nil {
		return err
	}
	if r == nil {
		return noReply
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return fmt.Errorf("automation %d: the confirmed permission manifest does not parse: %w", a.ID, err)
	}
	if _, err := m.AllowInboxReply(); err != nil {
		return noReply
	}
	return nil
}
