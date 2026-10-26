package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
)

// coachInterval is the gap between two coach runs.
const coachInterval = 7 * 24 * time.Hour

// coachGeneratorFactory is the seam tests override. The coach prompt carries
// the owner's own text, so it is the miner's stdin-only generator; the model
// tier comes from digest.TierForSource("coach.propose") (strong).
var coachGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return instructionGeneratorFactory(cfg)
}

// Seams tests replace to count and script the three steps.
var (
	runCoachJudge    = coach.Judge
	runCoachProposer = func(ctx context.Context, p *coach.Proposer, in coach.Inputs) (int, *digest.Usage, error) {
		return p.Run(ctx, in)
	}
)

func (d *Daemon) lastCoachPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_coach.txt")
}

func (d *Daemon) loadLastCoach() {
	data, err := os.ReadFile(d.lastCoachPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastCoach = time.Unix(unix, 0)
}

func (d *Daemon) saveLastCoach() {
	data := strconv.FormatInt(d.lastCoach.Unix(), 10)
	if err := os.WriteFile(d.lastCoachPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("coach: failed to save stamp: %v", err)
	}
}

// phaseCoach runs the agent coach once a week: judge the accepted proposals
// that are old enough, collect the signals, ask for new proposals. There is no
// catch-up: a stamp of any age gives exactly one run. The stamp is written
// after every run, a failed one included. No plan-limit gate (ask #655).
// Logs carry counts, never text.
func (d *Daemon) phaseCoach(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	if !d.lastCoach.IsZero() && now.Sub(d.lastCoach) < coachInterval {
		return
	}
	d.trackedPipelineRun("coach", func() pipelineRunStats {
		// A cycle cancelled mid-run (sleep/wake) must not cost the week.
		defer func() {
			if ctx.Err() != nil {
				return
			}
			d.lastCoach = now
			d.saveLastCoach()
		}()
		if d.agentLog == nil {
			d.logger.Printf("coach: agentlog.db is not open, judging skipped")
		} else if judged, cuts, err := runCoachJudge(d.db, d.agentLog, now); err != nil {
			d.logger.Printf("coach: judging: %v", err)
		} else {
			d.logger.Printf("coach: %d judged, %d cut", judged, cuts)
		}
		in, err := coach.Collect(ctx, d.db, d.agentLog, instructions.NewFeedReader(ctx, d.db, instructionSuggestionsDirs()), now)
		if err != nil {
			d.logger.Printf("coach: collecting signals: %v (retried next week)", err)
			return pipelineRunStats{err: err}
		}
		p := &coach.Proposer{DB: d.db, Gen: coachGeneratorFactory(d.config), Now: func() time.Time { return now }, Logger: d.logger, Lang: d.config.Digest.Language}
		n, usage, err := runCoachProposer(ctx, p, in)
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok, stats.outTok, stats.totalAPI = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
		}
		if err != nil {
			d.logger.Printf("coach: %v (retried next week)", err)
			return stats
		}
		d.logger.Printf("coach: %d written", n)
		return stats
	})
}
