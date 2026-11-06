package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
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
	if actionsProposeFlagApprove && tools.IsInboxReplyTool(t.Name) {
		// A Reply from a row (ask #451): proposed here, approved only by the
		// owner's Approve in Needs approval, never in the same press.
		return 0, fmt.Errorf("a reply is approved in Needs approval: actions propose takes no --approve for %s", t.Name)
	}
	ctxType, ctxID, err := proposeContextFlags()
	if err != nil {
		return 0, err
	}
	args := json.RawMessage(strings.TrimSpace(actionsProposeFlagArgs))
	ctxType, ctxID = proposeContext(args, ctxType, ctxID)
	if actionsProposeFlagApprove && ctxType == db.InboxButtonContextType {
		// An Inbox card's button only proposes; the owner approves the row in
		// its approval card (AGENT-05), like any other proposal.
		return 0, fmt.Errorf("an Inbox button only proposes: approve it in its approval card; "+
			"actions propose takes no --approve for context type %s", db.InboxButtonContextType)
	}
	if actionsProposeFlagApprove {
		detail := fmt.Sprintf("%s\nArgs: %s", t.Name, args)
		if err := confirmWithOwner("approve an action", detail); err != nil {
			return 0, err
		}
	}
	rc, err := reg.Propose(context.Background(), t.Name, args, tools.Binding{
		Surface:     tools.InboxSurface,
		ContextType: ctxType,
		ContextID:   ctxID,
	})
	if err != nil {
		return 0, buttonStateExit(err)
	}
	return rc.ActionID, nil
}

// inboxItemContextType is the context of a Reply from an Inbox row: the
// inbox_items row the reply answers (`--context inbox_item:<id>`).
const inboxItemContextType = "inbox_item"

// proposeContextFlags is the context the flags name: --context
// inbox_item:<positive id> (a row's Reply), or --context-type/--context-id;
// --context together with either of the other two is refused.
func proposeContextFlags() (string, string, error) {
	if actionsProposeFlagContext == "" {
		return actionsProposeFlagContextType, actionsProposeFlagContextID, nil
	}
	if actionsProposeFlagContextType != "" || actionsProposeFlagContextID != "" {
		return "", "", fmt.Errorf("--context replaces --context-type and --context-id; pass one or the other")
	}
	typ, rawID, _ := strings.Cut(actionsProposeFlagContext, ":")
	id, err := strconv.ParseInt(rawID, 10, 64)
	if typ != inboxItemContextType || err != nil || id <= 0 || strconv.FormatInt(id, 10) != rawID {
		return "", "", fmt.Errorf("--context %q: want %s:<positive id>", actionsProposeFlagContext, inboxItemContextType)
	}
	return typ, rawID, nil
}

// proposeContext is the context stored on the row. When the args name an
// event_id, the row's context is that track event: the flags' context is kept
// only when it names the same event, otherwise it is replaced by the args, so
// the audit row never names an event the press did not act on.
func proposeContext(args json.RawMessage, ctxType, ctxID string) (string, string) {
	var a struct {
		EventID *int64 `json:"event_id"`
	}
	if json.Unmarshal(args, &a) != nil || a.EventID == nil {
		return ctxType, ctxID
	}
	id := strconv.FormatInt(*a.EventID, 10)
	if ctxType == "track_event" && ctxID == id {
		return ctxType, ctxID
	}
	return "track_event", id
}
