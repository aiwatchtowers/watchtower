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
	"unicode/utf8"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/askanswer"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/watchman"
)

// permissionPollEvery is how often permission-wait reads its request back
// (spec 2026-10-17-phone-permission-answers §4.2 step 3). A var for tests.
var permissionPollEvery = time.Second

// permissionReadFailures is how many reads in a row may fail before the
// wait gives up and closes its request expired.
const permissionReadFailures = 3

// readPermissionRequest is the poll's read; a var so a test can fail it.
var readPermissionRequest = (*db.DB).GetPermissionRequest

// permissionSummaryRunes caps what a request shows the owner.
const permissionSummaryRunes = 2000

// The decisions permission-wait prints. Allow is for this one call: never
// updatedInput, never updatedPermissions (a phone allows a call, not a rule).
// A deny decided by the Mac's Workchat card (`decided_by = "Mac"`) says so,
// and so does one decided by Watchman, the owner's twin (`decided_by =
// "watchman"`); an allow is the same whoever decided it.
const (
	permissionAllowOutput   = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	permissionDenyOutput    = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the owner's phone."}}}`
	permissionMacDenyOutput = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied by the owner at the Mac."}}}`
	// permissionDeniedByWatchman is the agent's text for a twin's deny (spec
	// 2026-11-16-watchman-design, verbatim).
	permissionDeniedByWatchman   = "Watchman (the owner's twin) denied this — the owner decides it in the morning; continue with other work"
	permissionWatchmanDenyOutput = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"` +
		permissionDeniedByWatchman + `"}}}`
)

// permissionDecidedByMac is the `decided_by` the Desktop's Workchat writes.
const permissionDecidedByMac = "Mac"

var workbenchPermissionWaitFlagWorkbench string

var workbenchPermissionWaitCmd = &cobra.Command{
	Use:   "permission-wait",
	Short: "Let the owner's phone answer a Claude Code permission prompt (a Claude Code hook)",
	Long: "The synchronous PermissionRequest hook installed by `integrate claude-code --workbench N`:\n" +
		"it records the prompt on the Desktop terminal's row named by\n" +
		"WATCHTOWER_TERMINAL_SESSION_ID (state Needs approval, a pending permission request) and\n" +
		"waits until the owner's phone allows or denies it, then prints the decision. When the\n" +
		"owner answers at the Mac first, the session leaves the board, or the hook is stopped (the\n" +
		"request is then closed expired), it prints nothing and the prompt stays on the Mac.\n" +
		"Without that variable it does nothing.\n" +
		"It always exits 0.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench session-state` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		ctx, stop := signal.NotifyContext(cmd.Context(), syscall.SIGTERM, os.Interrupt)
		defer stop()
		runPermissionWaitHook(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(),
			workbenchPermissionWaitFlagWorkbench)
		return nil
	},
}

func init() {
	workbenchPermissionWaitCmd.Flags().StringVar(&workbenchPermissionWaitFlagWorkbench, workbenchFlag, "", "workbench id")
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
		decision, err = waitPermissionDecision(ctx, stdin, stderr, rowID, rawWorkbenchID)
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
func waitPermissionDecision(ctx context.Context, stdin io.Reader, stderr io.Writer, rowID int64, rawWorkbenchID string) (string, error) {
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
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return "", err
	}
	defer database.Close()
	row, err := hookSessionRow(database, rowID, workbenchID, in.SessionID)
	if row == nil || err != nil || !sessionagent.CapsOf(row.Kind).PermissionWait || row.Finished {
		return "", err
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return "", err
	}
	summary, clipped := permissionSummary(in.ToolName, in.ToolInput)
	id, err := database.OpenPermissionRequest(row.ID, workbenchID, in.SessionID, in.ToolName,
		summary, clipped, at, db.AgentOrder{})
	if err != nil {
		return "", err
	}
	queueWatchmanPermission(stderr, cfg, database, db.WatchmanItem{
		WorkbenchID: workbenchID, SessionID: row.ID,
		Kind: "permission", RefKind: "permission", RefID: id,
		Question: watchman.ItemQuestion(db.WatchmanPermissionText(in.ToolName, summary)),
	})
	return pollPermissionRequest(ctx, stderr, database, id, workbenchID, in.SessionID)
}

// permissionWatchmanWake wakes the daemon for a prompt's queued item; a var
// for tests.
var permissionWatchmanWake = func(cfg *config.Config) { watchmanWaitPointWake(cfg)() }

// queueWatchmanPermission queues the twin's item for a prompt of an armed
// session (spec 2026-11-16-watchman-design §3, §4) and wakes the daemon for
// a new one. A failure is one stderr line naming the request: the prompt
// stays the owner's and the wait goes on as without Watchman (spec §7).
func queueWatchmanPermission(stderr io.Writer, cfg *config.Config, database *db.DB, it db.WatchmanItem) {
	_, inserted, err := database.QueueWatchmanWaitPoint(it)
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: permission request %d was not queued for Watchman (it stays the owner's): %v\n", it.RefID, err)
		return
	}
	if inserted {
		permissionWatchmanWake(cfg)
	}
}

// pollPermissionRequest reads request id back every permissionPollEvery
// until it is decided (checkPermissionRequest). A stopped hook (ctx done:
// its timeout, Claude Code quitting, a signal) closes the request expired,
// so the phone no longer offers an answer nothing reads. A failed read is
// one stderr line and the poll goes on; permissionReadFailures in a row
// close the request expired too. Either close is a compare-and-set: an
// answer that landed first stays.
func pollPermissionRequest(ctx context.Context, stderr io.Writer, database *db.DB, id, workbenchID int64,
	sessionID string) (string, error) {
	ticker := time.NewTicker(permissionPollEvery)
	defer ticker.Stop()
	failures := 0
	for {
		select {
		case <-ctx.Done():
			return "", expirePermissionRequest(database, id)
		case <-ticker.C:
		}
		decision, done, err := checkPermissionRequest(stderr, database, id, workbenchID, sessionID)
		if done {
			return decision, err
		}
		if err == nil {
			failures = 0
			continue
		}
		failures++
		fmt.Fprintf(stderr, "watchtower: permission request %d: reading it back (%d of %d): %v\n",
			id, failures, permissionReadFailures, err)
		if failures >= permissionReadFailures {
			return "", expirePermissionRequest(database, id)
		}
	}
}

// checkPermissionRequest is one read of request id. The phone's allow or
// deny is the decision. The Mac answered when the session's state moved,
// at or past the request's time, to a state other than approval (a tool's
// working, a Mac deny's waiting, a subagent's event alike: any of them
// fails safe) or the session left the board or finished: the request is
// closed answered_on_mac and nothing is printed. A request closed by
// anything else (a newer prompt of the session, the Desktop's expiry) or
// gone with its session prints nothing. done is false while it waits, and
// on a failed read (err).
func checkPermissionRequest(stderr io.Writer, database *db.DB, id, workbenchID int64,
	sessionID string) (decision string, done bool, err error) {
	req, err := readPermissionRequest(database, id)
	if errors.Is(err, db.ErrPermissionRequestNotFound) {
		return "", true, nil // the session's row was deleted, its requests with it
	}
	if err != nil {
		return "", false, err
	}
	switch req.Status {
	case db.PermissionAllowed:
		return permissionAllowOutput, true, nil
	case db.PermissionDenied:
		switch {
		case req.DecidedBy.Valid && req.DecidedBy.String == permissionDecidedByMac:
			return permissionMacDenyOutput, true, nil
		case req.DecidedBy.Valid && req.DecidedBy.String == askanswer.ByWatchman:
			return permissionWatchmanDenyOutput, true, nil
		}
		return permissionDenyOutput, true, nil
	case db.PermissionPending:
	default:
		return "", true, nil
	}
	row, err := hookSessionRow(database, req.TerminalSessionID, workbenchID, sessionID)
	if err != nil {
		return "", false, err
	}
	if row != nil && !row.Finished &&
		(row.AgentStateAt.Before(req.CreatedAt) || row.AgentState.String == agentStateApproval) {
		return "", false, nil
	}
	closed, err := database.ClosePermissionRequest(id, db.PermissionAnsweredOnMac, "", hookNow())
	if err == nil && !closed {
		// The phone's answer landed after the Mac's: Claude Code keeps the Mac's.
		fmt.Fprintf(stderr, "watchtower: permission request %d: the phone answered after the Mac; the Mac's answer stands\n", id)
	}
	return "", true, err
}

// expirePermissionRequest closes request id expired: no hook reads it any
// more. The database calls take no context, so a cancelled wait still
// writes it, under the busy timeout already set.
func expirePermissionRequest(database *db.DB, id int64) error {
	_, err := database.ClosePermissionRequest(id, db.PermissionExpired, "", hookNow())
	return err
}

// permissionSummary is what a permission request shows the owner,
// permissionSummaryText cut to at most permissionSummaryRunes runes, and
// whether it was cut short (clipped).
func permissionSummary(toolName string, toolInput json.RawMessage) (summary string, clipped bool) {
	s := permissionSummaryText(toolName, toolInput)
	if utf8.RuneCountInString(s) <= permissionSummaryRunes {
		return s, false
	}
	return clipRunes(s, permissionSummaryRunes), true
}

// permissionSummaryText is a tool call as the hard-limit table reads it,
// whole: a Bash command (and its description below it, every line a `# `
// comment, so no line of it reads as part of the command), the file an
// Edit, Write or NotebookEdit touches, the URL a WebFetch reads, otherwise
// the tool input as compact JSON.
func permissionSummaryText(toolName string, toolInput json.RawMessage) string {
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
			for _, line := range strings.Split(d, "\n") {
				s += "\n# " + line
			}
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
	return s
}
