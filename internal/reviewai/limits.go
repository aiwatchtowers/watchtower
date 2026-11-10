package reviewai

import "time"

// Overview input caps and budgets (tech spec §3.1, §3.2): the only place
// they live.
const (
	// MaxBatchLines: diff lines one model call is shown.
	MaxBatchLines = 2500
	// MaxOverviewFileLines: lines shown of one file; the rest is counted
	// as "(+N lines not shown)".
	MaxOverviewFileLines = 300

	// SummaryBudget is the time of the summary call of a multi-batch run.
	SummaryBudget = 2 * time.Minute
	// MaxRunBudget caps a whole run however many batches it has.
	MaxRunBudget = 45 * time.Minute
	// maxParallel batch calls run at once.
	maxParallel = 4

	maxSummaryRunes   = 2000
	maxWhatRunes      = 600 // a chapter description
	maxCoverage       = 50
	maxRisk           = 200 // per chapter
	maxOverviewFields = 500 // runes of any other free-text field the model returns
)
