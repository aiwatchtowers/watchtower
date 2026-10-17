package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
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
	actionsFlagPatch        string
	actionsFlagArgsSHA256   string
)

// externalRetryWarning is what the card shows on a failed external row, said
// on the CLI too (spec §5: "the CLI/card warn 'check Jira before retrying'").
// An external retry re-sends the request; only the owner can tell whether the
// first attempt got through before it failed.
const externalRetryWarning = "Retrying re-sends the request — check Jira for a duplicate first."

// slackRetryWarning: a Slack send's retry first looks for the message the
// failed attempt may have posted, and re-posts only when it finds none.
const slackRetryWarning = "Retrying first checks whether the message already reached Slack and posts it only if it did not."

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
var actionsTrustCmd = &cobra.Command{
	Use:   "trust <tool> ask|execute",
	Short: "Set a tool's trust level, per chat surface",
	Long: `Trust is per (tool, chat surface): an execute granted on one surface never
covers another. Without --surface the level is set on every surface the tool
is offered on except automation; with --surface it is set on that surface
only (what Settings → Assistant tools passes, one switch per surface). An
automation-wide level is set only with an explicit --surface automation; it
applies to every automation's calls of the tool (a per-automation auto grant
is 'automations auto'). Only write tools take a trust level; the workbench
surface takes none.`,
	Args: cobra.ExactArgs(2),
	RunE: runActionsTrust,
}
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
	actionsApproveCmd.Flags().StringVar(&actionsFlagPatch, "patch", "",
		"the owner's edits as a JSON object, merged into the pending row before it is approved (e.g. a Slack message's text)")
	actionsApproveCmd.Flags().StringVar(&actionsFlagArgsSHA256, "args-sha256", "",
		"sha256 (hex) of the args_json the owner was shown; the approve is refused if the stored args differ")
	actionsListCmd.Flags().StringVar(&actionsFlagStatus, "status", "", "filter by status")
	actionsListCmd.Flags().Int64Var(&actionsFlagConversation, "conversation", 0, "filter by chat conversation id")
	actionsToolsCmd.Flags().StringVar(&actionsFlagSurface, "surface", "", "filter by surface (main|target|reaction|project|automation)")
	actionsTrustCmd.Flags().StringVar(&actionsFlagSurface, "surface", "",
		"set the trust on this surface only: main|target|reaction|automation (default: every surface the tool is on but automation)")
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
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		database.Close()
		return nil, nil, nil, err
	}
	return cfg, database, buildToolRegistry(cfg, database), nil
}

// ownerWriteBusyTimeout is how long an owner-facing write — an Approve,
// Reject or Retry click, a chat proposal being recorded — waits out another
// process's write lock (the daemon's) before failing with SQLITE_BUSY,
// instead of Open's 5 s (backlog 2026-09-30, approving a chat proposal).
const ownerWriteBusyTimeout = 30 * time.Second

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
		if row.Tool == "send_slack_message" {
			return slackRetryWarning, nil
		}
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
	if execute {
		applyHere, err := mayApplyHere(reg, database, id, to)
		if err != nil {
			return err
		}
		execute = applyHere
	}
	env := actionEnvelope{OK: true}
	switch {
	case to != "":
		ok, err := decide(reg, database, id, from, to)
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

// mayApplyHere is whether this command may run row id itself. A
// session-applied row (claude_ai_connector_call, #737) runs only in the chat
// session that proposed it: approve stops at `approved` (the session claims
// it), and a bare apply — --force included — is refused before anything is
// written, so not even an `executing` row is reclaimed here.
func mayApplyHere(reg *tools.Registry, database *db.DB, id int64, to string) (bool, error) {
	row, err := database.GetAgentAction(id)
	if err != nil {
		return false, fmt.Errorf("reading action #%d: %w", id, err)
	}
	if row == nil {
		return true, nil // reported as "no action #N" by the usual path
	}
	t, ok := reg.Get(row.Tool)
	if !ok || !t.AppliedBySession {
		return true, nil
	}
	if to == "" {
		return false, fmt.Errorf("action #%d: %s %w", id, t.Name, tools.ErrSessionApplied)
	}
	return false, nil
}

// agentEnvMarkers are the variables an AI coding agent's shell carries:
// Claude Code sets CLAUDECODE=1; Codex sets CODEX_THREAD_ID on every command
// it runs and CODEX_SANDBOX when it runs one sandboxed; a Watchtower
// workbench terminal hands its agent tools.TerminalSessionEnv (a plain shell
// terminal does not get it); a child an automation run starts carries
// automations.RunEnvMarker.
var agentEnvMarkers = []string{"CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX", tools.TerminalSessionEnv,
	automations.RunEnvMarker}

// refuseUnderAgent keeps the owner's decision the owner's (AGENT-07): an
// agent that can run `watchtower` could otherwise approve or apply its own
// proposal (a prompt-injected send_slack_message, then `actions approve` on
// the id its receipt names). Refused when any marker is set: the approve,
// the apply and an execute trust grant; `automations confirm`,
// `automations save --confirm-hash` and `automations dry-run` of a recipe
// that is not confirmed yet (spec 2026-10-14 §14.3, D16); `automations
// enable` and `automations delete` (D24, ask #293); `automations auto …
// on` (spec §6.4, P2); `automations session-launched` and `session-ended`
// (P5). The Desktop's buttons are the path. Reject and the read verbs stay open.
func refuseUnderAgent(verb string) error {
	for _, name := range agentEnvMarkers {
		if os.Getenv(name) != "" {
			return fmt.Errorf("refusing to %s under an AI agent (%s is set): the owner decides in Watchtower Desktop "+
				"(or runs this from a plain Terminal)", verb, name)
		}
	}
	return nil
}

// decide records the owner's decision. An approval goes through the
// registry, which merges --patch and checks the tool is ready to run; a
// rejection is the plain conditional transition.
func decide(reg *tools.Registry, database *db.DB, id int64, from []string, to string) (bool, error) {
	if to != "approved" {
		return database.TransitionAgentAction(id, from, to, "", "")
	}
	ok, err := reg.ApproveSeen(context.Background(), id, json.RawMessage(actionsFlagPatch), actionsFlagArgsSHA256)
	if errors.Is(err, tools.ErrNotFound) {
		return false, nil // reported below as "no action #N", like any other miss
	}
	return ok, err
}

func runActionsApprove(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent("approve an action"); err != nil {
		return err
	}
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "approved", true)
}

func runActionsReject(cmd *cobra.Command, args []string) error {
	return decideAndMaybeApply(cmd, args[0], []string{"pending"}, "rejected", false)
}

func runActionsApply(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent("apply an action"); err != nil {
		return err
	}
	return decideAndMaybeApply(cmd, args[0], nil, "", true)
}

func runActionsTrust(cmd *cobra.Command, args []string) error {
	if tools.Trust(args[1]) == tools.TrustExecute {
		if err := refuseUnderAgent("grant execute trust"); err != nil {
			return err
		}
	}
	_, database, reg, err := openActionsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	t, ok := reg.Get(args[0])
	if !ok {
		return tools.ErrUnknownTool
	}
	if err := tools.CheckTrustable(t); err != nil {
		return err
	}
	surfaces, err := trustTargetSurfaces(t, actionsFlagSurface)
	if err != nil {
		return err
	}
	for _, s := range surfaces {
		if err := reg.SetTrust(t.Name, s, tools.Trust(args[1])); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s: trust = %s on %s\n", t.Name, args[1], strings.Join(surfaces, ", "))
	return nil
}

// trustTargetSurfaces is the surfaces `actions trust` sets: the --surface
// given, else every trust surface of t but automation — an execute meant for
// the chats must not silently auto-apply every automation's calls too, so
// the automation surface is set only when named.
func trustTargetSurfaces(t *tools.Tool, flag string) ([]string, error) {
	if flag != "" {
		return []string{flag}, nil
	}
	all := tools.TrustSurfaces(t)
	out := make([]string, 0, len(all))
	for _, s := range all {
		if s != tools.AutomationSurface {
			out = append(out, s)
		}
	}
	switch {
	case len(out) > 0:
		return out, nil
	case len(all) > 0:
		return nil, fmt.Errorf("%s is offered only to automations; pass --surface %s", t.Name, tools.AutomationSurface)
	case len(t.Surfaces) > 0:
		return nil, fmt.Errorf("%s: workbench tools always apply in their own workbench", t.Name)
	}
	return nil, fmt.Errorf("%s names no surface; pass --surface", t.Name)
}

type toolJSON struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Access      string   `json:"access"`
	External    bool     `json:"external"`
	AlwaysAsk   bool     `json:"always_ask"`
	Surfaces    []string `json:"surfaces"`
	// Trust is the level on --surface when given; otherwise the one level
	// every surface shares, or "mixed" when they differ. TrustBySurface is
	// the per-surface truth (target 167); the workbench surface is not in
	// it — its tools always apply there (DEV-06).
	Trust          string            `json:"trust"`
	TrustBySurface map[string]string `json:"trust_by_surface"`
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
		// Settings → Assistant tools draws a trust switch per surface, so
		// only what trust can act on is listed (CheckTrustable); a
		// session-applied tool is no assistant tool a switch could govern.
		if tools.CheckTrustable(t) != nil || t.AppliedBySession {
			continue
		}
		// Never nil, so JSON carries []; the automation surface is listed with
		// its trust level like any other (spec §6.2).
		surfaces := append(make([]string, 0, len(t.Surfaces)), t.Surfaces...)
		trustSurfaces := tools.TrustSurfaces(t)
		bySurface := make(map[string]string, len(trustSurfaces))
		for _, s := range trustSurfaces {
			trust, err := reg.Trust(t.Name, s)
			if err != nil {
				return err
			}
			bySurface[s] = string(trust)
		}
		out = append(out, toolJSON{Name: t.Name, Description: t.Description, Access: string(t.Access),
			External: t.External, AlwaysAsk: t.AlwaysAsk, Surfaces: surfaces,
			Trust: summarizeTrust(trustSurfaces, bySurface, actionsFlagSurface), TrustBySurface: bySurface})
	}
	if actionsFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	for _, t := range out {
		perSurface := make([]string, 0, len(t.Surfaces))
		for _, s := range t.Surfaces {
			if trust, ok := t.TrustBySurface[s]; ok {
				perSurface = append(perSurface, s+":"+trust)
			} else {
				perSurface = append(perSurface, s+":direct")
			}
		}
		fmt.Fprintf(cmd.OutOrStdout(), "%-20s %-6s external=%-5v trust=%s %s\n",
			t.Name, t.Access, t.External, t.Trust, strings.Join(perSurface, ","))
	}
	return nil
}

// summarizeTrust is toolJSON.Trust: the level on the filtered surface, else
// the level all surfaces share, "mixed" when they differ, "ask" for a tool
// that names no surface.
func summarizeTrust(surfaces []string, bySurface map[string]string, filter string) string {
	if filter != "" {
		if s, ok := bySurface[filter]; ok {
			return s
		}
		return string(tools.TrustAsk)
	}
	summary := string(tools.TrustAsk)
	for i, s := range surfaces {
		if i == 0 {
			summary = bySurface[s]
		} else if bySurface[s] != summary {
			return "mixed"
		}
	}
	return summary
}
