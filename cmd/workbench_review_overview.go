package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/providers"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/tools"
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

var workbenchReviewOverviewCmd = &cobra.Command{Use: "overview", Short: "AI overview of a round or a session: intent coverage, risk, chapters", RunE: runWorkbenchReviewOverview}

// reviewFlagCachedOnly answers only a cached overview and never calls the
// model: a miss is `ok` with no overview (Quick mode asks this way, board #585).
var reviewFlagCachedOnly bool

func init() {
	workbenchReviewOverviewCmd.Flags().BoolVar(&reviewFlagCachedOnly, "cached-only", false, "answer only a cached overview; never call the model")
	workbenchReviewOverviewCmd.Flags().Int64Var(&reviewFlagWorkbench, workbenchFlag, 0, "workbench id")
	workbenchReviewOverviewCmd.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
	workbenchReviewOverviewCmd.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	workbenchReviewOverviewCmd.Flags().Int64Var(&reviewFlagSession, "session", 0, "terminal session id: the session's folder as it stands, no round")
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
	if reviewFlagSession != 0 {
		if reviewFlagRound != 0 {
			return fmt.Errorf("--round and --session are exclusive")
		}
		return runSessionReviewOverview(cmd)
	}
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
	if r.SessionID.Valid { // a round without a session has no intent
		if in, err = tools.ReviewOverviewInput(ctx, database, p, r.SessionID.Int64); err != nil {
			return failReview(cmd, err)
		}
	}
	return answerReviewOverview(aiCtx, ctx, cmd, database, p, repo, r.TreeSHA, r.BaseSHA, in)
}

// runSessionReviewOverview is the agent's form (spec
// 2026-10-24-finish-whole-ticket, gate 2): the overview of the session's
// folder as it stands, with no round opened. It is cached under the key the
// Desktop's round on the same tree reads, and the one finish_session checks;
// an empty diff answers ok with no overview.
func runSessionReviewOverview(cmd *cobra.Command) error {
	aiCtx, aiCancel := reviewAIContext(cmd)
	defer aiCancel()
	database, p, err := reviewTarget()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(aiCtx, workbenchReviewBudget)
	defer cancel()
	snap, err := tools.SnapshotReviewSession(ctx, database, p, reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	if snap.Empty {
		return writeReview(cmd, reviewEnvelope{OK: true})
	}
	in, err := tools.ReviewOverviewInput(ctx, database, p, reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	return answerReviewOverview(aiCtx, ctx, cmd, database, p, snap.Repo, snap.Tree, snap.Base, in)
}

// answerReviewOverview answers the cached overview of (tree, base, intent),
// or — unless --cached-only — makes the model call and caches it.
func answerReviewOverview(aiCtx, ctx context.Context, cmd *cobra.Command, database *db.DB, p *db.Workbench, repo *reviewdiff.Repo,
	tree, base string, in reviewai.Input) error {
	lenses, _ := reviewdiff.LoadLenses(p.FolderPath)
	for _, l := range lenses {
		in.LensIDs = append(in.LensIDs, l.ID)
	}
	hash := reviewai.IntentHash(in.Intent, in.Notes)
	if js, ok, err := database.ReviewOverviewJSON(p.ID, tree, base, hash); err != nil {
		return failReview(cmd, err)
	} else if ok {
		return writeReview(cmd, reviewEnvelope{OK: true, Overview: json.RawMessage(js), OverviewCached: true})
	} else if reviewFlagCachedOnly {
		return writeReview(cmd, reviewEnvelope{OK: true})
	}
	var err error
	if in.Diff, err = repo.Diff(ctx, base, tree); err != nil {
		return failReview(cmd, err)
	}
	return generateReviewOverview(aiCtx, cmd, database, p, tree, base, in, hash)
}

// generateReviewOverview makes the model call, caches the reply under hash
// and answers it.
func generateReviewOverview(aiCtx context.Context, cmd *cobra.Command, database *db.DB, p *db.Workbench, tree, base string, in reviewai.Input, hash string) error {
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
	if err := database.PutReviewOverview(p.ID, tree, base, hash, string(js), strong); err != nil {
		// The overview is paid for: answer it; the next open just asks again.
		fmt.Fprintf(cmd.ErrOrStderr(), "review overview: caching failed: %v\n", err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Overview: js})
}
