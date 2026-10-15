package cmd

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/workbenchgit"
)

const workbenchReviewBudget = 30 * time.Second

var (
	workbenchReviewCmd = &cobra.Command{Use: "review", Short: "Diff reviewer rounds of a workbench session (JSON for the Desktop)"}

	workbenchReviewStartCmd   = &cobra.Command{Use: "start", Short: "Open or resume the session's review round", RunE: runWorkbenchReviewStart}
	workbenchReviewDiffCmd    = &cobra.Command{Use: "diff", Short: "The round's diff", RunE: runWorkbenchReviewDiff}
	workbenchReviewFileCmd    = &cobra.Command{Use: "file", Short: "Both sides of one file of the round", RunE: runWorkbenchReviewFile}
	workbenchReviewSendCmd    = &cobra.Command{Use: "send", Short: "Close the round and print its delivery line", RunE: runWorkbenchReviewSend}
	workbenchReviewContextCmd = &cobra.Command{Use: "context", Short: "The session's intent card", RunE: runWorkbenchReviewContext}

	reviewFlagWorkbench int64
	reviewFlagJSON      bool
	reviewFlagSession   int64
	reviewFlagRound     int64
	reviewFlagPath      string
	reviewFlagSince     bool
	reviewFlagRefresh   bool
)

func init() {
	for _, c := range []*cobra.Command{workbenchReviewStartCmd, workbenchReviewDiffCmd, workbenchReviewFileCmd,
		workbenchReviewSendCmd, workbenchReviewContextCmd} {
		addWorkbenchIDFlag(c, &reviewFlagWorkbench, "workbench id")
		c.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
		workbenchReviewCmd.AddCommand(c)
	}
	for _, c := range []*cobra.Command{workbenchReviewStartCmd, workbenchReviewContextCmd} {
		c.Flags().Int64Var(&reviewFlagSession, "session", 0, "terminal session id")
	}
	for _, c := range []*cobra.Command{workbenchReviewDiffCmd, workbenchReviewFileCmd, workbenchReviewSendCmd} {
		c.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	}
	workbenchReviewDiffCmd.Flags().BoolVar(&reviewFlagSince, "since", false, "diff since the previous round")
	workbenchReviewFileCmd.Flags().BoolVar(&reviewFlagSince, "since", false, "old side = the previous round")
	workbenchReviewFileCmd.Flags().StringVar(&reviewFlagPath, "path", "", "file path in the round")
	workbenchReviewStartCmd.Flags().BoolVar(&reviewFlagRefresh, "refresh", false, "re-snapshot an open round")
	workbenchCmd.AddCommand(workbenchReviewCmd)
}

type reviewRoundJSON struct {
	ID           int64  `json:"id"`
	Status       string `json:"status"`
	Mode         string `json:"mode"`
	FolderRoot   string `json:"folder_root"`
	BaseSHA      string `json:"base_sha"`
	BaseLabel    string `json:"base_label"`
	TreeSHA      string `json:"tree_sha"`
	PrevRoundID  int64  `json:"prev_round_id"`
	PrevTreeSHA  string `json:"prev_tree_sha"`
	PrevTreeLost bool   `json:"prev_tree_lost"`
}

type reviewEnvelope struct {
	OK               bool                `json:"ok"`
	Error            string              `json:"error,omitempty"`
	Round            *reviewRoundJSON    `json:"round,omitempty"`
	Diff             *reviewdiff.Diff    `json:"diff,omitempty"`
	From             string              `json:"from,omitempty"`
	To               string              `json:"to,omitempty"`
	PreviousTreeLost bool                `json:"previous_tree_lost,omitempty"`
	Old              *reviewdiff.Side    `json:"old,omitempty"`
	New              *reviewdiff.Side    `json:"new,omitempty"`
	Sent             *bool               `json:"sent,omitempty"`
	Comments         int                 `json:"comments,omitempty"`
	Line             string              `json:"line,omitempty"`
	Items            []reviewContextItem `json:"items,omitempty"`
}

// reviewTarget resolves --workbench to its row and an open DB; a bad id or a
// missing workbench is a command error (non-zero exit).
func reviewTarget(cmd *cobra.Command) (*db.DB, *db.Workbench, error) {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return nil, nil, err
	}
	if reviewFlagWorkbench <= 0 {
		return nil, nil, fmt.Errorf("--workbench is required")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return nil, nil, err
	}
	p, err := workbenchWithFolder(database, reviewFlagWorkbench)
	if err != nil {
		return nil, nil, err
	}
	return database, p, nil
}

func writeReview(cmd *cobra.Command, env reviewEnvelope) error {
	if reviewFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	if !env.OK {
		fmt.Fprintln(cmd.OutOrStdout(), "error:", env.Error)
		return nil
	}
	fmt.Fprintf(cmd.OutOrStdout(), "ok\n")
	return nil
}

func failReview(cmd *cobra.Command, err error) error {
	return writeReview(cmd, reviewEnvelope{Error: err.Error()})
}

func roundJSON(ctx context.Context, repo *reviewdiff.Repo, database *db.DB, r *db.ReviewRound) *reviewRoundJSON {
	out := &reviewRoundJSON{ID: r.ID, Status: r.Status, Mode: r.Mode, FolderRoot: r.FolderRoot, BaseSHA: r.BaseSHA,
		BaseLabel: r.BaseLabel, TreeSHA: r.TreeSHA}
	if r.PrevRoundID.Valid {
		out.PrevRoundID = r.PrevRoundID.Int64
		if prev, err := database.GetReviewRound(r.ProjectID, r.PrevRoundID.Int64); err == nil {
			out.PrevTreeSHA = prev.TreeSHA
			out.PrevTreeLost = !repo.TreeExists(ctx, prev.TreeSHA)
		}
	}
	return out
}

// sessionFolder: the root of the folder the session's agent works in.
func sessionFolder(ctx context.Context, database *db.DB, p *db.Workbench, sessionID int64) (string, error) {
	row, err := database.GetTerminalSession(sessionID)
	if err != nil {
		return "", err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != p.ID {
		return "", fmt.Errorf("session %d is not on workbench %d", sessionID, p.ID)
	}
	cwd, err := database.TerminalAgentCwd(sessionID)
	if err != nil {
		return "", err
	}
	folder, err := workbenchgit.ResolveFolder(ctx, workbenchgit.Options{Folder: p.FolderPath}, cwd.Path)
	if err != nil {
		return "", err
	}
	if folder.Root == "" {
		return p.FolderPath, nil
	}
	return folder.Root, nil
}

func runWorkbenchReviewStart(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchReviewBudget)
	defer cancel()
	open, err := database.OpenReviewRound(p.ID, reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	folder := ""
	if open != nil {
		folder = open.FolderRoot
	} else if folder, err = sessionFolder(ctx, database, p, reviewFlagSession); err != nil {
		return failReview(cmd, err)
	}
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return failReview(cmd, err)
	}
	if open != nil && !reviewFlagRefresh {
		return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, open)})
	}
	tree, err := repo.Snapshot(ctx)
	if err != nil {
		return failReview(cmd, err)
	}
	if open != nil {
		if err := database.UpdateReviewRoundTree(open.ID, tree); err != nil {
			return failReview(cmd, err)
		}
		open.TreeSHA = tree
		return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, open)})
	}
	base, err := repo.Base(ctx)
	if err != nil {
		return failReview(cmd, err)
	}
	r := db.ReviewRound{ProjectID: p.ID, SessionID: sql.NullInt64{Int64: reviewFlagSession, Valid: true},
		FolderRoot: folder, BaseSHA: base.SHA, BaseLabel: base.Label, TreeSHA: tree}
	if last, err := database.LastSentReviewRound(p.ID, reviewFlagSession); err == nil && last != nil {
		r.PrevRoundID = sql.NullInt64{Int64: last.ID, Valid: true}
	}
	id, err := database.CreateReviewRound(r)
	if err != nil {
		return failReview(cmd, err)
	}
	created, err := database.GetReviewRound(p.ID, id)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Round: roundJSON(ctx, repo, database, created)})
}

// roundRange: from/to of the round's diff; since → the previous round's tree
// when it still exists, else the base with lost=true.
func roundRange(ctx context.Context, repo *reviewdiff.Repo, database *db.DB, r *db.ReviewRound) (from string, lost bool) {
	if !reviewFlagSince || !r.PrevRoundID.Valid {
		return r.BaseSHA, false
	}
	prev, err := database.GetReviewRound(r.ProjectID, r.PrevRoundID.Int64)
	if err != nil || !repo.TreeExists(ctx, prev.TreeSHA) {
		return r.BaseSHA, true
	}
	return prev.TreeSHA, false
}

func loadRound(cmd *cobra.Command) (*db.DB, *db.ReviewRound, *reviewdiff.Repo, context.Context, context.CancelFunc, error) {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchReviewBudget)
	r, err := database.GetReviewRound(p.ID, reviewFlagRound)
	if err != nil {
		cancel()
		return nil, nil, nil, nil, nil, failReview(cmd, fmt.Errorf("review round %d is not on this workbench", reviewFlagRound))
	}
	repo, err := reviewdiff.Open(r.FolderRoot, nil)
	if err != nil {
		cancel()
		return nil, nil, nil, nil, nil, failReview(cmd, err)
	}
	return database, r, repo, ctx, cancel, nil
}

func runWorkbenchReviewDiff(cmd *cobra.Command, _ []string) error {
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	from, lost := roundRange(ctx, repo, database, r)
	d, err := repo.Diff(ctx, from, r.TreeSHA)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Diff: &d, From: from, To: r.TreeSHA, PreviousTreeLost: lost})
}

func runWorkbenchReviewFile(cmd *cobra.Command, _ []string) error {
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	from, _ := roundRange(ctx, repo, database, r)
	oldSide, err := repo.File(ctx, from, reviewFlagPath)
	if err != nil {
		return failReview(cmd, err)
	}
	newSide, err := repo.File(ctx, r.TreeSHA, reviewFlagPath)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Old: &oldSide, New: &newSide})
}

func runWorkbenchReviewSend(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	n, ok, err := database.SendReviewRound(p.ID, reviewFlagRound)
	if err != nil {
		return failReview(cmd, err)
	}
	env := reviewEnvelope{OK: true, Sent: &ok, Comments: n}
	if ok {
		env.Line = reviewdiff.DeliveryLine(reviewFlagRound, n)
	}
	return writeReview(cmd, env)
}
