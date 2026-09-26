package cmd

import (
	"context"
	"encoding/json"
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
	actionsFlagForce        bool
)

// externalRetryWarning is what the card shows on a failed external row, said
// on the CLI too (spec §5: "the CLI/card warn 'check Jira before retrying'").
// An external retry re-sends the request; only the owner can tell whether the
// first attempt got through before it failed.
const externalRetryWarning = "Retrying re-sends the request — check Jira for a duplicate first."

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
	actionsApplyCmd.Flags().BoolVar(&actionsFlagForce, "force", false,
		"reclaim a row stranded in 'executing' by an interrupted apply")
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
	Warning   string     `json:"warning,omitempty"`
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

// decisionVerb turns the target status into the verb a refusal reads with
// ("action #3 is applied, cannot approve it").
func decisionVerb(to string) string {
	switch to {
	case "approved":
		return "approve"
	case "rejected":
		return "reject"
	default:
		return to
	}
}

// prepareApply runs the `apply` path's pre-checks against the row as it stands
// and returns the warning the output carries. A row in `executing` was claimed
// by an apply that never came back (a killed process): --force marks it failed
// so the ordinary retry path accepts it, and without --force it is refused —
// the other apply may still be running, and re-sending an external write on a
// guess is exactly what the claim exists to prevent.
func prepareApply(database *db.DB, id int64) (string, error) {
	row, err := database.GetAgentAction(id)
	if err != nil {
		return "", err
	}
	if row == nil {
		return "", fmt.Errorf("no action #%d", id)
	}
	if row.Status == "executing" {
		if !actionsFlagForce {
			return "", fmt.Errorf("action #%d is executing; pass --force to reclaim an interrupted apply", id)
		}
		ok, err := database.TransitionAgentAction(id, []string{"executing"}, "failed", "",
			"reclaimed after an interrupted apply")
		if err != nil {
			return "", err
		}
		if !ok {
			return "", fmt.Errorf("action #%d is no longer executing", id)
		}
		row.Status = "failed" // what the reclaim just made it
	}
	// A row that never reached `executing` provably never ran the tool, so
	// only a failed one can have left a half-finished external write behind.
	if row.External && row.Status == "failed" {
		return externalRetryWarning, nil
	}
	return "", nil
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
	env := actionEnvelope{OK: true}
	switch {
	case to != "":
		ok, err := database.TransitionAgentAction(id, from, to, "", "")
		if err != nil {
			return err
		}
		if !ok {
			row, err := database.GetAgentAction(id)
			if err != nil {
				return err
			}
			if row == nil {
				return fmt.Errorf("no action #%d", id)
			}
			return fmt.Errorf("action #%d is %s, cannot %s it", id, row.Status, decisionVerb(to))
		}
	case execute:
		if env.Warning, err = prepareApply(database, id); err != nil {
			return err
		}
	}
	var row *db.AgentAction
	if execute {
		row, err = reg.Apply(context.Background(), id)
		switch {
		case err != nil && to == "":
			// Nothing persisted on the bare `apply` path, so the failure IS
			// the outcome: exit non-zero, no envelope.
			return err
		case err != nil:
			// The decision above COMMITTED. Reporting a failed process for it
			// would tell the Desktop the approve never happened (spec §8).
			env.Error = err.Error()
			if row, err = database.GetAgentAction(id); err != nil {
				return err
			}
		default:
			env.AppliedOK = row.Status == "applied"
			env.Error = row.Error
		}
	} else {
		if row, err = database.GetAgentAction(id); err != nil {
			return err
		}
	}
	// GetAgentAction returns (nil, nil) for a row that is not there; nothing
	// deletes agent_actions rows, but the by-id getter's contract is the same
	// here as it is in the registry.
	if row == nil {
		return fmt.Errorf("no action #%d", id)
	}
	env.Action = toActionJSON(*row)
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	printAction(cmd.OutOrStdout(), *row)
	if env.Warning != "" {
		fmt.Fprintf(cmd.OutOrStdout(), "  warning: %s\n", env.Warning)
	}
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
