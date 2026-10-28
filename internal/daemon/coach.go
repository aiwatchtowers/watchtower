package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/coach"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"
	"watchtower/internal/sessionfeed"
)

// coachInterval is the gap between two coach runs; coachRetryAfter the gap
// after a failed run (a collect or model error) before it is tried again.
const (
	coachInterval   = 7 * 24 * time.Hour
	coachRetryAfter = 24 * time.Hour
)

// coachGeneratorFactory is the seam tests override. The coach prompt carries
// the owner's own typed text, so the CLI generators are switched to their
// stdin-only mode (CHAT-04: owner text is never on argv; the
// cmd.terminalTitleGeneratorFactory precedent, which the daemon cannot
// import); the model tier comes from digest.TierForSource("coach.propose")
// (strong).
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	if err := providers.Allowed(cfg.AI.Provider); err != nil {
		return digest.RefusedGenerator{Err: err} // #608: the run fails with the policy error, no fallback
	}
	light, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	var gen digest.Generator
	switch cfg.AI.Provider {
	case "codex":
		gen = codex.NewCodexGenerator(light, strong, cfg.CodexPath)
	case "ollama":
		gen = ollama.NewGenerator(light, strong, cfg.AI.OllamaURL)
	default:
		gen = digest.NewClaudeGenerator(light, strong, cfg.ClaudePath)
	}
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	return digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
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

// phaseCoach runs the agent coach once a week: fold the old instruction
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
		p := &coach.Proposer{DB: d.db, Gen: coachGeneratorFactory(d.config), Now: func() time.Time { return now }, Logger: d.logger, Lang: d.config.Digest.Language}
		n, usage, err := runCoachProposer(ctx, p, in)
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok, stats.outTok, stats.totalAPI = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
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
