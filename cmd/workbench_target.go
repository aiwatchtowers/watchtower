package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfolders"
)

// workbenchTargetTitleMax is the title cap, the same as create_targets'.
const workbenchTargetTitleMax = 200

var workbenchTargetCmd = &cobra.Command{
	Use:   "target",
	Short: "Write a workbench's board targets as the owner",
}

var workbenchTargetAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a target to a workbench's board, recorded as the owner's",
	Long: "Creates one target with the board defaults (status todo, priority medium unless\n" +
		"--priority sets one) through the same writer as the agent's create_targets; the\n" +
		"creation is recorded as the owner's in the status history. --parent must be a\n" +
		"target of the same workbench; its progress is recomputed. --folder names the\n" +
		"bench folder the work is in (its name or path); default the home folder.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchTargetAdd,
}

var (
	workbenchTargetFlagWorkbench int64
	workbenchTargetFlagTitle     string
	workbenchTargetFlagIntent    string
	workbenchTargetFlagPriority  string
	workbenchTargetFlagParent    int64
	workbenchTargetFlagFolder    string
	workbenchTargetFlagJSON      bool
)

func init() {
	f := workbenchTargetAddCmd.Flags()
	f.Int64Var(&workbenchTargetFlagWorkbench, workbenchFlag, 0, "workbench id (required)")
	f.StringVar(&workbenchTargetFlagTitle, "title", "", fmt.Sprintf("the target title (required, at most %d characters)", workbenchTargetTitleMax))
	f.StringVar(&workbenchTargetFlagIntent, "intent", "", "why the target matters")
	f.StringVar(&workbenchTargetFlagPriority, "priority", "", "high | medium | low (default medium)")
	f.Int64Var(&workbenchTargetFlagParent, "parent", 0, "put the target under this target of the same workbench")
	f.StringVar(&workbenchTargetFlagFolder, "folder", "", "the bench folder the work is in: its name or path (default the home folder)")
	f.BoolVar(&workbenchTargetFlagJSON, "json", false, `output JSON: {"target_id":N}`)
	workbenchTargetCmd.AddCommand(workbenchTargetAddCmd)
	workbenchCmd.AddCommand(workbenchTargetCmd)
}

func runWorkbenchTargetAdd(cmd *cobra.Command, _ []string) error {
	if workbenchTargetFlagWorkbench <= 0 {
		return fmt.Errorf("--%s: a positive workbench id is required", workbenchFlag)
	}
	title := strings.TrimSpace(workbenchTargetFlagTitle)
	switch n := len([]rune(title)); {
	case n == 0:
		return errors.New("--title is required")
	case n > workbenchTargetTitleMax:
		return fmt.Errorf("--title must be at most %d characters (got %d)", workbenchTargetTitleMax, n)
	}
	in := db.WorkbenchTargetInput{Title: title, Intent: workbenchTargetFlagIntent, Priority: workbenchTargetFlagPriority}
	if cmd.Flags().Changed("parent") {
		in.ParentID = sql.NullInt64{Int64: workbenchTargetFlagParent, Valid: true}
	}

	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		return err
	}
	if ref := strings.TrimSpace(workbenchTargetFlagFolder); ref != "" {
		f, err := workbenchfolders.Resolve(context.Background(), database, workbenchTargetFlagWorkbench, ref)
		if err != nil {
			return fmt.Errorf("--folder: %w", err)
		}
		in.FolderID = sql.NullInt64{Int64: f.ID, Valid: true}
	}
	var ids []int64
	if err := database.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = database.CreateWorkbenchTargetsTx(tx, workbenchTargetFlagWorkbench, db.ActorOwner, []db.WorkbenchTargetInput{in})
		return err
	}); err != nil {
		return fmt.Errorf("workbench %d: %w", workbenchTargetFlagWorkbench, err)
	}
	if workbenchTargetFlagJSON {
		return writeJSON(cmd.OutOrStdout(), struct {
			TargetID int64 `json:"target_id"`
		}{ids[0]})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created target #%d on workbench %d\n", ids[0], workbenchTargetFlagWorkbench)
	return nil
}
