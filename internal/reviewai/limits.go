package reviewai

// Overview input caps: the only place they live.
const (
	// MaxOverviewFileLines: a file with more diff lines is listed, not shown.
	MaxOverviewFileLines = 300
	// MaxOverviewLines: diff lines shown in all; the files after it are listed.
	MaxOverviewLines = 6000

	maxSummaryRunes   = 2000
	maxCoverage       = 50
	maxRisk           = 200
	maxChapters       = 30
	maxOverviewFields = 500 // runes of any one free-text field the model returns
)
