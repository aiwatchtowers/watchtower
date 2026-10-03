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

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// askGuardBusyTimeout bounds the ask guard's one read: Claude Code waits
// for a PreToolUse hook, so a locked database lets the tool through rather
// than stall the agent (the whole run stays well under 2 s).
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
	ToolName string `json:"tool_name"`
}

// askToolDenialReason is what the agent is told instead of its
// AskUserQuestion (spec 2026-10-03 §6.3).
const askToolDenialReason = "In a Watchtower workbench, questions to the owner go through ask_owner so they land in the owner's stack — file it there and keep working."

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
	Short: "Deny AskUserQuestion in a workbench session (a Claude Code PreToolUse hook)",
	Long: "The PreToolUse hook installed by `integrate claude-code --workbench N` with matcher\n" +
		"AskUserQuestion: when the hook input on stdin names AskUserQuestion and workbench N exists,\n" +
		"it denies the tool and tells the agent to file the question with ask_owner. Another tool,\n" +
		"a deleted workbench, a bad id or any failure prints nothing, so the tool runs. With\n" +
		"--pre-tool-use it always exits 0.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench check` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		if !workbenchAskGuardFlagPreToolUse {
			return errors.New("ask-guard only runs as the Claude Code PreToolUse hook (--pre-tool-use)")
		}
		if checkWorkbenchIDFlags(cmd) != nil {
			return nil // never refuse the tool over our own flags
		}
		runAskGuardHook(cmd.InOrStdin(), cmd.OutOrStdout(), workbenchAskGuardFlagWorkbench)
		return nil
	},
}

var (
	workbenchAskGuardFlagWorkbench  string
	workbenchAskGuardFlagPreToolUse bool
)

func init() {
	addWorkbenchIDFlag(workbenchAskGuardCmd, &workbenchAskGuardFlagWorkbench, "workbench id")
	workbenchAskGuardCmd.Flags().BoolVar(&workbenchAskGuardFlagPreToolUse, "pre-tool-use", false,
		"run as the Claude Code PreToolUse hook (always exit 0)")
	workbenchCmd.AddCommand(workbenchAskGuardCmd)
}

// runAskGuardHook prints the denial when the hook input names
// AskUserQuestion and workbench rawID exists. Its stdout is Claude Code's
// decision, so anything short of that — another tool (our entry ended up
// under a wider matcher), an unreadable input, a bad id, no config, a locked
// or missing database, a deleted workbench (a leftover hook), even a panic —
// prints nothing and the tool runs: the guard never traps a turn (PROJ-13).
func runAskGuardHook(stdin io.Reader, stdout io.Writer, rawID string) {
	defer func() { _ = recover() }()
	ctx, cancel := context.WithTimeout(context.Background(), askGuardInputWait)
	in, err := readHookInput[askGuardInput](ctx, stdin)
	cancel()
	if err != nil || in.ToolName != askGuardTool {
		return
	}
	if !askGuardWorkbenchLive(rawID) {
		return
	}
	var out preToolUseDenial
	out.HookSpecificOutput.HookEventName = "PreToolUse"
	out.HookSpecificOutput.PermissionDecision = "deny"
	out.HookSpecificOutput.PermissionDecisionReason = askToolDenialReason
	_ = json.NewEncoder(stdout).Encode(out)
}

// askGuardWorkbenchLive reports whether workbench rawID exists, reading the
// database without migrating it and under askGuardBusyTimeout. A var for
// tests.
var askGuardWorkbenchLive = func(rawID string) bool {
	id, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || id <= 0 {
		return false
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return false
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if cfg.ValidateWorkspace() != nil {
		return false
	}
	database, err := db.OpenExisting(cfg.DBPath(), askGuardBusyTimeout)
	if err != nil {
		return false
	}
	defer database.Close()
	_, err = database.GetWorkbench(id)
	return err == nil
}
