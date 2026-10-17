package cmd

import (
	"fmt"
	"path/filepath"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
)

// reviewLessonsRounds: how many of the newest sent rounds "Find repeats" reads.
const reviewLessonsRounds = 20

// reviewLessonsFile is where Accept writes, relative to the workbench folder.
var reviewLessonsFile = filepath.ToSlash(filepath.Join(".watchtower", "review.md"))

var (
	workbenchReviewLessonsCmd = &cobra.Command{Use: "lessons", Short: "Find repeats in review comments and accept them as house rules"}

	workbenchReviewLessonsProposeCmd = &cobra.Command{Use: "propose", Short: "Propose house rules from the owner's repeated comments", RunE: runWorkbenchReviewLessonsPropose}
	workbenchReviewLessonsAcceptCmd  = &cobra.Command{Use: "accept", Short: "Write a proposed rule into .watchtower/review.md", RunE: runWorkbenchReviewLessonsAccept}
	workbenchReviewLessonsDismissCmd = &cobra.Command{Use: "dismiss", Short: "Dismiss a proposed rule", RunE: runWorkbenchReviewLessonsDismiss}

	reviewFlagLesson int64
)

func init() {
	for _, c := range []*cobra.Command{workbenchReviewLessonsProposeCmd, workbenchReviewLessonsAcceptCmd, workbenchReviewLessonsDismissCmd} {
		c.Flags().Int64Var(&reviewFlagWorkbench, workbenchFlag, 0, "workbench id")
		c.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
		workbenchReviewLessonsCmd.AddCommand(c)
	}
	for _, c := range []*cobra.Command{workbenchReviewLessonsAcceptCmd, workbenchReviewLessonsDismissCmd} {
		c.Flags().Int64Var(&reviewFlagLesson, "lesson", 0, "lesson id")
	}
	workbenchReviewCmd.AddCommand(workbenchReviewLessonsCmd)
}

// ptrLessons: a pointer so an empty list is still emitted as "lessons": [].
func ptrLessons(ls []db.ReviewLesson) *[]reviewLessonJSON {
	out := lessonsJSON(ls)
	return &out
}

func lessonsJSON(ls []db.ReviewLesson) []reviewLessonJSON {
	out := make([]reviewLessonJSON, 0, len(ls))
	for _, l := range ls {
		out = append(out, reviewLessonJSON{ID: l.ID, Lens: l.Lens, Text: l.Text, SourceCommentIDs: l.SourceCommentIDs, Status: l.Status})
	}
	return out
}

func runWorkbenchReviewLessonsPropose(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("propose review lessons"); err != nil {
		return err
	}
	ctx, cancel := reviewAIContext(cmd)
	defer cancel()
	database, p, err := reviewTarget()
	if err != nil {
		return err
	}
	comments, err := database.ReviewLessonInputComments(p.ID, reviewLessonsRounds)
	if err != nil {
		return failReview(cmd, err)
	}
	if len(comments) < 2 {
		return writeReview(cmd, reviewEnvelope{OK: true, Lessons: ptrLessons(nil)})
	}
	lenses, _ := reviewdiff.LoadLenses(p.FolderPath)
	cfg, err := loadReviewAIConfig()
	if err != nil {
		return failReview(cmd, fmt.Errorf("find repeats unavailable: %w", err))
	}
	pipe := reviewai.New(reviewAIGeneratorFactory(cfg))
	pipe.SetPromptStore(prompts.New(database, nil))
	found, err := pipe.Lessons(ctx, comments, lenses)
	if err != nil {
		return failReview(cmd, fmt.Errorf("find repeats unavailable: %w", err))
	}
	rows := make([]db.ReviewLesson, 0, len(found))
	for _, l := range found {
		rows = append(rows, db.ReviewLesson{Lens: l.Lens, Text: l.Text, SourceCommentIDs: l.SourceCommentIDs})
	}
	saved, err := database.ReplaceProposedReviewLessons(p.ID, rows)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Lessons: ptrLessons(saved)})
}

func errLessonDecided(id int64) error { return fmt.Errorf("lesson %d was already decided", id) }

func runWorkbenchReviewLessonsAccept(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("accept a review lesson"); err != nil {
		return err
	}
	database, p, err := reviewTarget()
	if err != nil {
		return err
	}
	l, err := database.GetReviewLesson(p.ID, reviewFlagLesson)
	if err != nil {
		return failReview(cmd, err)
	}
	if l == nil {
		return failReview(cmd, fmt.Errorf("lesson %d is not on this workbench", reviewFlagLesson))
	}
	// Decide first: of two Accepts racing on one lesson only the one that
	// moved it writes the rule.
	ok, err := database.DecideReviewLesson(p.ID, l.ID, "accepted")
	if err != nil {
		return failReview(cmd, err)
	}
	if !ok {
		return failReview(cmd, errLessonDecided(l.ID))
	}
	lensName := "House rules"
	lenses, _ := reviewdiff.LoadLenses(p.FolderPath)
	for _, lens := range lenses {
		if lens.ID == l.Lens {
			lensName = lens.Name
			break
		}
	}
	if err := reviewdiff.AppendLessonRule(p.FolderPath, lensName, l.Text); err != nil {
		if rerr := database.ReopenReviewLesson(p.ID, l.ID); rerr != nil {
			return failReview(cmd, fmt.Errorf("%w (and the lesson stays accepted: %w)", err, rerr))
		}
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Written: reviewLessonsFile})
}

func runWorkbenchReviewLessonsDismiss(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("dismiss a review lesson"); err != nil {
		return err
	}
	database, p, err := reviewTarget()
	if err != nil {
		return err
	}
	ok, err := database.DecideReviewLesson(p.ID, reviewFlagLesson, "dismissed")
	if err != nil {
		return failReview(cmd, err)
	}
	if !ok {
		return failReview(cmd, errLessonDecided(reviewFlagLesson))
	}
	return writeReview(cmd, reviewEnvelope{OK: true})
}
