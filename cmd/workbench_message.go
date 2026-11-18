package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/sessionmsg"
	"watchtower/internal/sessionstart"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchfolders"
)

var workbenchMessageCmd = &cobra.Command{
	Use:   "message",
	Short: "Agent messages between the sessions of a workbench",
	Long: "send queues a message from this terminal session ($WATCHTOWER_TERMINAL_SESSION_ID) to another live\n" +
		"agent session of its workbench, as the MCP tool send_to_session does (agents use the tool; the CLI is\n" +
		"for tests); the daemon types it in. dismiss is the app's Dismiss of the notice for an agent message\n" +
		"left typed in a session's prompt: it records the prompt as cleared, only when nothing cleared it yet,\n" +
		"and is refused inside a terminal session or under an AI agent.",
}

var (
	messageFlagTo        int64
	messageFlagID        int64
	messageFlagTextStdin bool
	messageFlagJSON      bool
)

// maxMessageBytes bounds a message read from stdin (the text itself is
// capped at sessionmsg.MaxTextRunes).
const maxMessageBytes = 64 << 10

func init() {
	send := &cobra.Command{Use: "send", Short: "Queue a message to another live session of the workbench", Args: cobra.NoArgs,
		RunE: runWorkbenchMessageSend}
	send.Flags().Int64Var(&messageFlagTo, "to", 0, "the receiving terminal session id")
	send.Flags().BoolVar(&messageFlagTextStdin, "text-stdin", false, "read the message from stdin (required)")
	dismiss := &cobra.Command{Use: "dismiss", Short: "Record that an agent message left the receiver's prompt (the app's Dismiss)",
		Args: cobra.NoArgs, RunE: runWorkbenchMessageDismiss}
	dismiss.Flags().Int64Var(&messageFlagID, "id", 0, "the message id")
	for _, c := range []*cobra.Command{send, dismiss} {
		c.Flags().BoolVar(&messageFlagJSON, "json", false, "output JSON")
		workbenchMessageCmd.AddCommand(c)
	}
	workbenchCmd.AddCommand(workbenchMessageCmd)
}

// messageSendOutput is send's answer (send_to_session's result).
type messageSendOutput struct {
	MessageID int64  `json:"message_id"`
	State     string `json:"state"`
	Warning   string `json:"warning,omitempty"`
}

// messageDismissOutput is dismiss's --json answer, the shape the Desktop
// decodes: {"ok":true}, or ok false with the refusal's code and its
// "<code>: <sentence>" text (spec D42).
type messageDismissOutput struct {
	OK        bool   `json:"ok"`
	ErrorCode string `json:"error_code,omitempty"`
	Error     string `json:"error,omitempty"`
}

// Dismiss refusal codes.
const (
	dismissNotFound   = "not_found"
	dismissNotAllowed = "not_allowed"
)

// dismissRefused answers a refused dismiss: with --json ok false, its code
// and "<code>: <sentence>"; exit 1 either way.
func dismissRefused(cmd *cobra.Command, code, sentence string) error {
	err := fmt.Errorf("%s: %s", code, sentence)
	if messageFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), messageDismissOutput{ErrorCode: code, Error: err.Error()}); werr != nil {
			return werr
		}
	}
	return &exitCodeError{code: 1, err: err}
}

func runWorkbenchMessageSend(cmd *cobra.Command, _ []string) error {
	if messageFlagTo <= 0 {
		return usageError("--to: a positive terminal session id is required")
	}
	if !messageFlagTextStdin {
		return usageError("--text-stdin is required: the message is read from stdin, never argv")
	}
	from, err := envTerminalSession(os.LookupEnv)
	if err != nil {
		return err
	}
	if from == 0 {
		return usageError("send runs inside a terminal session (%s): a message needs a session to reply to", terminalSessionEnv)
	}
	b, err := io.ReadAll(io.LimitReader(cmd.InOrStdin(), maxMessageBytes+1))
	if err != nil {
		return fmt.Errorf("reading the message from stdin: %w", err)
	}
	if len(b) > maxMessageBytes {
		return usageError("--text-stdin: the message is over %d bytes", maxMessageBytes)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	deps := workbenchSessionDeps(cfg)
	id, state, err := sessionmsg.Send(cmdContext(cmd), database, deps.Live, from, messageFlagTo, string(b))
	if err != nil {
		return messageRefused(cmd, err)
	}
	out := messageSendOutput{MessageID: id, State: state}
	if running, err := deps.DaemonRunning(); err != nil || !running {
		out.Warning = sessionmsg.DaemonNotRunningWarning
	} else {
		deps.Wake()
	}
	if messageFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "message: %d\nstate: %s\n", out.MessageID, out.State)
	if out.Warning != "" {
		fmt.Fprintln(cmd.ErrOrStderr(), "warning: "+out.Warning)
	}
	return nil
}

// messageRefused answers a send refusal ("<code>: <sentence>", spec D42):
// with --json an ok:false result with its code, exit 1 either way; any
// other error as is.
func messageRefused(cmd *cobra.Command, err error) error {
	var r *workbenchfolders.Refusal
	if !errors.As(err, &r) {
		return err
	}
	if messageFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), sessionStartRefusal{ErrorCode: r.Code, Error: r.Error()}); werr != nil {
			return werr
		}
	}
	return &exitCodeError{code: 1, err: r}
}

func runWorkbenchMessageDismiss(cmd *cobra.Command, _ []string) error {
	if messageFlagID <= 0 {
		return usageError("--id: a positive message id is required")
	}
	caller, err := envTerminalSession(os.LookupEnv)
	if err != nil {
		return err
	}
	if caller != 0 {
		return dismissRefused(cmd, dismissNotAllowed,
			fmt.Sprintf("dismiss is the owner's, from the app: refused inside terminal session %d.", caller))
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	var wb int64
	err = database.QueryRowContext(cmdContext(cmd), `SELECT workbench_id FROM session_messages WHERE id = ?`, messageFlagID).Scan(&wb)
	if errors.Is(err, sql.ErrNoRows) {
		return dismissRefused(cmd, dismissNotFound, fmt.Sprintf("there is no agent message #%d.", messageFlagID))
	}
	if err != nil {
		return fmt.Errorf("reading session message %d: %w", messageFlagID, err)
	}
	// Under an AI agent's marker with no session of its own: refused.
	if err := checkSessionCaller(database, wb); err != nil {
		return dismissRefused(cmd, dismissNotAllowed, err.Error()+".")
	}
	if err := database.ClearPromptFlag(cmdContext(cmd), messageFlagID, time.Now()); err != nil {
		return err //nolint:wrapcheck // ClearPromptFlag names the message
	}
	if messageFlagJSON {
		return writeJSON(cmd.OutOrStdout(), messageDismissOutput{OK: true})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "message %d dismissed\n", messageFlagID)
	return nil
}

// workbenchSessionDeps is how this process reaches the session host, the
// daemon and the CLI for agent messages and sub-sessions: liveness from the
// host's list (never starting a host), the daemon by its pid file alone
// (never the sync lock), its wake signal when it advertises the messages
// wake, and `workbench session start` as a child process (the one start
// path).
func workbenchSessionDeps(cfg *config.Config) tools.SessionDeps {
	return tools.SessionDeps{
		Live: func(ctx context.Context, sessionID int64) (bool, error) {
			runs, err := hostRuns(ctx, cfg)
			return runs[sessionID], err
		},
		Runs:          func(ctx context.Context) (map[int64]bool, error) { return hostRuns(ctx, cfg) },
		DaemonRunning: func() (bool, error) { return daemon.DaemonRunning(cfg.WorkspaceDir()) },
		Wake:          func() { wakeSessionMessages(cfg) },
		StartSession:  runSubSessionStart,
	}
}

// hostRuns is every session with a run in the session host; none when no
// host runs (a read never starts one).
func hostRuns(ctx context.Context, cfg *config.Config) (map[int64]bool, error) {
	p := sessionstart.NewPort(sessionStartDeps(cfg, nil), nil)
	defer func() { _ = p.Close() }()
	runs, err := p.Runs(ctx)
	if errors.Is(err, sessionstart.ErrHostNotRunning) {
		return map[int64]bool{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the session host: %w", err)
	}
	out := make(map[int64]bool, len(runs))
	for id := range runs {
		out[id] = true
	}
	return out, nil
}

// wakeSessionMessages sends the running daemon its wake signal when it
// advertises SessionMessagesWakeCapability; otherwise (none, an older one,
// any failure) the deliverer's tick picks the message up.
func wakeSessionMessages(cfg *config.Config) {
	pidPath := pidFilePath(cfg)
	pid, state, err := daemon.PeekProcess(pidPath)
	if err != nil || state != daemon.PeekRunning {
		return
	}
	if ok, err := daemon.HasCapability(pidPath, pid, daemon.SessionMessagesWakeCapability); err != nil || !ok {
		return
	}
	_ = automationWakeKill(pid, daemon.AutomationWakeSignal)
}
