//go:build !race

package codeindex

// raceSlowdown scales wall-clock bounds for the race detector's overhead.
const raceSlowdown = 1
