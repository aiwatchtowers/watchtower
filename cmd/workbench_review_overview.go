package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"sync"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/providers"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
	"watchtower/internal/tools"
)

// reviewAIBudget bounds a whole lessons command — git, the model call and
// the db writes — below the Desktop's 330 s wait. The overview has its own
// ceiling, reviewai.RunCeiling.
const reviewAIBudget = 5 * time.Minute

// reviewAIContext is the command's context for a model call: a cancelled
// parent or a SIGINT/SIGTERM (the Desktop's cancel) cancels it, so the CLI
// generator kills its model child instead of leaving it running.
func reviewAIContext(cmd *cobra.Command) (context.Context, context.CancelFunc) {
	sigCtx, stop := reviewSignalContext(cmd)
	ctx, cancel := context.WithTimeout(sigCtx, reviewAIBudget)
	return ctx, func() {
		cancel()
		stop()
	}
}

// reviewSignalContext is the command's context, cancelled by its parent or
// a SIGINT/SIGTERM.
func reviewSignalContext(cmd *cobra.Command) (context.Context, context.CancelFunc) {
	parent := cmd.Context()
	if parent == nil {
		parent = context.Background()
	}
	return notifyShutdownContext(parent, stderrLogf)
}

// reviewAIGeneratorFactory builds the generator of the overview and lessons
// calls; tests swap it.
var reviewAIGeneratorFactory = func(cfg *config.Config) digest.Generator { return cliBoundedGenerator(cfg) }

// reviewStreamTickEvery is the streamed form's heartbeat (tech spec §3.2):
// the Desktop fails a stream silent for 5 min, so a slow model call never
// trips it.
const reviewStreamTickEvery = 30 * time.Second

// reviewStreamTicker starts the heartbeat's ticker; tests swap it for a
// fake clock.
var reviewStreamTicker = func(every time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(every)
	return t.C, t.Stop
}

var workbenchReviewOverviewCmd = &cobra.Command{Use: "overview", Short: "AI overview of a round or a session: intent coverage, risk, chapters", RunE: runWorkbenchReviewOverview}

var (
	// reviewFlagCachedOnly answers only a cached overview and never calls
	// the model: a miss is `ok` with no overview (Quick mode asks this way,
	// board #585).
	reviewFlagCachedOnly bool
	// reviewFlagStream prints JSON lines: events, then the envelope (§3.5).
	reviewFlagStream bool
	// reviewFlagChapters redoes only these chapters, then the summary.
	reviewFlagChapters []string
	// reviewFlagSummary redoes only the summary from the cached parts.
	reviewFlagSummary bool
	// reviewFlagContinue describes only the chapters without a part row.
	reviewFlagContinue bool
	// reviewFlagCaller is who runs the overview: desktop, agent or cli; ""
	// is agent under an AI agent, else cli (the run lock records it, §3.7).
	reviewFlagCaller string
)

func init() {
	f := workbenchReviewOverviewCmd.Flags()
	f.BoolVar(&reviewFlagCachedOnly, "cached-only", false, "answer only a cached overview; never call the model")
	f.BoolVar(&reviewFlagStream, "stream", false, "print JSON lines (map, chapter and summary events, a tick every 30 s), then the envelope; needs --json")
	f.StringArrayVar(&reviewFlagChapters, "chapter", nil, "redo only this chapter (by its key; repeatable), then the summary")
	f.BoolVar(&reviewFlagSummary, "summary", false, "redo only the summary from the cached chapter descriptions")
	f.BoolVar(&reviewFlagContinue, "continue", false, "describe only the chapters without a description, then the summary")
	f.StringVar(&reviewFlagCaller, "caller", "", "who runs it: desktop, agent or cli (default: agent under an AI agent, else cli)")
	f.Int64Var(&reviewFlagWorkbench, workbenchFlag, 0, "workbench id")
	f.BoolVar(&reviewFlagJSON, "json", false, "output JSON")
	f.Int64Var(&reviewFlagRound, "round", 0, "review round id")
	f.Int64Var(&reviewFlagSession, "session", 0, "terminal session id: the session's folder as it stands, no round")
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

// checkOverviewFlags refuses flag combinations that mean nothing.
func checkOverviewFlags() error {
	switch {
	case reviewFlagSession != 0 && reviewFlagRound != 0:
		return errors.New("--round and --session are exclusive")
	case reviewFlagStream && !reviewFlagJSON:
		return errors.New("--stream needs --json")
	case !slices.Contains([]string{"", "desktop", "agent", "cli"}, reviewFlagCaller):
		return fmt.Errorf("--caller must be desktop, agent or cli, not %q", reviewFlagCaller)
	}
	modes := 0
	for _, on := range []bool{reviewFlagCachedOnly, len(reviewFlagChapters) > 0, reviewFlagSummary, reviewFlagContinue} {
		if on {
			modes++
		}
	}
	if modes > 1 {
		return errors.New("--cached-only, --chapter, --summary and --continue are exclusive")
	}
	return nil
}

// overviewJob is what one overview command works on: the place, its map
// and diff, and the intent (the session's items, then the lane items) and
// notes the overview is made for.
type overviewJob struct {
	database *db.DB
	p        *db.Workbench
	pl       reviewPlace
	m        reviewmap.Map
	diff     reviewdiff.Diff
	in       reviewai.Input
}

func runWorkbenchReviewOverview(cmd *cobra.Command, _ []string) error {
	if err := checkOverviewFlags(); err != nil {
		return err
	}
	ctx, stop := reviewSignalContext(cmd)
	defer stop()
	var emit func(reviewai.Event)
	if reviewFlagStream {
		s := startOverviewStream(cmd.OutOrStdout())
		activeOverviewStream = s
		defer func() {
			s.stop()
			activeOverviewStream = nil
		}()
		emit = s.emit
	}
	job, ok, err := loadOverviewJob(cmd, ctx)
	if err != nil || !ok {
		return err
	}
	if emit != nil {
		emit(reviewai.Event{Event: "map", Map: &job.m})
	}
	if len(job.diff.Files) == 0 { // nothing changed: nothing to describe
		return writeReview(cmd, reviewEnvelope{OK: true})
	}
	return answerReviewOverview(ctx, cmd, job, emit)
}

// loadOverviewJob reads the round's or the session's place, its map and the
// intent. ok false: a refusal was already answered.
func loadOverviewJob(cmd *cobra.Command, ctx context.Context) (overviewJob, bool, error) {
	var job overviewJob
	var gitCtx context.Context
	var session int64
	if reviewFlagSession != 0 {
		var err error
		if job.database, job.p, err = reviewTarget(); err != nil {
			return job, false, err
		}
		var cancel context.CancelFunc
		gitCtx, cancel = context.WithTimeout(ctx, workbenchReviewBudget)
		defer cancel()
		if job.pl, err = sessionReviewPlace(gitCtx, job.database, job.p, reviewFlagSession); err != nil {
			return job, false, failReview(cmd, err)
		}
		session = reviewFlagSession
	} else {
		database, r, repo, rCtx, cancel, err := loadRoundIn(cmd, ctx)
		if err != nil || r == nil {
			return job, false, err
		}
		defer cancel()
		gitCtx, job.database = rCtx, database
		if job.p, err = workbenchWithFolder(database, reviewFlagWorkbench); err != nil {
			return job, false, err
		}
		if job.pl, err = roundReviewPlace(gitCtx, repo, r); err != nil {
			return job, false, failReview(cmd, err)
		}
		if r.SessionID.Valid { // a round without a session has no session intent
			session = r.SessionID.Int64
		}
	}
	if err := job.load(gitCtx, session); err != nil {
		return job, false, failReview(cmd, err)
	}
	return job, true, nil
}

// load reads the session's intent and notes (session 0: none), builds the
// map and appends its lane items to the intent.
func (job *overviewJob) load(ctx context.Context, session int64) error {
	var err error
	if session != 0 {
		if job.in, err = tools.ReviewOverviewInput(ctx, job.database, job.p, session); err != nil {
			return err
		}
	}
	if job.m, job.diff, err = BuildReviewMap(ctx, job.database, job.p, job.pl); err != nil {
		return err
	}
	lanes, err := tools.LaneIntent(job.database, job.p, job.m)
	if err != nil {
		return err
	}
	job.in.Intent = tools.WithLaneIntent(job.in.Intent, lanes)
	return nil
}

// sessionLaneIntent is finish_session's tools.LaneIntentFunc: the lane items
// of the map of the session's folder at the gate's snapshot, the map the
// session form describes.
func sessionLaneIntent(ctx context.Context, d *db.DB, p *db.Workbench, session int64, snap tools.ReviewSnapshot) ([]reviewai.IntentItem, error) {
	pl, err := snapshotReviewPlace(ctx, snap, session)
	if err != nil {
		return nil, err
	}
	m, _, err := BuildReviewMap(ctx, d, p, pl)
	if err != nil {
		return nil, err
	}
	return tools.LaneIntent(d, p, m)
}

// answerReviewOverview answers the assembled overview cached for the job's
// tree, base and intent, or — unless --cached-only — runs the model. A
// --chapter or --summary run always runs; --continue answers a cached
// overview that is complete.
func answerReviewOverview(ctx context.Context, cmd *cobra.Command, job overviewJob, emit func(reviewai.Event)) error {
	if len(reviewFlagChapters) == 0 && !reviewFlagSummary {
		hash := reviewai.IntentHash(job.in.Intent, job.in.Notes)
		js, ok, err := job.database.ReviewOverviewJSON(job.p.ID, job.pl.Tree, job.pl.Base, hash)
		if err != nil {
			return failReview(cmd, err)
		}
		incomplete := cachedIncomplete(js)
		switch {
		case ok && (!reviewFlagContinue || len(incomplete) == 0):
			return writeReview(cmd, reviewEnvelope{OK: true, Overview: json.RawMessage(js), OverviewCached: true, Incomplete: &incomplete})
		case !ok && reviewFlagCachedOnly:
			return writeReview(cmd, reviewEnvelope{OK: true})
		}
	}
	// Task 8 (tech spec §3.7): every model-calling form takes the branch's
	// run lock here, after the cache check and before the first call; the
	// wait does not count into the run's ceiling, which starts in Run.
	return runReviewOverview(ctx, cmd, job, emit)
}

// cachedIncomplete is a cached overview's incomplete list; an overview
// cached before it existed is complete.
func cachedIncomplete(js string) []string {
	var o struct {
		Incomplete []string `json:"incomplete"`
	}
	_ = json.Unmarshal([]byte(js), &o)
	if o.Incomplete == nil {
		return []string{}
	}
	return o.Incomplete
}

// runReviewOverview runs the model (reviewai.Run writes the parts and the
// assembled overview) and answers the overview, or the run's error class,
// owner text and the provider's detail.
func runReviewOverview(ctx context.Context, cmd *cobra.Command, job overviewJob, emit func(reviewai.Event)) error {
	cfg, err := loadReviewAIConfig()
	if err != nil {
		return failReview(cmd, fmt.Errorf("AI overview unavailable: %w", err))
	}
	pipe := reviewai.New(reviewAIGeneratorFactory(cfg))
	pipe.SetPromptStore(prompts.New(job.database, nil))
	_, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	ov, err := pipe.Run(ctx, job.database, job.m, job.diff, job.in.Intent, job.in.Notes, reviewai.RunOptions{
		ProjectID: job.p.ID, Tree: job.pl.Tree, Base: job.pl.Base, Model: strong,
		Chapters: reviewFlagChapters, SummaryOnly: reviewFlagSummary, Emit: emit, Stderr: cmd.ErrOrStderr(),
	})
	var re *reviewai.RunError
	if errors.As(err, &re) {
		return writeReview(cmd, reviewEnvelope{Error: re.Text, ErrorClass: re.Class, Detail: re.Detail})
	}
	if err != nil {
		return failReview(cmd, err)
	}
	js, err := json.Marshal(ov)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Overview: js, Incomplete: &ov.Incomplete})
}

// overviewStream writes the streamed form's lines, one JSON object each,
// and a tick every reviewStreamTickEvery until stop.
type overviewStream struct {
	mu   sync.Mutex
	w    io.Writer
	stop func()
}

func startOverviewStream(w io.Writer) *overviewStream {
	s := &overviewStream{w: w}
	ticks, stopTicker := reviewStreamTicker(reviewStreamTickEvery)
	done, finished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		for {
			select {
			case <-ticks:
				s.emit(reviewai.Event{Event: "tick"})
			case <-done:
				return
			}
		}
	}()
	s.stop = sync.OnceFunc(func() {
		stopTicker()
		close(done)
		<-finished
	})
	return s
}

// emit writes one event line.
func (s *overviewStream) emit(e reviewai.Event) {
	b, err := json.Marshal(e)
	if err != nil {
		return // an Event always marshals
	}
	s.write(append(b, '\n'))
}

func (s *overviewStream) write(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.w.Write(p)
}

// activeOverviewStream is the running command's stream: writeReview writes
// the envelope through it, so no tick lands inside the envelope's line.
var activeOverviewStream *overviewStream

// writeStreamEnvelope writes env as the stream's last line: one compact
// JSON object.
func writeStreamEnvelope(w io.Writer, env reviewEnvelope) error {
	b, err := json.Marshal(env)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if s := activeOverviewStream; s != nil {
		s.write(b)
		return nil
	}
	_, err = w.Write(b)
	return err
}
