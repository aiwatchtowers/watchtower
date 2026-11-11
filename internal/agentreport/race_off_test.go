//go:build !race

package agentreport

// raceEnabled skips the 150k-event scaling test: the race detector makes it too costly.
const raceEnabled = false
