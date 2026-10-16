package cmd

import (
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

// reviewAIBudget bounds one model call of the reviewer (the Desktop waits 330 s).
const reviewAIBudget = 5 * time.Minute

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
	database, r, repo, ctx, cancel, err := loadRound(cmd)
	if err != nil || r == nil {
		return err
	}
	defer cancel()
	p, err := workbenchWithFolder(database, reviewFlagWorkbench)
	if err != nil {
		return err
	}
	diff, err := repo.Diff(ctx, r.BaseSHA, r.TreeSHA)
	if err != nil {
		return failReview(cmd, err)
	}
	in := reviewai.Input{Diff: diff}
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

	cfg, err := loadReviewAIConfig()
	if err != nil {
		return failReview(cmd, fmt.Errorf("AI overview unavailable: %w", err))
	}
	pipe := reviewai.New(reviewAIGeneratorFactory(cfg))
	pipe.SetPromptStore(prompts.New(database, nil))
	aiCtx, aiCancel := workbenchGitContext(cmd, reviewAIBudget)
	defer aiCancel()
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
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Overview: js})
}
