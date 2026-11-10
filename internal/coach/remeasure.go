package coach

import (
	"errors"
	"fmt"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// RemeasureMixedBaselines re-takes, once per install, the baseline of every
// accepted proposal the judge may still judge (no verdict, or a retryable
// too_little_data) on the agent its destination serves
// (AgentFor): before board #1517 a baseline counted every agent's sessions,
// so a Claude text's baseline could carry Codex rows (spec D58, ask #1152).
// The window is the Accept's own, [decided_at − 14 days, decided_at]; a
// window with nothing measurable gives a nil baseline (too_little_data at
// the verdict). Each row is written with a compare-and-set on its stored
// baseline, so a final verdict or a rollback written meanwhile (the judge,
// `coach rollback`) wins and the row is left alone. The db_maintenance key
// MaintCoachBaselinesPerAgent is written once every row is done; until then
// (a crash, an error, agent analytics still waiting for their move out of
// watchtower.db) the next call runs it again — at daemon start and before
// each Judge. al nil (no agent analytics) writes the key at once. The count
// is the baselines that changed.
func RemeasureMixedBaselines(main *db.DB, al *agentlogdb.DB) (int, error) {
	return remeasure(main, al, nil)
}

// remeasure is RemeasureMixedBaselines with a hook run between the
// measurement and the compare-and-set (tests only: nil in production).
func remeasure(main *db.DB, al *agentlogdb.DB, beforeCAS func(db.CoachProposal)) (int, error) {
	done, err := main.CoachBaselinesPerAgentDone()
	if err != nil || done {
		return 0, err
	}
	if al == nil {
		return 0, main.MarkCoachBaselinesPerAgentDone()
	}
	// Rows still in watchtower.db would measure as nothing: wait for the move.
	if moved, err := al.Moved(); err != nil || !moved {
		return 0, err
	}
	accepted, err := main.ListAcceptedUnjudgedCoachProposals()
	if err != nil {
		return 0, err
	}
	rewritten := 0
	var errs []error
	for _, p := range accepted {
		if p.DecidedAt.IsZero() {
			continue
		}
		m, err := Measure(main, al, p.WorkbenchID, p.DecidedAt.Add(-baselineWindow), p.DecidedAt, AgentFor(p.Destination))
		if err != nil {
			errs = append(errs, fmt.Errorf("re-measuring coach proposal %d: %w", p.ID, err))
			continue
		}
		var value *float64
		n := 0
		if v := m.Of(p.Metric); v.Known {
			value, n = &v.V, v.N
		}
		if sameBaseline(p.Baseline, value) && p.BaselineN == n {
			continue
		}
		if beforeCAS != nil {
			beforeCAS(p)
		}
		ok, err := main.CASCoachBaseline(p.ID, p.Baseline, value, n)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if ok {
			rewritten++
		}
	}
	if err := errors.Join(errs...); err != nil {
		return rewritten, err
	}
	return rewritten, main.MarkCoachBaselinesPerAgentDone()
}

func sameBaseline(a, b *float64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
