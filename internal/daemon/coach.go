package daemon

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/workbenchgit"
)

// coachInterval is the gap between two coach runs; coachRetryAfter the gap
// after a failed run (a collect or model error) before it is tried again.
const (
	coachInterval   = 7 * 24 * time.Hour
	coachRetryAfter = 24 * time.Hour
	// coachCommitsEvery is the gap between two commit checks of the accepted
	// workbench repository edits; coachHeadReadBudget caps one git read.
	coachCommitsEvery   = 24 * time.Hour
	coachHeadReadBudget = 15 * time.Second
)

// coachGeneratorFactory is the seam tests override. The coach prompt carries
// the owner's own typed text, which every CLI generator sends on stdin, never
// argv (CHAT-04); the model tier comes from
// digest.TierForSource("coach.propose") (strong). The reserve leaves are CLI
// children only, isolated (digest.IsolateChild).
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	snapshot := *cfg
	snapshot.AI.Providers = maps.Clone(cfg.AI.Providers)
	cfg = &snapshot
	if err := providers.Allowed(cfg.AI.Provider); err != nil {
		return digest.RefusedGenerator{Err: err} // #608: the run fails with the policy error, no fallback
	}
	gen := transport.For(cfg.AI.Provider).NewGenerator(transport.Options{Config: cfg})
	legacy := digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
	return providerrouting.WrapGenerator(cfg, legacy, func(provider string) digest.Generator {
		if !providers.RunsChild(provider) {
			err := providers.Allowed(provider)
			if err == nil {
				err = fmt.Errorf("coach: reserve provider %q runs no CLI child", provider)
			}
			return digest.RefusedGenerator{Err: err}
		}
		return transport.For(provider).NewGenerator(transport.Options{Config: cfg, IsolatedChild: true})
	}, providerrouting.GeneratorOptions{Timeout: digest.DaemonAICallTimeout})
}

// coachSessionDirs is the test seam for the transcript directories the owner
// lines are read from (the same rules as the cmd terminal seams: Claude
// Code's dir is always ~/.claude; Codex's is an absolute $CODEX_HOME, else
// ~/.codex).
var coachSessionDirs = func() sessionfeed.Dirs {
	dirs := sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentlog.DefaultClaudeDir(), "projects")}
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		dirs.CodexHome = dir
	} else if home, err := os.UserHomeDir(); err == nil {
		dirs.CodexHome = filepath.Join(home, ".codex")
	}
	return dirs
}

// Seams tests replace to count and script the steps.
var (
	// coachFileAtHead reads a workbench file at the folder's HEAD: the
	// read-only `git show` of workbenchgit.FileAtHead (COACH-01:
	// TestCOACH01_NoGitWrites scans this file).
	coachFileAtHead = func(ctx context.Context, folder, rel string) (string, bool, error) {
		return workbenchgit.FileAtHead(ctx, workbenchgit.Options{Folder: folder}, rel)
	}
	runCoachImport   = coach.ImportSuggestions
	runCoachJudge    = coach.Judge
	runCoachProposer = func(ctx context.Context, p *coach.Proposer, in coach.Inputs) (int, *digest.Usage, error) {
		return p.Run(ctx, in)
	}
)

func (d *Daemon) lastCoachPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_coach.txt")
}

func (d *Daemon) lastCoachFailedPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_coach_failed.txt")
}

func (d *Daemon) loadLastCoach() {
	d.lastCoach = readUnixStamp(d.lastCoachPath())
	d.lastCoachFailed = readUnixStamp(d.lastCoachFailedPath())
}

// readUnixStamp reads a file of unix seconds; zero when missing or unreadable.
func readUnixStamp(path string) time.Time {
	data, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(unix, 0)
}

func (d *Daemon) saveLastCoach() {
	data := strconv.FormatInt(d.lastCoach.Unix(), 10)
	if err := os.WriteFile(d.lastCoachPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("coach: failed to save stamp: %v", err)
	}
	d.lastCoachFailed = time.Time{}
	if err := os.Remove(d.lastCoachFailedPath()); err != nil && !os.IsNotExist(err) {
		d.logger.Printf("coach: failed to clear the failure stamp: %v", err)
	}
}

// markCoachFailed records a failed run: the next try is coachRetryAfter later.
func (d *Daemon) markCoachFailed(now time.Time) {
	d.lastCoachFailed = now
	data := strconv.FormatInt(now.Unix(), 10)
	if err := os.WriteFile(d.lastCoachFailedPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("coach: failed to save the failure stamp: %v", err)
	}
}

// phaseCoach checks the accepted workbench repository edits for their commit
// once a day (coachCommitCheck), and runs the agent coach once a week: fold the old instruction
// suggestions in (once ever, ImportSuggestions), judge the accepted proposals
// that are old enough, collect the signals, ask for new proposals. The fold
// runs under the lock, before proposing, so it and `coach run` never race on
// the free slots; its error is logged and the pass goes on. There is no
// catch-up: a stamp of any age gives exactly one run. The weekly stamp is
// written only when the proposing step ran to completion (spec §6.2: a failed
// run is retried next time): a collect or model error writes the failure stamp
// instead and is retried a day later, not every cycle; a cycle cancelled
// mid-run writes neither and the next cycle runs again; a judging error alone
// does not hold the week. No plan-limit gate (ask #655). Logs carry counts,
// never text.
func (d *Daemon) phaseCoach(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	if d.lastCoachCommits.IsZero() || now.Sub(d.lastCoachCommits) >= coachCommitsEvery {
		d.lastCoachCommits = now
		d.coachCommitCheck(ctx, now)
	}
	if !d.lastCoach.IsZero() && now.Sub(d.lastCoach) < coachInterval {
		return
	}
	if !d.lastCoachFailed.IsZero() && now.Sub(d.lastCoachFailed) < coachRetryAfter {
		return
	}
	// The same lock `coach run` holds: a pass already running (the owner's
	// own) is not doubled; nothing is stamped, so the next cycle looks again.
	unlock, ok, err := fsutil.TryLockFile(coach.LockPath(d.config.WorkspaceDir()))
	if err != nil {
		d.logger.Printf("coach: lock: %v", err)
		return
	}
	if !ok {
		d.logger.Printf("coach: busy, skipped")
		return
	}
	defer unlock()
	d.trackedPipelineRun("coach", func() pipelineRunStats {
		if n, err := runCoachImport(d.db, d.config.Digest.Language, now); err != nil {
			d.logger.Printf("coach: folding instruction suggestions: %v", err)
		} else if n > 0 {
			d.logger.Printf("coach: %d instruction suggestion(s) folded into proposals", n)
		}
		if d.agentLog == nil {
			d.logger.Printf("coach: agentlog.db is not open, judging skipped")
		} else if judged, cuts, err := runCoachJudge(d.db, d.agentLog, now); err != nil {
			d.logger.Printf("coach: judging: %v", err)
		} else {
			d.logger.Printf("coach: %d judged, %d cut", judged, cuts)
		}
		in, err := coach.Collect(ctx, d.db, d.agentLog, instructions.NewFeedReader(ctx, d.db, coachSessionDirs()), now)
		if err != nil {
			if ctx.Err() == nil {
				d.markCoachFailed(now)
			}
			d.logger.Printf("coach: collecting signals: %v (retried tomorrow)", err)
			return pipelineRunStats{err: err}
		}
		gen := d.coachGenerator(ctx)
		p := &coach.Proposer{DB: d.db, Gen: gen, Now: func() time.Time { return now }, Logger: d.logger, Lang: d.config.Digest.Language}
		n, usage, err := runCoachProposer(ctx, p, in)
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok, stats.outTok, stats.totalAPI = usage.InputTokens(), usage.OutputTokens(), usage.TotalAPITokens()
		}
		if ctx.Err() != nil { // a cycle cancelled mid-run (sleep/wake) is retried next cycle
			return stats
		}
		if err != nil {
			d.markCoachFailed(now)
			d.logger.Printf("coach: %v (retried tomorrow)", err)
			return stats
		}
		d.lastCoach = now
		d.saveLastCoach()
		d.logger.Printf("coach: %d written", n)
		return stats
	})
}

// coachGenerator keeps the coach's stdin-only factory while sharing worker
// admission and the caller's immutable routing inputs with the rest of the job.
func (d *Daemon) coachGenerator(ctx context.Context) digest.Generator {
	gen := coachGeneratorFactory(config.RoutingSnapshot(ctx, d.config))
	if d.aiWorkerPool != nil {
		gen = digest.WithCallTimeout(digest.NewPooledGenerator(gen, d.aiWorkerPool), digest.DaemonAICallTimeout)
	}
	return gen
}

// coachCommitCheck starts the verdict window of each accepted workbench
// repository edit the owner has committed (spec §4.3a, D68): the first time
// the file at the workbench folder's HEAD equals the accepted text,
// measure_from = now, by a compare-and-set on measure_from IS NULL (a second
// pass is a no-op). A folder that is gone, is not a git work tree any more,
// or cannot be read skips the row that day; the judge's 30-day rule ends a
// row never committed. Git is read outside any write transaction; each
// SetCoachMeasureFrom is its own short write. Logs carry ids, never a path.
func (d *Daemon) coachCommitCheck(ctx context.Context, now time.Time) {
	ps, err := d.db.ListRepoProposalsAwaitingCommit()
	if err != nil {
		d.logger.Printf("coach: commit check: %v", err)
		return
	}
	committed := 0
	for _, p := range ps {
		if ctx.Err() != nil {
			return
		}
		seen, why := d.coachEditAtHead(ctx, p)
		if why != "" {
			d.logger.Printf("coach: commit check: proposal %d (workbench %d) skipped today: %s", p.ID, p.WorkbenchID, why)
			continue
		}
		if !seen {
			continue
		}
		set, err := d.db.SetCoachMeasureFrom(p.ID, now)
		if err != nil {
			d.logger.Printf("coach: commit check: proposal %d: %v", p.ID, err)
			continue
		}
		if set {
			committed++
		}
	}
	if committed > 0 {
		d.logger.Printf("coach: commit check: %d repository edit(s) committed, measured from now", committed)
	}
}

// coachEditAtHead reports whether p's file at its workbench folder's HEAD
// holds p's accepted text; why names a skip (never the folder or the path).
func (d *Daemon) coachEditAtHead(ctx context.Context, p db.CoachProposal) (seen bool, why string) {
	rel, ok := coach.RepoRelPath(p.Destination, p.Skill)
	if !ok {
		return false, "not a repository file"
	}
	w, err := d.db.GetWorkbench(p.WorkbenchID)
	if err != nil {
		return false, "workbench not readable"
	}
	if fi, err := os.Stat(w.FolderPath); err != nil || !fi.IsDir() {
		return false, "folder gone"
	}
	readCtx, cancel := context.WithTimeout(ctx, coachHeadReadBudget)
	defer cancel()
	text, ok, err := coachFileAtHead(readCtx, w.FolderPath, rel)
	if err != nil {
		return false, "not readable at HEAD (not a git work tree, or git failed)"
	}
	return ok && text == p.AfterText, ""
}
