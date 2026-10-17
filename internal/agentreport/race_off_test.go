//go:build !race

package agentreport

// raceEnabled skips wall-clock budgets: the race detector multiplies them.
const raceEnabled = false
