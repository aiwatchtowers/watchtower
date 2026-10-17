package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
)

// permissionPollEvery is how often permission-wait reads its request back
// (spec 2026-10-17-phone-permission-answers §4.2 step 3). A var for tests.
var permissionPollEvery = time.Second

// permissionSummaryRunes caps what a request shows the owner.
const permissionSummaryRunes = 2000

// The decisions permission-wait prints. Allow is for this one call: never
// updatedInput, never updatedPermissions (a phone allows a call, not a rule).
const (
	permissionAllowOutput = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	permissionDenyOutput  = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the owner's phone."}}}`
)

var workbenchPermissionWaitFlagWorkbench string

var workbenchPermissionWaitCmd = &cobra.Command{
	Use:   "permission-wait",
	Short: "Let the owner's phone answer a Claude Code permission prompt (a Claude Code hook)",
	Long: "The synchronous PermissionRequest hook installed by `integrate claude-code --workbench N`:\n" +
		"it records the prompt on the Desktop terminal's row named by\n" +
		"WATCHTOWER_TERMINAL_SESSION_ID (state Needs approval, a pending permission request) and\n" +
		"waits until the owner's phone allows or denies it, then prints the decision. When the\n" +
		"owner answers at the Mac first, the session leaves the board, or the hook is stopped, it\n" +
		"prints nothing and the prompt stays on the Mac. Without that variable it does nothing.\n" +
		"It always exits 0.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench session-state` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := checkWorkbenchIDFlags(cmd); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: permission request not recorded: %v\n", err)
			return nil
		}
		base := cmd.Context()
		if base == nil {
			base = context.Background()
		}
		ctx, stop := signal.NotifyContext(base, syscall.SIGTERM, os.Interrupt)
		defer stop()
		runPermissionWaitHook(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(),
			workbenchPermissionWaitFlagWorkbench)
		return nil
	},
}

func init() {
	addWorkbenchIDFlag(workbenchPermissionWaitCmd, &workbenchPermissionWaitFlagWorkbench, "workbench id")
	workbenchCmd.AddCommand(workbenchPermissionWaitCmd)
}

// runPermissionWaitHook is `workbench permission-wait`. stdout carries the
// decision and nothing else; every failure is one stderr line and no
// decision, so the prompt stays on the Mac. Without the terminal env var the
// session is not a Desktop row: stdin is not even read.
func runPermissionWaitHook(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, rawWorkbenchID string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: permission request not recorded: panic: %v\n", r)
		}
	}()
	rowID, ok, err := terminalSessionRowID()
	if !ok {
		return
	}
	if err == nil {
		var decision string
		decision, err = waitPermissionDecision(ctx, stdin, rowID, rawWorkbenchID)
		if decision != "" {
			fmt.Fprint(stdout, decision)
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: permission request not recorded: %v\n", err)
	}
}

// waitPermissionDecision records the request (spec §4.2 step 2) and waits
// for its answer (step 3): the decision to print, or "" for none.
func waitPermissionDecision(ctx context.Context, stdin io.Reader, rowID int64, rawWorkbenchID string) (string, error) {
	workbenchID, err := strconv.ParseInt(strings.TrimSpace(rawWorkbenchID), 10, 64)
	if err != nil || workbenchID <= 0 {
		return "", fmt.Errorf("invalid --workbench %q", briefClip(rawWorkbenchID, 40))
	}
	at := hookNow().Truncate(time.Millisecond) // the stored precision
	readCtx, cancel := context.WithTimeout(ctx, sessionStateInputWait)
	in, err := readHookEvent(readCtx, stdin, sessionStateStdinLimit, agentkind.Claude)
	cancel()
	if errors.Is(err, io.EOF) {
		return "", nil // a manual run with stdin closed
	}
	if err != nil {
		return "", fmt.Errorf("reading the hook input: %w", err)
	}
	if in.Event != "PermissionRequest" || in.SessionID == "" {
		return "", nil
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return "", err
	}
	defer database.Close()
	row, err := hookSessionRow(database, rowID, workbenchID, in.SessionID)
	if row == nil || err != nil || row.Kind != string(agentkind.Claude) || row.Finished {
		return "", err
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return "", err
	}
	id, err := database.OpenPermissionRequest(row.ID, workbenchID, in.SessionID, in.ToolName,
		permissionSummary(in.ToolName, in.ToolInput), at, db.AgentOrder{})
	if err != nil {
		return "", err
	}
	return pollPermissionRequest(ctx, database, id, workbenchID, in.SessionID)
}

// pollPermissionRequest reads request id back every permissionPollEvery
// until it is decided. The phone's allow or deny is the decision. The Mac
// answered when the session's state moved past the request's time to a
// state other than approval (a tool's working, a Mac deny's waiting, a
// subagent's event alike: any of them fails safe) or the session left the
// board or finished: the request is closed answered_on_mac and nothing is
// printed. A request closed by anything else (a newer prompt of the
// session, the Desktop's expiry) and a cancelled ctx print nothing.
func pollPermissionRequest(ctx context.Context, database *db.DB, id, workbenchID int64, sessionID string) (string, error) {
	ticker := time.NewTicker(permissionPollEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return "", nil
		case <-ticker.C:
		}
		req, err := database.GetPermissionRequest(id)
		if errors.Is(err, db.ErrPermissionRequestNotFound) {
			return "", nil // the session's row was deleted, its requests with it
		}
		if err != nil {
			return "", err
		}
		switch req.Status {
		case db.PermissionAllowed:
			return permissionAllowOutput, nil
		case db.PermissionDenied:
			return permissionDenyOutput, nil
		case db.PermissionPending:
		default:
			return "", nil
		}
		row, err := hookSessionRow(database, req.TerminalSessionID, workbenchID, sessionID)
		if err != nil {
			return "", err
		}
		if row == nil || row.Finished ||
			(row.AgentStateAt.After(req.CreatedAt) && row.AgentState.String != agentStateApproval) {
			_, err := database.ClosePermissionRequest(id, db.PermissionAnsweredOnMac, hookNow())
			return "", err
		}
	}
}

// permissionSummary is what a permission request shows the owner, at most
// permissionSummaryRunes runes: a Bash command (and its description on the
// next line), the file an Edit, Write or NotebookEdit touches, the URL a
// WebFetch reads, otherwise the tool input as compact JSON.
func permissionSummary(toolName string, toolInput json.RawMessage) string {
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(toolInput, &fields)
	str := func(key string) string {
		var s string
		if json.Unmarshal(fields[key], &s) != nil {
			return ""
		}
		return s
	}
	var s string
	switch toolName {
	case "Bash":
		s = str("command")
		if d := str("description"); s != "" && d != "" {
			s += "\n" + d
		}
	case "Edit", "Write", "NotebookEdit":
		s = str("file_path")
		if s == "" {
			s = str("notebook_path") // NotebookEdit's own field
		}
	case "WebFetch":
		s = str("url")
	}
	if s == "" {
		var buf bytes.Buffer
		if json.Compact(&buf, toolInput) == nil {
			s = buf.String()
		} else {
			s = strings.TrimSpace(string(toolInput))
		}
	}
	return clipRunes(s, permissionSummaryRunes)
}
