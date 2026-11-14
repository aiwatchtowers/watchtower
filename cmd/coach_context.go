package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentreport"
	"watchtower/internal/coach"
	"watchtower/internal/db"
)

// The context proposer's steps of `coach run` (seams for tests).
var (
	coachContextPreview = coach.PreviewContext
	coachContextPropose = coach.ProposeContext
)

// coachProposeContext runs one pass of the mechanical context proposer over
// the workbenches with agent analytics on: a dry run lists what it would
// file, a real run files it and counts the new rows. A failure is printed on
// stderr and the run goes on, like the suggestion fold.
func coachProposeContext(cmd *cobra.Command, e *coachEnv, now time.Time, dry bool) (props []db.CoachProposal, written int) {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	ids, err := e.db.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "coach: context: %v\n", err)
		return nil, 0
	}
	home, _ := coachHome() // empty: the settings and memory rules are skipped
	env := coach.ContextEnv{DB: e.db, AgentLog: e.al, Home: home, Now: func() time.Time { return now },
		Lang: agentreport.LangOf(e.cfg.Digest.Language)}
	if dry {
		props, err = coachContextPreview(ctx, env, ids)
	} else {
		written, err = coachContextPropose(ctx, env, ids)
	}
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "coach: context: %v\n", err)
	}
	return props, written
}
