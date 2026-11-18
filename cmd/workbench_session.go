package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionstart"
	"watchtower/internal/workbenchfolders"
)

var workbenchSessionCmd = &cobra.Command{
	Use:   "session",
	Short: "Start and stop workbench agent sessions in the session host",
	Long: "start does what the app's New Session does and answers at once (instant start): it writes the\n" +
		"session row (state starting) and prints it; a detached `session finish` then places it — the\n" +
		"workbench folder, or its own git worktree when a live agent already works there (or as --place\n" +
		"asks) — and launches it in the session host. The row shows the result: running in the host, or\n" +
		"a failure with its reason. --folder starts it in another folder of the workbench (id, name or path;\n" +
		"default the home folder) and --parent records the session it is a sub-session of. stop is the host's Stop request (the exit carries requested: no\n" +
		"worktree cleanup); stopped: true means the session is not running any more (also when it was\n" +
		"not). Inside an agent's terminal session only that session's workbench may be started or stopped.",
}

var (
	sessionFlagWorkbench int64
	sessionFlagTarget    int64
	sessionFlagSession   int64
	sessionFlagAgent     string
	sessionFlagPlace     string
	sessionFlagJSON      bool
	// The Desktop's starts (Go hub 3 Task 8): the row's title, the
	// automation run of a session() step, and the first prompt on stdin.
	sessionFlagTitle         string
	sessionFlagAutomationRun int64
	sessionFlagBriefStdin    bool
	// The bench folder a start is for (id, name or path; "" = the home
	// folder) and the session starting it as a sub-session (spec 2026-11-18
	// §6.4–6.5).
	sessionFlagFolder string
	sessionFlagParent int64
)

// maxBriefBytes bounds a brief read from stdin.
const maxBriefBytes = 1 << 20

// workbenchSessionShell is the login shell a start launches in ("" =
// $SHELL); a test seam.
var workbenchSessionShell = ""

// finishBudget bounds a detached finish: the worktree, its integration and
// the launch.
const finishBudget = 3 * time.Minute

// finishLaunchWatch is how long a finish watches its launch for the agent's
// exit 127 (a test seam).
var finishLaunchWatch = 3 * time.Second

// workbenchSessionFinishSpawn continues a start in a detached
// `workbench session finish` (its own session, no terminal, stdout and
// stderr to /dev/null) so start answers at once. A non-empty brief goes to
// it over an inherited pipe on its stdin (`--brief-stdin`), never argv; the
// finish reads it before anything else, so the write does not wait long. A
// test seam.
var workbenchSessionFinishSpawn = func(sessionID int64, place, brief string) error {
	bin, err := workbenchExecutable()
	if err != nil {
		return fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	args := []string{"workbench", "session", "finish", "--session", strconv.FormatInt(sessionID, 10), "--place", place,
		"--config", flagConfig}
	if flagWorkspace != "" {
		args = append(args, "--workspace", flagWorkspace)
	}
	if brief != "" {
		args = append(args, "--brief-stdin")
	}
	c := exec.Command(bin, args...)
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	var in io.WriteCloser
	if brief != "" {
		if in, err = c.StdinPipe(); err != nil {
			return fmt.Errorf("continuing the start: %w", err)
		}
	}
	if err := c.Start(); err != nil {
		return fmt.Errorf("continuing the start: %w", err)
	}
	if in != nil {
		_, werr := io.WriteString(in, brief)
		if cerr := in.Close(); werr == nil {
			werr = cerr
		}
		if werr != nil {
			// A finish with half a brief must not launch.
			_ = c.Process.Kill()
			_, _ = c.Process.Wait()
			return fmt.Errorf("handing the brief to the start: %w", werr)
		}
	}
	return c.Process.Release() //nolint:wrapcheck // never fails for a started process
}

// maxStartStderr bounds the stderr a failed sub-session start reports.
const maxStartStderr = 2000

// runSubSessionStart is start_session's start (spec 2026-11-18 §6.5): this
// binary's `workbench session start <args>` with the brief on stdin, under
// this process's environment, so checkSessionCaller confines it to the
// calling session's workbench. It answers stdout (the --json answer, a
// refusal's included) and, when the start failed, an error carrying its
// stderr.
func runSubSessionStart(ctx context.Context, args []string, brief string) ([]byte, error) {
	bin, err := workbenchExecutable()
	if err != nil {
		return nil, fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	full := append([]string{"workbench", "session", "start"}, args...)
	full = append(full, "--config", flagConfig)
	if flagWorkspace != "" {
		full = append(full, "--workspace", flagWorkspace)
	}
	c := exec.CommandContext(ctx, bin, full...)
	c.Stdin = strings.NewReader(brief)
	var stderr strings.Builder
	c.Stderr = &stderr
	out, err := c.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if len(msg) > maxStartStderr {
			msg = msg[len(msg)-maxStartStderr:]
		}
		if msg != "" {
			return out, fmt.Errorf("%w: %s", err, msg)
		}
		return out, err //nolint:wrapcheck // the exit status is the message
	}
	return out, nil
}

// readBrief is the brief on stdin when --brief-stdin was given, else "".
func readBrief(cmd *cobra.Command) (string, error) {
	if !sessionFlagBriefStdin {
		return "", nil
	}
	b, err := io.ReadAll(io.LimitReader(cmd.InOrStdin(), maxBriefBytes+1))
	if err != nil {
		return "", fmt.Errorf("reading the brief from stdin: %w", err)
	}
	if len(b) > maxBriefBytes {
		return "", usageError("--brief-stdin: the brief is over %d bytes", maxBriefBytes)
	}
	return string(b), nil
}

func init() {
	start := &cobra.Command{Use: "start", Short: "Start an agent session", Args: cobra.NoArgs, RunE: runWorkbenchSessionStart}
	start.Flags().Int64Var(&sessionFlagWorkbench, workbenchFlag, 0, "workbench id")
	start.Flags().Int64Var(&sessionFlagTarget, "target", 0, "the target the session works on (optional)")
	start.Flags().StringVar(&sessionFlagAgent, "agent", "", "claude or codex (default: workbench.default_agent)")
	start.Flags().StringVar(&sessionFlagPlace, "place", "auto", "folder, worktree or auto")
	start.Flags().StringVar(&sessionFlagTitle, "title", "", "the session's title (default: the target's text, else New session · HH:MM)")
	start.Flags().Int64Var(&sessionFlagAutomationRun, "automation-run", 0, "the automation run whose session() step starts it")
	start.Flags().StringVar(&sessionFlagFolder, "folder", "", "the workbench folder to start in: id, name or path (default: the home folder)")
	start.Flags().Int64Var(&sessionFlagParent, "parent", 0, "the session this one is a sub-session of (same workbench)")
	finish := &cobra.Command{Use: "finish", Short: "Place and launch a row start wrote (run by start, detached)",
		Hidden: true, Args: cobra.NoArgs, RunE: runWorkbenchSessionFinish}
	finish.Flags().Int64Var(&sessionFlagSession, "session", 0, "terminal session id")
	finish.Flags().StringVar(&sessionFlagPlace, "place", "auto", "folder, worktree or auto")
	for _, c := range []*cobra.Command{start, finish} {
		c.Flags().BoolVar(&sessionFlagBriefStdin, "brief-stdin", false,
			"read the first prompt from stdin (default: the target's work-on prompt, else none)")
	}
	workbenchSessionCmd.AddCommand(finish)
	stop := &cobra.Command{Use: "stop", Short: "Stop a session (the host's Stop request)", Args: cobra.NoArgs, RunE: runWorkbenchSessionStop}
	stop.Flags().Int64Var(&sessionFlagSession, "session", 0, "terminal session id")
	for _, c := range []*cobra.Command{start, stop} {
		c.Flags().BoolVar(&sessionFlagJSON, "json", false, "output JSON")
		workbenchSessionCmd.AddCommand(c)
	}
	workbenchCmd.AddCommand(workbenchSessionCmd)
}

// sessionStartOutput is start's answer. FolderID and Folder are the bench
// folder (its stored name) the session started for; Place is the placement
// asked for (auto, folder or worktree — the outcome is the row's once the
// detached finish ran); Worktree the worktree's path once the row is placed
// in one, else "". A refusal is sessionStartRefusal instead.
type sessionStartOutput struct {
	OK             bool   `json:"ok"`
	SessionID      int64  `json:"session_id"`
	State          string `json:"state"`
	FolderPath     string `json:"folder_path"`
	WorktreeBranch string `json:"worktree_branch"`
	FolderID       int64  `json:"folder_id"`
	Folder         string `json:"folder"`
	Place          string `json:"place"`
	Worktree       string `json:"worktree"`
}

// sessionStartRefusal is a refused start's answer: ok false, the refusal's
// code and its "<code>: <sentence>" text (spec D42).
type sessionStartRefusal struct {
	OK        bool   `json:"ok"`
	ErrorCode string `json:"error_code"`
	Error     string `json:"error"`
}

type sessionStopOutput struct {
	SessionID int64 `json:"session_id"`
	Stopped   bool  `json:"stopped"`
}

func runWorkbenchSessionStart(cmd *cobra.Command, _ []string) error {
	if sessionFlagWorkbench <= 0 {
		return usageError("--%s: a positive workbench id is required", workbenchFlag)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := checkSessionCaller(database, sessionFlagWorkbench); err != nil {
		return err
	}
	brief, err := readBrief(cmd)
	if err != nil {
		return err
	}
	ctx := cmdContext(cmd)
	r := handlers.StartRequest{Workbench: sessionFlagWorkbench, Agent: sessionFlagAgent, Place: sessionFlagPlace,
		Title: sessionFlagTitle, AutomationRunID: sessionFlagAutomationRun}
	if sessionFlagTarget > 0 {
		r.Target = &sessionFlagTarget
	}
	r.ParentSessionID = sessionFlagParent
	if sessionFlagFolder != "" {
		f, err := workbenchfolders.Resolve(ctx, database, sessionFlagWorkbench, sessionFlagFolder)
		if err != nil {
			return sessionStartRefused(cmd, err)
		}
		r.FolderID = f.ID
	}
	d := sessionStartDeps(cfg, database)
	res, err := sessionstart.Begin(ctx, d, r)
	var notFound *handlers.AgentNotFoundError
	if errors.As(err, &notFound) {
		// The Desktop's pinned answer (testdata/desktop_contract.json): no row.
		if werr := writeJSON(cmd.OutOrStdout(), map[string]string{
			"error": sessionstart.AgentNotFoundClass, "agent": notFound.Agent,
		}); werr != nil {
			return werr
		}
		return &exitCodeError{code: sessionstart.AgentNotFoundExit, err: err}
	}
	if err != nil {
		return sessionStartRefused(cmd, err)
	}
	if res.State == sessionstart.StateStarting {
		if err := workbenchSessionFinishSpawn(res.SessionID, sessionFlagPlace, brief); err != nil {
			_ = database.SetTerminalSessionLaunchError(ctx, res.SessionID, "the start could not continue", time.Now())
			return err
		}
	}
	out := sessionStartOutput{OK: true, SessionID: res.SessionID, State: res.State, Place: sessionFlagPlace}
	if out.Place == "" {
		out.Place = string(sessionstart.ChoiceAuto)
	}
	var branch sql.NullString
	var folderID sql.NullInt64
	if err := database.QueryRowContext(ctx, `SELECT folder_path, worktree_branch, workbench_folder_id FROM terminal_sessions WHERE id = ?`,
		res.SessionID).Scan(&out.FolderPath, &branch, &folderID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("reading session %d: %w", res.SessionID, err)
	}
	out.WorktreeBranch = branch.String
	if branch.String != "" {
		out.Worktree = out.FolderPath
	}
	if folderID.Valid {
		f, err := database.WorkbenchFolderByID(ctx, folderID.Int64)
		if err != nil {
			return fmt.Errorf("reading session %d's folder: %w", res.SessionID, err)
		}
		out.FolderID, out.Folder = f.ID, f.Name
	}
	if sessionFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "session: %d\nstate: %s\nfolder: %s\n", out.SessionID, out.State, out.FolderPath)
	return nil
}

// sessionStartRefused answers a start's error: a folder or parent refusal
// ("<code>: <sentence>", spec D42) with --json as an ok:false result with
// its code, exit 1 either way; any other error as is.
func sessionStartRefused(cmd *cobra.Command, err error) error {
	var r *workbenchfolders.Refusal
	if !errors.As(err, &r) {
		return err
	}
	if sessionFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), sessionStartRefusal{ErrorCode: r.Code, Error: r.Error()}); werr != nil {
			return werr
		}
	}
	return &exitCodeError{code: 1, err: r}
}

// runWorkbenchSessionFinish is the detached rest of a start: placement and
// launch of the row (sessionstart.Finish), the result written on the row.
func runWorkbenchSessionFinish(cmd *cobra.Command, _ []string) error {
	if sessionFlagSession <= 0 {
		return usageError("--session: a positive terminal session id is required")
	}
	brief, err := readBrief(cmd)
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	var wb sql.NullInt64
	if err := database.QueryRow(`SELECT project_id FROM terminal_sessions WHERE id = ?`, sessionFlagSession).Scan(&wb); err != nil {
		return fmt.Errorf("reading terminal session %d: %w", sessionFlagSession, err)
	}
	if err := checkSessionCaller(database, wb.Int64); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(cmdContext(cmd), finishBudget)
	defer cancel()
	d := sessionStartDeps(cfg, database)
	// An agent that exits 127 right after the launch records
	// "<agent> was not found" on the row for the Desktop.
	d.LaunchWatch = finishLaunchWatch
	return sessionstart.Finish(ctx, d, sessionFlagSession, sessionFlagPlace, brief, false)
}

func runWorkbenchSessionStop(cmd *cobra.Command, _ []string) error {
	if sessionFlagSession <= 0 {
		return usageError("--session: a positive terminal session id is required")
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	var wb sql.NullInt64
	err = database.QueryRow(`SELECT project_id FROM terminal_sessions WHERE id = ?`, sessionFlagSession).Scan(&wb)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("terminal session %d: %w", sessionFlagSession, db.ErrTerminalSessionNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading terminal session %d: %w", sessionFlagSession, err)
	}
	if err := checkSessionCaller(database, wb.Int64); err != nil {
		return err
	}
	if err := sessionstart.Stop(cmdContext(cmd), sessionStartDeps(cfg, database), sessionFlagSession); err != nil {
		return err
	}
	out := sessionStopOutput{SessionID: sessionFlagSession, Stopped: true}
	if sessionFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "session %d stopped\n", out.SessionID)
	return nil
}

// checkSessionCaller confines a caller under an agent marker to its own
// workbench, as `workbench cleanup` confines one to its session: inside a
// terminal session ($WATCHTOWER_TERMINAL_SESSION_ID) only that session's
// workbench may be started in or stopped; under any other agent marker
// (no session of its own to scope by) it is refused. The Desktop runs the
// command without them.
func checkSessionCaller(database *db.DB, workbench int64) error {
	caller, err := envTerminalSession(os.LookupEnv)
	if err != nil {
		return err
	}
	if caller == 0 {
		for _, name := range agentEnvMarkers {
			if os.Getenv(name) != "" {
				return usageError("refusing to start or stop a session under an AI agent (%s is set) outside a workbench session", name)
			}
		}
		return nil
	}
	var own sql.NullInt64
	err = database.QueryRow(`SELECT project_id FROM terminal_sessions WHERE id = ?`, caller).Scan(&own)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("reading terminal session %d: %w", caller, err)
	}
	if !own.Valid || own.Int64 != workbench {
		return usageError("inside terminal session %d only its own workbench's sessions can be started or stopped", caller)
	}
	return nil
}

// sessionStartDeps is what a session start runs against in this process —
// the CLI's and the Go hub's: the database and its file (the host scope),
// the host socket (WATCHTOWER_SESSION_HOST_SOCKET or the shared one), this
// binary for starting a host, and the seams only cmd has: codex's
// launch-args, the worktree integration, the default agent.
func sessionStartDeps(cfg *config.Config, database *db.DB) sessionstart.Deps {
	d := sessionstart.Deps{DB: database, DBPath: cfg.DBPath(), Shell: workbenchSessionShell}
	if bin, err := workbenchExecutable(); err == nil {
		d.CLIPath = bin
	}
	d.DefaultAgent = func() agentkind.Kind { return agentkind.Kind(cfg.Workbench.DefaultAgent) }
	d.CodexArgs = func(_ context.Context, workbenchID int64) (devpack.LaunchArgs, error) {
		bin, err := workbenchExecutable()
		if err != nil {
			return devpack.LaunchArgs{}, fmt.Errorf("determining the watchtower binary path: %w", err)
		}
		return devpack.CodexLaunchArgs(cfg, bin, workbenchID, codexFindBinary) //nolint:wrapcheck // devpack's own errors (ErrCodexNotFound) are matched
	}
	d.Integrate = installWorktreeIntegration
	return d
}
