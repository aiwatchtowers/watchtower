//go:build race

package transporttest

// raceEnabled stretches the cells' deadlines: the race detector slows the
// in-process adapters several times over.
const raceEnabled = true
