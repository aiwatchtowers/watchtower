package cmd

import (
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

// coachProposeContext runs the mechanical context proposer for every
// workbench with agent analytics on: a dry run lists what it would file
// (a global proposal once, though every workbench finds it), a real run files
// it and counts the new rows. A failure is printed on stderr and the run goes
// on, like the suggestion fold.
func coachProposeContext(cmd *cobra.Command, e *coachEnv, now time.Time, dry bool) (props []db.CoachProposal, written int) {
	ids, err := e.db.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "coach: context: %v\n", err)
		return nil, 0
	}
	home, _ := coachHome() // empty: the memory rule is skipped, the config reads as missing
	env := coach.ContextEnv{DB: e.db, AgentLog: e.al, Home: home, Now: func() time.Time { return now },
		Lang: agentreport.LangOf(e.cfg.Digest.Language)}
	seen := map[string]bool{}
	for _, id := range ids {
		if dry {
			ps, err := coachContextPreview(env, id)
			if err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "coach: context: workbench %d: %v\n", id, err)
				continue
			}
			for _, p := range ps {
				if !seen[p.Fingerprint] {
					seen[p.Fingerprint] = true
					props = append(props, p)
				}
			}
			continue
		}
		n, err := coachContextPropose(env, id)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "coach: context: workbench %d: %v\n", id, err)
		}
		written += n
	}
	return props, written
}
