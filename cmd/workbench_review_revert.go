package cmd

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

var (
	workbenchReviewRevertHunkCmd = &cobra.Command{Use: "revert-hunk",
		Short: "Undo one hunk of the round in the work tree (the owner's Desktop button)", RunE: runWorkbenchReviewRevertHunk}

	reviewFlagHunk string
)

func init() {
	c := workbenchReviewRevertHunkCmd
	c.Flags().Int64Var(&reviewFlagWorkbench, workbenchFlag, 0, "workbench id")
	c.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
	c.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	c.Flags().StringVar(&reviewFlagHunk, "hunk", "", "hunk id from the round's diff")
	c.Flags().BoolVar(&reviewFlagSince, "since", false, "the hunk is from the diff since the previous round")
	workbenchReviewCmd.AddCommand(c)
}

// runWorkbenchReviewRevertHunk is the reviewer's Undo (REVIEW-01, REVIEW-02):
// refused under an agent, on a round that is not open, while the session's
// agent is working, and for a hunk already undone; RevertHunk checks the file.
func runWorkbenchReviewRevertHunk(cmd *cobra.Command, _ []string) error {
	if err := requireOwnerConfirmation("undo a review hunk", ""); err != nil {
		return err
	}
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	if r.Status != "open" {
		return failReview(cmd, errors.New("the round is not open"))
	}
	if r.SessionID.Valid {
		working, err := database.TerminalAgentWorking(r.SessionID.Int64)
		if err != nil {
			return failReview(cmd, err)
		}
		if working {
			return failReview(cmd, errors.New("the agent is working in this session — undo when it stops"))
		}
	}
	done, err := database.ReviewReverts(r.ID)
	if err != nil {
		return failReview(cmd, err)
	}
	for _, d := range done {
		if d.HunkID == reviewFlagHunk {
			return failReview(cmd, errors.New("this hunk was already undone in this round"))
		}
	}
	from, _, err := roundRange(ctx, repo, database, r)
	if err != nil {
		return failReview(cmd, err)
	}
	d, err := repo.Diff(ctx, from, r.TreeSHA)
	if err != nil {
		return failReview(cmd, err)
	}
	rev, err := repo.RevertHunk(ctx, d, reviewFlagHunk)
	if err != nil {
		return failReview(cmd, err)
	}
	if err := database.AddReviewRevert(db.ReviewRevert{RoundID: r.ID, HunkID: rev.HunkID, Path: rev.Path,
		Header: rev.Header, Patch: rev.Patch}); err != nil {
		return failReview(cmd, fmt.Errorf("undone, but not recorded: %w", err))
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Revert: &reviewRevertJSON{HunkID: rev.HunkID, Path: rev.Path}})
}
