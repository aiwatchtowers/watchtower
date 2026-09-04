package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

var (
	actionsFlagJSON         bool
	actionsFlagStatus       string
	actionsFlagConversation int64
	actionsFlagSurface      string
)

var actionsCmd = &cobra.Command{
	Use:   "actions",
	Short: "Proposed assistant actions: list, approve, reject, retry, tool trust",
	Long: `Every write tool the assistant calls lands in agent_actions as a proposal.
The Desktop drives these commands from the proposal cards; they are also the
CLI face for inspection and recovery.`,
}

var actionsListCmd = &cobra.Command{Use: "list", Short: "List proposed actions", RunE: runActionsList}
var actionsShowCmd = &cobra.Command{Use: "show <id>", Short: "Show one action", Args: cobra.ExactArgs(1), RunE: runActionsShow}
var actionsApproveCmd = &cobra.Command{Use: "approve <id>", Short: "Approve a pending action and execute it", Args: cobra.ExactArgs(1), RunE: runActionsApprove}
var actionsRejectCmd = &cobra.Command{Use: "reject <id>", Short: "Reject a pending action", Args: cobra.ExactArgs(1), RunE: runActionsReject}
var actionsApplyCmd = &cobra.Command{Use: "apply <id>", Short: "Retry an approved or failed action", Args: cobra.ExactArgs(1), RunE: runActionsApply}
var actionsTrustCmd = &cobra.Command{Use: "trust <tool> ask|execute", Short: "Set a tool's trust level", Args: cobra.ExactArgs(2), RunE: runActionsTrust}
var actionsToolsCmd = &cobra.Command{Use: "tools", Short: "List the registry's write tools", RunE: runActionsTools}

func init() {
	rootCmd.AddCommand(actionsCmd)
	for _, c := range []*cobra.Command{actionsListCmd, actionsShowCmd, actionsApproveCmd, actionsRejectCmd, actionsApplyCmd, actionsToolsCmd} {
		c.Flags().BoolVar(&actionsFlagJSON, "json", false, "output JSON (the Desktop contract)")
		actionsCmd.AddCommand(c)
	}
	actionsCmd.AddCommand(actionsTrustCmd)
	actionsListCmd.Flags().StringVar(&actionsFlagStatus, "status", "", "filter by status")
	actionsListCmd.Flags().Int64Var(&actionsFlagConversation, "conversation", 0, "filter by chat conversation id")
	actionsToolsCmd.Flags().StringVar(&actionsFlagSurface, "surface", "", "filter by chat surface (main|target)")
}

// actionJSON is the wire shape of one row. Field names are load-bearing:
// the Desktop's AgentActionQueries reads the table directly, but the CLI
// envelopes are decoded by AgentActionFeed verbatim.
type actionJSON struct {
	ID             int64           `json:"id"`
	Tool           string          `json:"tool"`
	External       bool            `json:"external"`
	Status         string          `json:"status"`
	Args           json.RawMessage `json:"args"`
	Reason         string          `json:"reason"`
	Surface        string          `json:"surface"`
	ConversationID int64           `json:"conversation_id"`
	TurnID         string          `json:"turn_id"`
	Result         json.RawMessage `json:"result"`
	Error          string          `json:"error"`
	CreatedAt      string          `json:"created_at"`
	DecidedAt      string          `json:"decided_at"`
	AppliedAt      string          `json:"applied_at"`
}

func toActionJSON(a db.AgentAction) actionJSON {
	out := actionJSON{ID: a.ID, Tool: a.Tool, External: a.External, Status: a.Status,
		Args: json.RawMessage(a.ArgsJSON), Reason: a.Reason, Surface: a.Surface, ConversationID: a.ConversationID,
		TurnID: a.TurnID, Result: json.RawMessage("null"), Error: a.Error,
		CreatedAt: a.CreatedAt, DecidedAt: a.DecidedAt, AppliedAt: a.AppliedAt}
	if a.ResultJSON != "" {
		out.Result = json.RawMessage(a.ResultJSON)
	}
	return out
}

type actionEnvelope struct {
	OK        bool       `json:"ok"`
	Action    actionJSON `json:"action"`
	AppliedOK bool       `json:"applied_ok"`
	Error     string     `json:"error"`
}

func openActionsCmd() (*config.Config, *db.DB, *tools.Registry, error) {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return nil, nil, nil, err
	}
	return cfg, database, buildToolRegistry(cfg, database), nil
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func parseActionID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid action id %q", arg)
	}
	return id, nil
}

func printAction(w io.Writer, a db.AgentAction) {
	fmt.Fprintf(w, "#%d %s [%s] %s\n", a.ID, a.Tool, a.Status, a.Reason)
	fmt.Fprintf(w, "  args:   %s\n", a.ArgsJSON)
	if a.ResultJSON != "" {
		fmt.Fprintf(w, "  result: %s\n", a.ResultJSON)
	}
	if a.Error != "" {
		fmt.Fprintf(w, "  error:  %s\n", a.Error)
	}
}

func runActionsList(cmd *cobra.Command, _ []string) error {
	_, database, _, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	rows, err := database.ListAgentActions(db.AgentActionFilter{Status: actionsFlagStatus, ConversationID: actionsFlagConversation, Limit: 200})
	if err != nil {
		return err
	}
	if actionsFlagJSON {
		out := make([]actionJSON, 0, len(rows))
		for _, r := range rows {
			out = append(out, toActionJSON(r))
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	for _, r := range rows {
		printAction(cmd.OutOrStdout(), r)
	}
	return nil
}

func runActionsShow(cmd *cobra.Command, args []string) error {
	id, err := parseActionID(args[0])
	if err != nil {
		return err
	}
	_, database, _, err := openActionsCmd()
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
		return writeJSON(cmd.OutOrStdout(), toActionJSON(*row))
	}
	printAction(cmd.OutOrStdout(), *row)
	return nil
}

// decideAndMaybeApply is approve/reject/apply's shared core. The status
// change is the persisted outcome (exit 0 once it landed); execution is
// reported separately through applied_ok/error — the recap_ok precedent —
// so a Jira failure never masquerades as "the approve did not happen".
func decideAndMaybeApply(cmd *cobra.Command, idArg string, from []string, to string, execute bool) error {
	id, err := parseActionID(idArg)
	if err != nil {
		return err
	}
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if to != "" {
		ok, err := database.TransitionAgentAction(id, from, to, "", "")
		if err != nil {
			return err
		}
		if !ok {
			row, _ := database.GetAgentAction(id)
			if row == nil {
				return fmt.Errorf("no action #%d", id)
			}
			return fmt.Errorf("action #%d is %s, cannot %s it", id, row.Status, to)
		}
	}
	env := actionEnvelope{OK: true}
	var row *db.AgentAction
	if execute {
		row, err = reg.Apply(context.Background(), id)
		if errors.Is(err, tools.ErrBadTransition) || errors.Is(err, tools.ErrNotFound) {
			return err
		}
		if err != nil {
			return err
		}
		env.AppliedOK = row.Status == "applied"
		env.Error = row.Error
	} else {
		row, err = database.GetAgentAction(id)
		if err != nil {
			return err
		}
	}
	env.Action = toActionJSON(*row)
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	printAction(cmd.OutOrStdout(), *row)
	return nil
}

func runActionsApprove(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "approved", true)
}

func runActionsReject(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "rejected", false)
}

func runActionsApply(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], nil, "", true)
}

func runActionsTrust(cmd *cobra.Command, args []string) error {
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := reg.SetTrust(args[0], tools.Trust(args[1])); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s: trust = %s\n", args[0], args[1])
	return nil
}

type toolJSON struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Access      string   `json:"access"`
	External    bool     `json:"external"`
	Surfaces    []string `json:"surfaces"`
	Trust       string   `json:"trust"`
}

func runActionsTools(cmd *cobra.Command, _ []string) error {
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	var listed []*tools.Tool
	if actionsFlagSurface != "" {
		listed = reg.List(actionsFlagSurface)
	} else {
		listed = reg.All()
	}
	out := make([]toolJSON, 0, len(listed))
	for _, t := range listed {
		trust, err := reg.Trust(t.Name)
		if err != nil {
			return err
		}
		surfaces := t.Surfaces
		if surfaces == nil {
			surfaces = []string{}
		}
		out = append(out, toolJSON{Name: t.Name, Description: t.Description, Access: string(t.Access),
			External: t.External, Surfaces: surfaces, Trust: string(trust)})
	}
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	for _, t := range out {
		fmt.Fprintf(cmd.OutOrStdout(), "%-20s %-6s external=%-5v trust=%s\n", t.Name, t.Access, t.External, t.Trust)
	}
	return nil
}
