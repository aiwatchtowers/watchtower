// Package coach measures how well the owner's coding agents work and judges
// the prompt additions the coach proposes against those measurements.
package coach

import (
	"fmt"
	"time"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

// Value is one measured number. Known is false when its denominator was zero
// (no tasks, no active time, no reviews): V is then 0 and means nothing. N is
// how many units the value averages over.
type Value struct {
	V     float64
	N     int
	Known bool
}

// Metrics are the four coach metrics (plus the two review counts) over one
// period. Sessions is how many agent sessions the period covers.
type Metrics struct {
	Corrections    Value // interrupts + rejected calls per task
	TaskHours      Value // agent hours per task
	TaskCostUSD    Value // agent cost per task
	OwnerLoop      Value // share of active time the owner was the one working
	SpecFindings   Value // findings per first-round spec review
	ReviewComments Value // comments per first-round diff review
	Sessions       int
}

func ratio(num, den float64, n int) Value {
	if den <= 0 {
		return Value{}
	}
	return Value{V: num / den, N: n, Known: true}
}

// Measure computes the metrics over [since, until). workbenchID 0 is every
// workbench with analytics on: numerators and denominators are summed first
// and divided once, so a busy workbench weighs more than an idle one.
func Measure(main *db.DB, al *agentlogdb.DB, workbenchID int64, since, until time.Time) (Metrics, error) {
	ids := []int64{workbenchID}
	if workbenchID == 0 {
		var err error
		if ids, err = main.AgentAnalyticsWorkbenchIDs(); err != nil {
			return Metrics{}, fmt.Errorf("listing workbenches with analytics: %w", err)
		}
	}
	var m Metrics
	var tasks int
	var corrections, agentMS, costUSD, ownerMS, activeMS float64
	for _, id := range ids {
		ov, err := agentreport.BuildOverview(main, al, id, since, until, agentreport.English)
		if err != nil {
			return Metrics{}, fmt.Errorf("building overview of workbench %d: %w", id, err)
		}
		tasks += len(ov.Tasks) + ov.TasksMore
		corrections += float64(ov.Trouble.Interrupts + ov.Trouble.Rejections)
		for _, t := range ov.Tasks {
			agentMS += float64(t.AgentMS)
			costUSD += t.CostUSD
		}
		ownerMS += float64(ov.Time.OwnerMS)
		activeMS += float64(ov.Time.ActiveMS)
		m.Sessions += ov.Totals.Sessions
	}
	m.Corrections = ratio(corrections, float64(tasks), tasks)
	m.TaskHours = ratio(agentMS/3.6e6, float64(tasks), tasks)
	m.TaskCostUSD = ratio(costUSD, float64(tasks), tasks)
	m.OwnerLoop = ratio(ownerMS, activeMS, m.Sessions)

	sum, n, err := main.FirstRoundSpecFindings(workbenchID, since, until)
	if err != nil {
		return Metrics{}, err
	}
	m.SpecFindings = ratio(float64(sum), float64(n), n)
	sum, n, err = main.FirstRoundReviewComments(workbenchID, since, until)
	if err != nil {
		return Metrics{}, err
	}
	m.ReviewComments = ratio(float64(sum), float64(n), n)
	return m, nil
}

// Of returns the value a proposal's target metric names; an unknown name is
// not known.
func (m Metrics) Of(metric string) Value {
	switch metric {
	case "corrections":
		return m.Corrections
	case "task_cost":
		return m.TaskCostUSD
	case "owner_loop":
		return m.OwnerLoop
	case "review_findings":
		return m.SpecFindings
	}
	return Value{}
}
