//go:build race

package confluenceedit

// raceEnabled skips CPU-time scaling checks: the race detector multiplies
// their cost and adds nothing to them.
const raceEnabled = true
