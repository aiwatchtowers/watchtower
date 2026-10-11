package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

// askGuardBusyTimeout bounds each of the ask guard's reads: Claude Code
// waits for a PreToolUse hook, so a locked database lets the tool through
// rather than stall the agent (the whole run stays well under 2 s).
const askGuardBusyTimeout = 500 * time.Millisecond

// askGuardInputWait bounds the wait for the hook input: Claude Code writes
// it and closes stdin at once. With the busy timeout the run stays under
// 2 s. A var for tests.
var askGuardInputWait = 500 * time.Millisecond

// askGuardTool is the one tool the guard denies.
const askGuardTool = "AskUserQuestion"

// askGuardInput is the part of Claude Code's PreToolUse input the guard
// reads.
type askGuardInput struct {
	SessionID string `json:"session_id"`
	ToolName  string `json:"tool_name"`
}

// What the agent is told instead of its AskUserQuestion, by the owner's
// presence (spec 2026-10-10-owner-asks-v2 Part 6): present, the question
// goes in the reply as text (the Stop guard records it); away, or whenever
// the presence cannot be read, it goes to ask_owner.
const (
	askToolDenialReasonPresent = "The owner is here: ask this in plain text in your reply (one short question), or " +
		"with ask_owner for a review, a check or several decisions."
	askToolDenialReasonAway = "In a Watchtower workbench, questions to the owner go through ask_owner so they land in " +
		"the owner's stack — file it there and keep working. One decision with 2-3 short options shows as a one-tap Quick ask."
)

// preToolUseDenial is Claude Code's PreToolUse output that denies the tool
// call and hands the reason to the agent.
type preToolUseDenial struct {
	HookSpecificOutput struct {
		HookEventName            string `json:"hookEventName"`
		PermissionDecision       string `json:"permissionDecision"`
		PermissionDecisionReason string `json:"permissionDecisionReason"`
	} `json:"hookSpecificOutput"`
}

var workbenchAskGuardCmd = &cobra.Command{
	Use:   "ask-guard",
	Short: "The workbench ask guard: Claude Code's Stop and PreToolUse(AskUserQuestion) hooks",
	Long: "Two hooks installed by `integrate claude-code --workbench N`, each always exiting 0.\n" +
		"--pre-tool-use (matcher AskUserQuestion): when the hook input on stdin names\n" +
		"AskUserQuestion and workbench N exists, it denies the tool and tells the agent to ask in\n" +
		"plain text when the owner is here in this session, or to file the question with ask_owner\n" +
		"otherwise. Another tool, a deleted workbench, a bad id or any failure before the denial\n" +
		"prints nothing, so the tool runs.\n" +
		"--stop: classifies the turn's final message with the light-tier model and sends back a\n" +
		"request left as text, unless it is one short question the owner is here to see in this\n" +
		"session (then it is recorded for raising later), or a message that says the work is done\n" +
		"without finish_session. It never blocks a continued turn; an input or model failure prints\n" +
		"nothing, and a database failure reads as the owner being away.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench check` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		if workbenchAskGuardFlagPreToolUse == workbenchAskGuardFlagStop {
			return errors.New("ask-guard runs as one Claude Code hook: --pre-tool-use or --stop")
		}
		if checkWorkbenchIDFlags(cmd) != nil {
			return nil // never refuse the tool or block the turn over our own flags
		}
		if workbenchAskGuardFlagStop {
			ctx := cmd.Context()
			if ctx == nil {
				ctx = context.Background()
			}
			runAskGuardStop(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), workbenchAskGuardFlagWorkbench)
			return nil
		}
		runAskGuardHook(cmd.InOrStdin(), cmd.OutOrStdout(), workbenchAskGuardFlagWorkbench)
		return nil
	},
}

var (
	workbenchAskGuardFlagWorkbench  string
	workbenchAskGuardFlagPreToolUse bool
	workbenchAskGuardFlagStop       bool
)

func init() {
	addWorkbenchIDFlag(workbenchAskGuardCmd, &workbenchAskGuardFlagWorkbench, "workbench id")
	workbenchAskGuardCmd.Flags().BoolVar(&workbenchAskGuardFlagPreToolUse, "pre-tool-use", false,
		"run as the Claude Code PreToolUse hook (always exit 0)")
	workbenchAskGuardCmd.Flags().BoolVar(&workbenchAskGuardFlagStop, "stop", false,
		"run as the Claude Code Stop hook (always exit 0)")
	workbenchCmd.AddCommand(workbenchAskGuardCmd)
}

// runAskGuardHook prints the denial when the hook input names
// AskUserQuestion and workbench rawID exists. Its stdout is Claude Code's
// decision, so anything short of that — another tool (our entry ended up
// under a wider matcher), an unreadable input, a bad id, no config, a locked
// or missing database, a deleted workbench (a leftover hook), even a panic —
// prints nothing and the tool runs: the guard never traps a turn (PROJ-13).
// Once the workbench is found it always denies; only the reason depends on
// the owner's presence.
func runAskGuardHook(stdin io.Reader, stdout io.Writer, rawID string) {
	defer func() { _ = recover() }()
	ctx, cancel := context.WithTimeout(context.Background(), askGuardInputWait)
	in, err := readHookInput[askGuardInput](ctx, stdin)
	cancel()
	if err != nil || in.ToolName != askGuardTool {
		return
	}
	reason := askGuardToolReason(rawID, in.SessionID)
	if reason == "" {
		return
	}
	var out preToolUseDenial
	out.HookSpecificOutput.HookEventName = "PreToolUse"
	out.HookSpecificOutput.PermissionDecision = "deny"
	out.HookSpecificOutput.PermissionDecisionReason = reason
	_ = json.NewEncoder(stdout).Encode(out)
}

// askGuardToolReason is the denial reason for an AskUserQuestion of
// conversation claudeID in workbench rawID, "" when the workbench does not
// exist or cannot be read (the tool runs). It only reads: db.OpenExisting
// (query_only, never creating or migrating) under askGuardBusyTimeout. A var
// for tests.
var askGuardToolReason = func(rawID, claudeID string) string {
	id, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || id <= 0 {
		return ""
	}
	cfg, err := askGuardConfig()
	if err != nil {
		return ""
	}
	database, err := db.OpenExisting(cfg.DBPath(), askGuardBusyTimeout)
	if err != nil {
		return ""
	}
	defer database.Close()
	if _, err := database.GetWorkbench(id); err != nil {
		return ""
	}
	if askGuardOwnerHere(database, id, claudeID) {
		return askToolDenialReasonPresent
	}
	return askToolDenialReasonAway
}

// askGuardOwnerHere reports whether the owner is in the Desktop terminal
// session this hook runs in, resolved as the Stop guard does (Part 4.6): a
// claude row of the workbench running conversation claudeID, a folder with
// the core state hooks (without them the Stop guard could not record a
// plain-text question and would send it back), and a fresh presence write
// naming the row. Outside such a row, or on any read failure, the owner is
// away; nothing is printed, on stderr either.
func askGuardOwnerHere(database *db.DB, workbenchID int64, claudeID string) bool {
	rowID, ok, err := terminalSessionRowID()
	if err != nil || !ok || claudeID == "" {
		return false
	}
	g := &askGuardSession{database: database, workbenchID: workbenchID, claudeID: claudeID, rowID: rowID}
	r, err := g.resolve(hookNow())
	return err == nil && r.Present && r.Recordable
}
