package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
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
	for _, key := range reviewFlagChapters { // never a summary-only run by a typo or a stale key
		if !slices.ContainsFunc(job.m.Chapters, func(ch reviewmap.Chapter) bool { return ch.Key == key }) {
			return usageError("unknown chapter %s", key)
		}
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
		var dirty string
		if job.pl, dirty, err = sessionReviewPlace(gitCtx, job.database, job.p, reviewFlagSession); err != nil {
			return job, false, failReview(cmd, err)
		}
		if dirty != "" { // the finish gate refuses it too: the reviewer never reads those changes
			return job, false, failReview(cmd, errors.New(dirty))
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

// answerReviewOverview answers the assembled overview cached for the job's
// tree, base and intent, or — unless --cached-only — runs the model under
// the branch's run lock (tech spec §3.7). A streamed run that waited for
// another run's lock looks at the cache again: that run may have made the
// very overview.
func answerReviewOverview(ctx context.Context, cmd *cobra.Command, job overviewJob, emit func(reviewai.Event)) error {
	if done, err := answerCachedOverview(cmd, job); done {
		return err
	}
	cfg, err := loadReviewAIConfig()
	if err != nil {
		return failReview(cmd, fmt.Errorf("AI overview unavailable: %w", err))
	}
	pipe := reviewai.New(reviewAIGeneratorFactory(cfg))
	pipe.SetPromptStore(prompts.New(job.database, nil))
	lock := &overviewLock{job: job, pipe: pipe, emit: emit, shown: map[string]bool{}}
	release, err := lock.acquire(ctx, cfg.WorkspaceDir())
	var busy *reviewai.BusyError
	switch {
	case errors.As(err, &busy):
		re := busy.RunError()
		env := reviewEnvelope{Error: re.Text, ErrorClass: re.Class}
		if busy.Waited { // the streamed form: an envelope like any failed run
			return writeReview(cmd, env)
		}
		if werr := writeReview(cmd, env); werr != nil {
			return werr
		}
		return &exitCodeError{code: 1, err: busy}
	case errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded):
		return writeReview(cmd, reviewEnvelope{Error: reviewai.CancelledText, ErrorClass: reviewai.ClassCancelled})
	case err != nil:
		return failReview(cmd, err)
	}
	defer release()
	if lock.waited {
		if done, err := answerCachedOverview(cmd, job); done {
			return err
		}
	}
	// The run's ceiling starts in Run, after the wait.
	return runReviewOverview(ctx, cmd, cfg, pipe, job, lock.runEmit())
}

// answerCachedOverview answers the cached assembled overview (done true),
// or a --cached-only miss. A --chapter or --summary run always runs;
// --continue answers a cached overview that is complete.
func answerCachedOverview(cmd *cobra.Command, job overviewJob) (done bool, err error) {
	if len(reviewFlagChapters) > 0 || reviewFlagSummary {
		return false, nil
	}
	hash := reviewai.IntentHash(job.in.Intent, job.in.Notes)
	js, ok, err := job.database.ReviewOverviewJSON(job.p.ID, job.pl.Tree, job.pl.Base, hash)
	if err != nil {
		return true, failReview(cmd, err)
	}
	incomplete, readable := cachedIncomplete(js)
	switch {
	case ok && (!reviewFlagContinue || (readable && len(incomplete) == 0)):
		return true, writeReview(cmd, reviewEnvelope{OK: true, Overview: json.RawMessage(js), OverviewCached: true, Incomplete: &incomplete})
	case !ok && reviewFlagCachedOnly:
		return true, writeReview(cmd, reviewEnvelope{OK: true})
	}
	return false, nil
}

// reviewLockWait is the streamed form's wait for another run's lock (zero:
// reviewai.LockWaitCap, a part re-read every reviewai.LockWaitEvery); tests
// shorten it.
var reviewLockWait reviewai.LockWait

// reviewWaitingEvery is how often a waiting stream repeats its waiting
// line (tech spec §3.7); tests shorten it.
var reviewWaitingEvery = time.Minute

// overviewLock takes the run lock of a job's folder. Only the streamed form
// waits: it prints a waiting line at once and every reviewWaitingEvery, and
// a cached chapter line for each part the holder writes meanwhile (shown).
type overviewLock struct {
	job    overviewJob
	pipe   *reviewai.Pipeline
	emit   func(reviewai.Event)
	waited bool
	shown  map[string]bool
	said   time.Time // the last waiting line
	warned bool      // a part read failed and was logged
}

func (l *overviewLock) acquire(ctx context.Context, workspaceDir string) (func(), error) {
	path := reviewai.LockPath(workspaceDir, l.job.p.ID, realFolderPath(l.job.pl.Folder))
	if !reviewFlagStream {
		return reviewai.AcquireRun(ctx, path, overviewCaller(), nil)
	}
	wait := reviewLockWait
	wait.OnWait = l.onWait
	return reviewai.AcquireRun(ctx, path, overviewCaller(), &wait)
}

// onWait is one beat of the wait: the waiting line when due, then the
// parts that appeared since the last beat.
func (l *overviewLock) onWait(h reviewai.Holder) {
	now := time.Now()
	if !l.waited || now.Sub(l.said) >= reviewWaitingEvery {
		l.emit(reviewai.Event{Event: "waiting", By: h.By})
		l.said = now
	}
	l.waited = true
	cached, err := l.pipe.CachedChapters(l.job.database, l.job.p.ID, l.job.m, l.job.diff, l.job.in.Notes)
	if err != nil { // the run itself reads the parts again once it holds the lock
		if !l.warned {
			l.warned = true
			log.Printf("review overview: waiting run could not read the cached parts (project %d)", l.job.p.ID)
		}
		return
	}
	for _, ch := range l.job.m.Chapters {
		if d, ok := cached[ch.Key]; ok && !l.shown[ch.Key] {
			l.shown[ch.Key] = true
			l.emit(reviewai.ChapterEvent(reviewai.StateCached, d))
		}
	}
}

// runEmit is the run's emit: a cached line the wait already printed is not
// printed twice.
func (l *overviewLock) runEmit() func(reviewai.Event) {
	if len(l.shown) == 0 {
		return l.emit
	}
	return func(e reviewai.Event) {
		if e.Event == "chapter" && e.State == reviewai.StateCached && l.shown[e.Key] {
			return
		}
		l.emit(e)
	}
}

// overviewCaller is who runs the overview, written into the run lock:
// --caller, else agent under an AI agent (AGENT-07's markers), else cli.
func overviewCaller() string {
	if reviewFlagCaller != "" {
		return reviewFlagCaller
	}
	for _, name := range agentEnvMarkers {
		if os.Getenv(name) != "" {
			return "agent"
		}
	}
	return "cli"
}

// realFolderPath is folder with its symlinks resolved; as given when it
// does not resolve.
func realFolderPath(folder string) string {
	if resolved, err := filepath.EvalSymlinks(folder); err == nil {
		return resolved
	}
	return filepath.Clean(folder)
}

// cachedIncomplete is a cached overview's incomplete list; an overview
// cached before it existed is complete. readable false: the row does not
// decode, so --continue runs instead of answering it.
func cachedIncomplete(js string) (incomplete []string, readable bool) {
	var o struct {
		Incomplete []string `json:"incomplete"`
	}
	if err := json.Unmarshal([]byte(js), &o); err != nil {
		return []string{}, false
	}
	if o.Incomplete == nil {
		return []string{}, true
	}
	return o.Incomplete, true
}

// runReviewOverview runs the model (reviewai.Run writes the parts and the
// assembled overview) and answers the overview, or the run's error class,
// owner text and the provider's detail.
func runReviewOverview(ctx context.Context, cmd *cobra.Command, cfg *config.Config, pipe *reviewai.Pipeline, job overviewJob,
	emit func(reviewai.Event)) error {
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
// the envelope through it after stopping the ticks, so no tick lands inside
// or after the envelope's line.
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
		s.stop() // no tick after the last line
		s.write(b)
		return nil
	}
	_, err = w.Write(b)
	return err
}
