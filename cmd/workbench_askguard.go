package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/workbenchmethod"
)

// askGuardBusyTimeout bounds each of the ask guard's reads: Claude Code
// waits for a PreToolUse hook, so a locked database lets the tool through
// rather than stall the agent.
const askGuardBusyTimeout = 500 * time.Millisecond

// askGuardInputWait bounds the wait for the hook input: Claude Code writes
// it and closes stdin at once. A var for tests.
var askGuardInputWait = 500 * time.Millisecond

// askGuardReadBudget bounds the PreToolUse hook's reads together, from the
// database open on: the workbench read (askGuardBusyTimeout), then the
// presence reads (the session row, its workbench, the hooks, the presence),
// cut off at the budget's end and read as away. With askGuardInputWait the
// hook finishes in under 2 s (PROJ-13).
const askGuardReadBudget = 1400 * time.Millisecond

// askGuardTool is the one tool the guard denies; codexAskGuardTool is
// Codex's ask-the-user tool (spec 2026-10-12 §6.4, C9).
const (
	askGuardTool      = "AskUserQuestion"
	codexAskGuardTool = "request_user_input"
)

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
		"AskUserQuestion and workbench N exists, it denies the tool (by the workbench's ask guard mode:\n" +
		"strict always, soft while the owner is away, off never) and tells the agent to ask in\n" +
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
		agent, err := hookAgentFor(cmd, workbenchAskGuardFlagAgent)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: ask guard skipped: %v\n", err)
			return nil // never refuse the tool or block the turn over our own flags
		}
		if agent == agentkind.Codex {
			runCodexAskGuard(cmd)
			return nil
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
	workbenchAskGuardFlagAgent      string
	workbenchAskGuardFlagPreToolUse bool
	workbenchAskGuardFlagStop       bool
)

func init() {
	workbenchAskGuardCmd.Flags().StringVar(&workbenchAskGuardFlagWorkbench, workbenchFlag, "", "workbench id")
	addHookAgentFlag(workbenchAskGuardCmd, &workbenchAskGuardFlagAgent)
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
// Once the workbench is found it denies by the workbench's ask guard mode
// (askToolReasonFor): strict always, soft only while the owner is away, off never.
func runAskGuardHook(stdin io.Reader, stdout io.Writer, rawID string) {
	defer func() { _ = recover() }()
	ctx, cancel := context.WithTimeout(context.Background(), askGuardInputWait)
	in, err := readHookEvent(ctx, stdin, hookStdinLimit, agentkind.Claude)
	cancel()
	if err != nil || in.ToolName != askGuardTool {
		return
	}
	reason := askGuardToolReason(rawID, in.SessionID)
	if reason == "" {
		return
	}
	writeToolDenial(stdout, reason)
}

// writeToolDenial prints the PreToolUse output denying the tool with reason
// (the same JSON for Claude Code and Codex, C7).
func writeToolDenial(stdout io.Writer, reason string) {
	var out preToolUseDenial
	out.HookSpecificOutput.HookEventName = "PreToolUse"
	out.HookSpecificOutput.PermissionDecision = "deny"
	out.HookSpecificOutput.PermissionDecisionReason = reason
	_ = json.NewEncoder(stdout).Encode(out)
}

// runCodexAskGuard is `workbench ask-guard --agent codex`, the --stop or
// --pre-tool-use hook on the Codex row it runs in.
func runCodexAskGuard(cmd *cobra.Command) {
	if workbenchAskGuardFlagStop {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		runCodexAskGuardStop(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr())
		return
	}
	runCodexAskGuardHook(cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr())
}

// runCodexAskGuardHook is runAskGuardHook for Codex: on its row, a
// request_user_input is denied by the ask guard mode (askToolReasonFor), with
// the present or the away reason by the owner's presence in this session (read within
// askGuardReadBudget). Another tool, no row, or a failure before the denial
// prints nothing on stdout, so the tool runs (PROJ-13).
func runCodexAskGuardHook(stdin io.Reader, stdout, stderr io.Writer) {
	defer func() { _ = recover() }()
	row, in, ok := readCodexHook(stdin, stderr, "ask guard skipped", askGuardInputWait, hookStdinLimit, openAskGuardDB)
	if !ok || in.ToolName != codexAskGuardTool {
		return
	}
	reason := askToolDenialReasonAway
	deadline := time.Now().Add(askGuardReadBudget)
	if database, err := openAskGuardDB(); err == nil {
		reason = askGuardReasonBy(database, deadline, row.WorkbenchID.Int64, row.ID, false, func(d *db.DB) bool {
			return askGuardOwnerHereIn(d, row.WorkbenchID.Int64, row.ID, in.SessionID, agentkind.Codex)
		})
	}
	if reason == "" {
		return
	}
	writeToolDenial(stdout, reason)
}

// askGuardToolReason is the denial reason for an AskUserQuestion of
// conversation claudeID in workbench rawID, "" when the workbench does not
// exist or cannot be read, or when its ask guard mode lets the tool run (off,
// or soft with the owner here): the tool runs. It only reads: db.OpenExisting
// (query_only, never creating or migrating) under askGuardBusyTimeout. A var
// for tests.
var askGuardToolReason = func(rawID, claudeID string) string {
	id, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || id <= 0 {
		return ""
	}
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return ""
	}
	deadline := time.Now().Add(askGuardReadBudget)
	database, err := db.OpenExisting(cfg.DBPath(), askGuardBusyTimeout)
	if err != nil {
		return ""
	}
	if _, err := database.GetWorkbench(id); err != nil {
		_ = database.Close()
		return ""
	}
	// An absent variable is no Desktop row (the workbench folder's rules); a
	// present but unreadable one is strict, never a weaker mode.
	rowID, _, rowErr := terminalSessionRowID()
	presence := askGuardOwnerPresence
	return askGuardReasonBy(database, deadline, id, rowID, rowErr != nil, func(d *db.DB) bool { return presence(d, id, claudeID) })
}

// askGuardToolMode is the workbench's ask guard mode for a PreToolUse hook
// in row rowID (0 = outside a Desktop row), resolved like the Stop guard's;
// a failed read is strict (PROJ-13).
func askGuardToolMode(database *db.DB, workbenchID, rowID int64) string {
	e := workbenchmethod.ResolveSession(database, workbenchID, rowID)
	if e.Err != nil {
		return workbenchmethod.AskGuardStrict
	}
	return e.AskGuard
}

// askToolReasonFor is the PreToolUse decision by mode (spec 2026-10-15 §7.2,
// PROJ-13); "" lets the tool run. strict always denies — ask in plain text
// when the owner is here, else ask_owner; soft denies only while the owner
// is away; off never denies. An unknown mode is strict.
func askToolReasonFor(mode string, here bool) string {
	switch {
	case mode == workbenchmethod.AskGuardOff, mode == workbenchmethod.AskGuardSoft && here:
		return ""
	case mode != workbenchmethod.AskGuardSoft && here:
		return askToolDenialReasonPresent
	}
	return askToolDenialReasonAway
}

// askGuardReasonBy is the PreToolUse reason for the mode and, unless the
// mode is off, the owner's presence (presence), both read on database inside
// the one budget ending at deadline: a read cut by it, like a failing one,
// resolves strict with the owner away. The database is closed once the
// reads end (sql.DB.Close waits for a running query, so the hook does not).
// strict forces strict (an unreadable session variable). A panic in a read
// also resolves strict with the owner away.
func askGuardReasonBy(database *db.DB, deadline time.Time, workbenchID, rowID int64, strict bool, presence func(*db.DB) bool) string {
	reason := make(chan string, 1)
	go func() {
		defer func() { _ = database.Close() }()
		defer func() {
			if recover() != nil {
				select {
				case reason <- askToolDenialReasonAway:
				default:
				}
			}
		}()
		mode := workbenchmethod.AskGuardStrict
		if !strict {
			mode = askGuardToolMode(database, workbenchID, rowID)
		}
		if mode == workbenchmethod.AskGuardOff {
			reason <- ""
			return
		}
		reason <- askToolReasonFor(mode, presence(database))
	}()
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case r := <-reason:
		return r
	case <-timer.C:
		return askToolDenialReasonAway
	}
}

// openAskGuardDB opens the database the way the guard reads it: never
// creating or migrating it, reads under askGuardBusyTimeout (query_only).
func openAskGuardDB() (*db.DB, error) {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return nil, err
	}
	return db.OpenExisting(cfg.DBPath(), askGuardBusyTimeout)
}

// askGuardOwnerPresence is askGuardOwnerHere; a var for tests.
var askGuardOwnerPresence = askGuardOwnerHere

// askGuardOwnerHere reports whether the owner is in the Desktop terminal
// session this hook runs in, resolved as the Stop guard does (Part 4.6): a
// claude row of the workbench running conversation claudeID, a folder with
// the core state hooks (without them the Stop guard could not record a
// plain-text question and would send it back), and a fresh presence write
// naming the row. Outside such a row, or on any read failure, the owner is
// away; nothing is printed, on stderr either. A panic here, after the
// workbench was found, also reads as away: the tool stays denied.
func askGuardOwnerHere(database *db.DB, workbenchID int64, claudeID string) bool {
	rowID, ok, err := terminalSessionRowID()
	if err != nil || !ok {
		return false
	}
	return askGuardOwnerHereIn(database, workbenchID, rowID, claudeID, agentkind.Claude)
}

// askGuardOwnerHereIn is askGuardOwnerHere on row rowID, an agent row of
// kind: the owner is here when the row runs conversation claudeID, can
// record a plain-text question, and has a fresh presence write.
func askGuardOwnerHereIn(database *db.DB, workbenchID, rowID int64, claudeID string, kind agentkind.Kind) (here bool) {
	defer func() {
		if recover() != nil {
			here = false
		}
	}()
	if claudeID == "" {
		return false
	}
	g := &askGuardSession{database: database, workbenchID: workbenchID, claudeID: claudeID, rowID: rowID, kind: kind}
	r, err := g.resolve(hookNow())
	return err == nil && r.Present && r.Recordable
}
