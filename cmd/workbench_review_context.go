package cmd

import (
	"github.com/spf13/cobra"

	"watchtower/internal/reviewdiff"
	"watchtower/internal/tools"
)

func runWorkbenchReviewContext(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget()
	if err != nil {
		return err
	}
	if err := tools.CheckSessionOnWorkbench(database, p, reviewFlagSession); err != nil {
		return failReview(cmd, err)
	}
	items, err := tools.ReviewContextItems(cmd.Context(), database, p, reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	lenses, notes := reviewdiff.LoadLenses(p.FolderPath)
	return writeReview(cmd, reviewEnvelope{OK: true, Items: items, Lenses: lenses, LensNotes: notes})
}
