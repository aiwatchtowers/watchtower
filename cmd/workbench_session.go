package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionstart"
)

var workbenchSessionCmd = &cobra.Command{
	Use:   "session",
	Short: "Start and stop workbench agent sessions in the session host",
	Long: "start does what the app's New Session does: the session row (Starting…), its place — the\n" +
		"workbench folder, or its own git worktree when a live agent already works there (or as --place\n" +
		"asks) —, the first prompt, the launch in the session host. stop is the host's Stop request (the\n" +
		"exit carries requested: no worktree cleanup). Inside an agent's terminal session only that\n" +
		"session's workbench may be started or stopped.",
}

var (
	sessionFlagWorkbench int64
	sessionFlagTarget    int64
	sessionFlagSession   int64
	sessionFlagAgent     string
	sessionFlagPlace     string
	sessionFlagJSON      bool
)

// workbenchSessionShell is the login shell a start launches in ("" =
// $SHELL); a test seam.
var workbenchSessionShell = ""

// startBudgetCLI bounds a CLI start: the worktree, its integration and the
// launch all run before the command answers.
const startBudgetCLI = 3 * time.Minute

func init() {
	start := &cobra.Command{Use: "start", Short: "Start an agent session", Args: cobra.NoArgs, RunE: runWorkbenchSessionStart}
	start.Flags().Int64Var(&sessionFlagWorkbench, workbenchFlag, 0, "workbench id")
	start.Flags().Int64Var(&sessionFlagTarget, "target", 0, "the target the session works on (optional)")
	start.Flags().StringVar(&sessionFlagAgent, "agent", "", "claude or codex (default: workbench.default_agent)")
	start.Flags().StringVar(&sessionFlagPlace, "place", "auto", "folder, worktree or auto")
	stop := &cobra.Command{Use: "stop", Short: "Stop a session (the host's Stop request)", Args: cobra.NoArgs, RunE: runWorkbenchSessionStop}
	stop.Flags().Int64Var(&sessionFlagSession, "session", 0, "terminal session id")
	for _, c := range []*cobra.Command{start, stop} {
		c.Flags().BoolVar(&sessionFlagJSON, "json", false, "output JSON")
		workbenchSessionCmd.AddCommand(c)
	}
	workbenchCmd.AddCommand(workbenchSessionCmd)
}

type sessionStartOutput struct {
	SessionID      int64  `json:"session_id"`
	State          string `json:"state"`
	FolderPath     string `json:"folder_path"`
	WorktreeBranch string `json:"worktree_branch"`
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
	ctx, cancel := context.WithTimeout(cmdContext(cmd), startBudgetCLI)
	defer cancel()
	r := handlers.StartRequest{Workbench: sessionFlagWorkbench, Agent: sessionFlagAgent, Place: sessionFlagPlace}
	if sessionFlagTarget > 0 {
		r.Target = &sessionFlagTarget
	}
	res, startErr := sessionstart.Start(ctx, sessionStartDeps(cfg, database), r)
	if res.SessionID == 0 {
		return startErr
	}
	out := sessionStartOutput{SessionID: res.SessionID, State: res.State}
	var branch sql.NullString
	if err := database.QueryRowContext(ctx, `SELECT folder_path, worktree_branch FROM terminal_sessions WHERE id = ?`,
		res.SessionID).Scan(&out.FolderPath, &branch); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return errors.Join(startErr, fmt.Errorf("reading session %d: %w", res.SessionID, err))
	}
	out.WorktreeBranch = branch.String
	if sessionFlagJSON {
		if err := writeJSON(cmd.OutOrStdout(), out); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(cmd.OutOrStdout(), "session: %d\nstate: %s\nfolder: %s\n", out.SessionID, out.State, out.FolderPath)
	}
	return startErr
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
