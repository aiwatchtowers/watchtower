package cmd

import (
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfolders"
)

// `workbench folder quiet|decline` (spec 2026-11-18 §6.7, §7 Writers): the
// Desktop's answers to a folder suggestion that are writes — Not Now quiets
// the outside-bench hook for that root in the session, Never for This
// Folder declines the folder for the bench. Like the membership verbs, an
// agent never runs them (checkFolderWriter). Each prints {ok, error_code?,
// error?} with --json; a refusal is ok:false, exit 0.
var workbenchFolderQuietCmd = &cobra.Command{
	Use:   "quiet",
	Short: "Not Now on a folder suggestion: the session is not reminded of that repository again",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchFolderQuiet,
}

var workbenchFolderDeclineCmd = &cobra.Command{
	Use:   "decline",
	Short: "Never for This Folder: the workbench's agents never suggest that folder again",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchFolderDecline,
}

var (
	folderFlagSession int64
	folderFlagRoot    string
)

func init() {
	workbenchFolderQuietCmd.Flags().Int64Var(&folderFlagSession, "session", 0, "the terminal session id (required)")
	workbenchFolderQuietCmd.Flags().StringVar(&folderFlagRoot, "root", "", "the repository root the suggestion named (required)")
	workbenchFolderDeclineCmd.Flags().Int64Var(&folderFlagWorkbench, workbenchFlag, 0, "workbench id (required)")
	workbenchFolderDeclineCmd.Flags().StringVar(&folderFlagFolder, "folder", "", "the folder's path (required)")
	for _, c := range []*cobra.Command{workbenchFolderQuietCmd, workbenchFolderDeclineCmd} {
		c.Flags().BoolVar(&folderFlagJSON, "json", false, "output JSON")
	}
	workbenchFolderCmd.AddCommand(workbenchFolderQuietCmd, workbenchFolderDeclineCmd)
}

// answerPath is an absolute path argument cleaned, symlinks resolved when it
// still resolves (the hook and the tool store resolved paths); "" when it is
// empty or relative.
func answerPath(p string) string {
	p = strings.TrimSpace(p)
	if !filepath.IsAbs(p) {
		return ""
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

func runWorkbenchFolderQuiet(cmd *cobra.Command, _ []string) error {
	if err := checkFolderWriter(); err != nil {
		return err
	}
	root := answerPath(folderFlagRoot)
	if folderFlagSession <= 0 || root == "" {
		return folderFailed(cmd, folderCodeBadArgs, errors.New("--session takes a positive session id and --root an absolute path"))
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	ctx := cmdContext(cmd)
	var one int
	// A session being deleted is gone for the owner already: not_found.
	err = database.QueryRowContext(ctx, `SELECT 1 FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL,
		folderFlagSession).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return folderRefused(cmd, database, &workbenchfolders.Refusal{Code: workbenchfolders.CodeNotFound,
			Detail: fmt.Sprintf("there is no terminal session %d.", folderFlagSession)})
	}
	if err != nil {
		return fmt.Errorf("reading terminal session %d: %w", folderFlagSession, err)
	}
	if err := database.QuietOutsideRoot(ctx, folderFlagSession, root); err != nil {
		return err //nolint:wrapcheck // db's message names the session and root
	}
	return folderAnswered(cmd, fmt.Sprintf("Session %d is not reminded of %s again.", folderFlagSession, root))
}

func runWorkbenchFolderDecline(cmd *cobra.Command, _ []string) error {
	if err := checkFolderWriter(); err != nil {
		return err
	}
	folder := answerPath(folderFlagFolder)
	if folder == "" {
		return folderFailed(cmd, folderCodeBadArgs, errors.New("--folder takes an absolute path"))
	}
	fc, err := openFolderCmd(cmdContext(cmd), false)
	if err != nil {
		return err
	}
	defer fc.done()
	if err := fc.database.DeclineFolder(cmdContext(cmd), fc.p.ID, folder); err != nil {
		return err //nolint:wrapcheck // db's message names the workbench and folder
	}
	return folderAnswered(cmd, fmt.Sprintf("Workbench %d's agents never suggest %s again.", fc.p.ID, folder))
}

// folderAnswered prints a quiet or decline's success: {"ok":true} with
// --json, else text.
func folderAnswered(cmd *cobra.Command, text string) error {
	if folderFlagJSON {
		return writeJSON(cmd.OutOrStdout(), folderResultJSON{OK: true})
	}
	fmt.Fprintln(cmd.OutOrStdout(), text)
	return nil
}
