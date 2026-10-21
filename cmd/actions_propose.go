package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/tools"
)

// runActionsPropose is `actions propose`: the owner's Inbox press records one
// proposal of an inbox-surface tool and, with --approve, approves and applies
// it through decideAndMaybeApply — the `actions approve` path, so the
// envelope is the same. AGENT-07 holds as for approve: refused under an agent
// marker before anything is read, and --approve needs the owner's Confirm
// (the Desktop answers its own launch without a window) before the row is
// written, so a Deny leaves nothing behind.
func runActionsPropose(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("propose an action"); err != nil {
		return err
	}
	id, err := proposeInboxAction()
	if err != nil {
		return err
	}
	if actionsProposeFlagApprove {
		return decideAndMaybeApply(cmd, strconv.FormatInt(id, 10), []string{"pending"}, "approved", true)
	}
	database, _, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	row, err := database.GetAgentAction(id)
	if err != nil {
		return err
	}
	if row == nil {
		return fmt.Errorf("no action #%d", id)
	}
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), actionEnvelope{OK: true, Action: toActionJSON(*row)})
	}
	printAction(cmd.OutOrStdout(), *row)
	return nil
}

// proposeInboxAction checks the tool and surface, asks the owner's Confirm
// for --approve, and records the proposal; it returns the row id. It closes
// its database before returning, so decideAndMaybeApply opens its own.
func proposeInboxAction() (int64, error) {
	database, reg, err := openActionsCmd()
	if err != nil {
		return 0, err
	}
	defer database.Close()
	t, ok := reg.Get(actionsProposeFlagTool)
	if !ok {
		return 0, fmt.Errorf("%w: %q", tools.ErrUnknownTool, actionsProposeFlagTool)
	}
	if !slices.Contains(t.Surfaces, tools.InboxSurface) {
		return 0, fmt.Errorf("%s is not an Inbox tool; actions propose runs only tools on the %s surface",
			t.Name, tools.InboxSurface)
	}
	if actionsProposeFlagSurface != tools.InboxSurface {
		return 0, fmt.Errorf("actions propose runs only on the %s surface, not %q", tools.InboxSurface, actionsProposeFlagSurface)
	}
	args := json.RawMessage(strings.TrimSpace(actionsProposeFlagArgs))
	if actionsProposeFlagApprove {
		detail := fmt.Sprintf("%s\nArgs: %s", t.Name, args)
		if err := confirmWithOwner("approve an action", detail); err != nil {
			return 0, err
		}
	}
	rc, err := reg.Propose(context.Background(), t.Name, args, tools.Binding{
		Surface:     tools.InboxSurface,
		ContextType: actionsProposeFlagContextType,
		ContextID:   actionsProposeFlagContextID,
	})
	if err != nil {
		return 0, err
	}
	return rc.ActionID, nil
}
