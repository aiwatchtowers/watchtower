package db

import (
	"fmt"
)

// MaintCoachBaselinesPerAgent is the db_maintenance key set once every
// accepted, unjudged coach proposal's baseline was re-measured on the agent
// its destination serves (coach.RemeasureMixedBaselines, board #1517).
const MaintCoachBaselinesPerAgent = "coach_baselines_per_agent"

// ListAcceptedUnjudgedCoachProposals returns the accepted proposals the judge
// may still give a verdict: no verdict yet or too_little_data (retried until
// the judge gives up), oldest first.
func (db *DB) ListAcceptedUnjudgedCoachProposals() ([]CoachProposal, error) {
	rows, err := db.Query(`SELECT ` + coachCols + ` FROM coach_proposals
		WHERE status = 'accepted' AND verdict IN ('', 'too_little_data') ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing unjudged coach proposals: %w", err)
	}
	defer rows.Close()
	var out []CoachProposal
	for rows.Next() {
		p, err := scanCoachProposal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// CASCoachBaseline sets proposal id's baseline (nil = NULL) and its n only
// while it is still accepted with no verdict or too_little_data and its
// baseline is still old (the baseline stands for the pair: Accept writes both
// at once); false when another writer got there first.
func (db *DB) CASCoachBaseline(id int64, old, value *float64, n int) (bool, error) {
	res, err := db.Exec(`UPDATE coach_proposals SET baseline = ?, baseline_n = ?
		WHERE id = ? AND status = 'accepted' AND verdict IN ('', 'too_little_data') AND baseline IS ?`,
		coachBaselineArg(value), n, id, coachBaselineArg(old))
	if err != nil {
		return false, fmt.Errorf("updating coach proposal %d baseline: %w", id, err)
	}
	changed, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("updating coach proposal %d baseline: %w", id, err)
	}
	return changed == 1, nil
}

// CoachBaselinesPerAgentDone reports whether MaintCoachBaselinesPerAgent is set.
func (db *DB) CoachBaselinesPerAgentDone() (bool, error) {
	_, ok, err := readMaintenance(db, MaintCoachBaselinesPerAgent)
	return ok, err
}

// MarkCoachBaselinesPerAgentDone sets MaintCoachBaselinesPerAgent.
func (db *DB) MarkCoachBaselinesPerAgentDone() error {
	_, err := db.Exec(`INSERT INTO db_maintenance (key, value) VALUES (?, '1')
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, MaintCoachBaselinesPerAgent)
	if err != nil {
		return fmt.Errorf("writing db_maintenance %s: %w", MaintCoachBaselinesPerAgent, err)
	}
	return nil
}

func coachBaselineArg(v *float64) any {
	if v == nil {
		return nil
	}
	return *v
}
