package cmd

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/agentreport"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/tuning"
)

// tuningDeps fills the tuning chat's readers (spec 2026-11-03-tuning-chat-design
// §4.2) with the CLI's own: the agent report and session of `agents report`,
// `usage llm`'s report, the prompt store, and the coach's environment — the
// same home folders and git reader (coachRepoState) a CLI Accept uses, so the
// MCP child and `coach accept` read a repository file's state alike. It runs
// no git itself (COACH-01: TestCOACH01_NoGitWrites).
func tuningDeps(cfg *config.Config) tuning.Deps {
	now := func() time.Time { return time.Now().UTC() }
	return tuning.Deps{
		Store: func(d *db.DB) *prompts.Store { return prompts.New(d, nil) },
		AgentReport: func(_ context.Context, wb int64, days int, agent string) (any, error) {
			t := now()
			var since time.Time
			if days > 0 {
				since = t.AddDate(0, 0, -days)
			}
			if agent == "" {
				agent = agentreport.AgentAll
			}
			ov, _, err := agentsReportValue(cfg, wb, since, t, "", agent)
			if err != nil {
				return nil, err
			}
			return ov, nil
		},
		AgentSession: func(_ context.Context, wb int64, uuid string) (any, error) {
			_, det, err := agentsReportValue(cfg, wb, time.Time{}, now(), uuid, agentreport.AgentAll)
			if errors.Is(err, agentreport.ErrSessionNotFound) {
				return nil, fmt.Errorf("%w: %w", tuning.ErrNotFound, err)
			}
			if err != nil {
				return nil, err
			}
			return det, nil
		},
		LLMUsage: func(_ context.Context, period string) (any, error) {
			since, err := usageLLMSince(period, time.Now())
			if err != nil {
				return nil, err
			}
			return buildUsageLLMReport(cfg, period, since)
		},
		Now: now,
		CoachEnv: func() coach.Env {
			home, _ := coachHome() // empty: the tuning tools refuse with "no home folder"
			return coach.Env{Home: home, CodexHome: coach.CodexHomeFromEnv(), RepoState: coachRepoState()}
		},
	}
}
