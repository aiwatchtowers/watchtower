package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/providers"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
)

// reviewAIBudget bounds a whole overview or lessons command — git, the model
// call and the db writes — below the Desktop's 330 s wait.
const reviewAIBudget = 5 * time.Minute

// reviewAIContext is the command's context for a model call: a cancelled
// parent or a SIGINT/SIGTERM (the Desktop's cancel) cancels it, so the CLI
// generator kills its model child instead of leaving it running.
func reviewAIContext(cmd *cobra.Command) (context.Context, context.CancelFunc) {
	parent := cmd.Context()
	if parent == nil {
		parent = context.Background()
	}
	sigCtx, stop := notifyShutdownContext(parent, stderrLogf)
	ctx, cancel := context.WithTimeout(sigCtx, reviewAIBudget)
	return ctx, func() {
		cancel()
		stop()
	}
}

// reviewAIGeneratorFactory builds the generator of the overview and lessons
// calls; tests swap it.
var reviewAIGeneratorFactory = func(cfg *config.Config) digest.Generator { return cliBoundedGenerator(cfg) }

var workbenchReviewOverviewCmd = &cobra.Command{Use: "overview", Short: "AI overview of a round: intent coverage, risk, chapters", RunE: runWorkbenchReviewOverview}

func init() {
	addWorkbenchIDFlag(workbenchReviewOverviewCmd, &reviewFlagWorkbench, "workbench id")
	workbenchReviewOverviewCmd.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
	workbenchReviewOverviewCmd.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	workbenchReviewCmd.AddCommand(workbenchReviewOverviewCmd)
}

// loadReviewAIConfig loads the config the way the other model commands do.
func loadReviewAIConfig() (*config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	return cfg, nil
}

func runWorkbenchReviewOverview(cmd *cobra.Command, _ []string) error {
	aiCtx, aiCancel := reviewAIContext(cmd)
	defer aiCancel()
	database, r, repo, ctx, cancel, err := loadRoundIn(cmd, aiCtx)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	p, err := workbenchWithFolder(database, reviewFlagWorkbench)
	if err != nil {
		return err
	}
	var in reviewai.Input
	if r.SessionID.Valid {
		items, err := reviewContextItems(ctx, database, p, r.SessionID.Int64)
		if err != nil {
			return failReview(cmd, err)
		}
		for _, it := range items {
			in.Intent = append(in.Intent, reviewai.IntentItem{Text: it.Text, Intent: it.Intent, Task: it.PlanText})
		}
		if in.Notes, err = database.ReviewNotes(p.ID, r.SessionID.Int64); err != nil {
			return failReview(cmd, err)
		}
	}
	lenses, _ := reviewdiff.LoadLenses(p.FolderPath)
	for _, l := range lenses {
		in.LensIDs = append(in.LensIDs, l.ID)
	}
	hash := reviewai.IntentHash(in.Intent, in.Notes)
	if js, ok, err := database.ReviewOverviewJSON(p.ID, r.TreeSHA, r.BaseSHA, hash); err != nil {
		return failReview(cmd, err)
	} else if ok {
		return writeReview(cmd, reviewEnvelope{OK: true, Overview: json.RawMessage(js), OverviewCached: true})
	}
	if in.Diff, err = repo.Diff(ctx, r.BaseSHA, r.TreeSHA); err != nil {
		return failReview(cmd, err)
	}

	cfg, err := loadReviewAIConfig()
	if err != nil {
		return failReview(cmd, fmt.Errorf("AI overview unavailable: %w", err))
	}
	pipe := reviewai.New(reviewAIGeneratorFactory(cfg))
	pipe.SetPromptStore(prompts.New(database, nil))
	ov, err := pipe.Overview(aiCtx, in)
	if err != nil {
		return failReview(cmd, fmt.Errorf("AI overview unavailable: %w", err))
	}
	js, err := json.Marshal(ov)
	if err != nil {
		return failReview(cmd, err)
	}
	_, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	if err := database.PutReviewOverview(p.ID, r.TreeSHA, r.BaseSHA, hash, string(js), strong); err != nil {
		// The overview is paid for: answer it; the next open just asks again.
		fmt.Fprintf(cmd.ErrOrStderr(), "review overview: caching failed: %v\n", err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Overview: js})
}
