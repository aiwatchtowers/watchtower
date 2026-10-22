package cmd

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
)

// resetJSON is `automations reset --json` (the Desktop decodes exactly these
// keys).
type resetJSON struct {
	AutomationID int64  `json:"automation_id"`
	Overridden   bool   `json:"overridden"`
	ApprovalHash string `json:"approval_hash"`
}

// builtinIDOfArg is the built-in arg names: a built-in's id ("morning-brief")
// or the automation id of its row; an owner automation is refused.
func builtinIDOfArg(database *db.DB, arg string) (string, error) {
	if _, ok := builtinLookup(arg); ok {
		return arg, nil
	}
	id, err := parseAutomationID("automation id", arg)
	if err != nil {
		return "", fmt.Errorf("%q is neither a built-in nor an automation id", arg)
	}
	a, err := database.GetAutomation(id)
	if err != nil {
		return "", err
	}
	if !a.IsBuiltin() {
		return "", fmt.Errorf("automation %d is not a built-in: only a built-in is reset", id)
	}
	return a.BuiltinID, nil
}

// runAutomationsReset puts a built-in back on its shipped text: the owner's
// copy is removed (a regular file only — anything else at its path is never
// read anyway and is left alone) and the row synced, which confirms the
// shipped text (AUTO-06 as amended). Owner-only, like delete: refused under
// an agent's markers and confirmed in the Desktop.
func runAutomationsReset(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent("reset a built-in automation"); err != nil {
		return err
	}
	if err := confirmWithOwner("reset a built-in automation", automationConfirmDetail(args[0])); err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := builtinIDOfArg(database, args[0])
	if err != nil {
		return err
	}
	path := builtin.OwnerCopyPath(cfg.WorkspaceDir(), id)
	if _, err := os.Lstat(filepath.Dir(path)); err == nil {
		if err := requireBuiltinCopyDir(filepath.Dir(path)); err != nil {
			return fmt.Errorf("not reset: %w", err)
		}
	}
	fi, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return fmt.Errorf("checking the edited copy %s: %w", path, err)
	case fi.Mode().IsRegular():
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("removing the edited copy %s: %w", path, err)
		}
	default:
		fmt.Fprintf(cmd.ErrOrStderr(), "%s is not a regular file; it was left in place (it is never read)\n", path)
	}
	a, err := builtin.SyncOne(cmd.Context(), database, cfg.WorkspaceDir(), cfg, id, time.Now())
	if err != nil {
		return err
	}
	out := resetJSON{AutomationID: a.ID, Overridden: a.Overridden, ApprovalHash: a.ApprovalHash}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	fmt.Fprintf(w, "%s (#%d) is back on its shipped text.\n", a.Name, a.ID)
	return nil
}
