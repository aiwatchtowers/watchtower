package cmd

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

var workbenchSessionTargetCmd = &cobra.Command{
	Use:   "session-target",
	Short: "Bind a workbench terminal session to a target (or clear the binding)",
	Long: "--session S --target T binds agent session S to target T (a group or a task of S's\n" +
		"workbench): the session's progress line counts that target's leaves and finish_session\n" +
		"gates on its subtree. --session S --clear removes the binding. Exactly one of --target\n" +
		"and --clear is required. The workbench is the one S belongs to. --json prints one line\n" +
		"{\"session_id\":N,\"target_id\":M,\"stamped\":K} (target_id 0 when cleared; K = the\n" +
		"leaves under the bound target the binding takes, 0 when cleared). A refusal\n" +
		"(unknown session, shell session, archived, dismissed or foreign target) exits non-zero\n" +
		"with the reason on stderr. The owner's verb: refused under an AI agent, which has the\n" +
		"set_session_target tool.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchSessionTarget,
}

var (
	workbenchSessionTargetFlagSession int64
	workbenchSessionTargetFlagTarget  int64
	workbenchSessionTargetFlagClear   bool
	workbenchSessionTargetFlagJSON    bool
)

func init() {
	c := workbenchSessionTargetCmd
	fs := c.Flags()
	fs.Int64Var(&workbenchSessionTargetFlagSession, "session", 0, "terminal session id")
	fs.Int64Var(&workbenchSessionTargetFlagTarget, "target", 0, "target id to bind the session to")
	fs.BoolVar(&workbenchSessionTargetFlagClear, "clear", false, "remove the session's target binding")
	fs.BoolVar(&workbenchSessionTargetFlagJSON, "json", false, "output JSON")
	_ = c.MarkFlagRequired("session")
	c.MarkFlagsOneRequired("target", "clear")
	c.MarkFlagsMutuallyExclusive("target", "clear")
	workbenchCmd.AddCommand(c)
}

func runWorkbenchSessionTarget(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("bind a session to a target"); err != nil {
		return err
	}
	sessionID := workbenchSessionTargetFlagSession
	targetID := workbenchSessionTargetFlagTarget
	if sessionID <= 0 {
		return fmt.Errorf("--session: a positive session id is required")
	}
	if targetID < 0 || (!workbenchSessionTargetFlagClear && targetID == 0) {
		return fmt.Errorf("--target: a positive target id is required (or --clear)")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	session, err := database.GetTerminalSession(sessionID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return fmt.Errorf("session %d not found", sessionID)
	}
	if err != nil {
		return err
	}
	if !session.WorkbenchID.Valid {
		return fmt.Errorf("session %d is not an agent session of a workbench", sessionID)
	}
	stamped, err := tools.BindSessionTarget(database, session.WorkbenchID.Int64, sessionID, targetID)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if workbenchSessionTargetFlagJSON {
		return json.NewEncoder(w).Encode(struct {
			SessionID int64 `json:"session_id"`
			TargetID  int64 `json:"target_id"`
			Stamped   int   `json:"stamped"`
		}{sessionID, targetID, stamped})
	}
	if targetID == 0 {
		_, err = fmt.Fprintf(w, "session %d: target cleared\n", sessionID)
	} else {
		_, err = fmt.Fprintf(w, "session %d bound to target %d (%d leaves)\n", sessionID, targetID, stamped)
	}
	return err
}
