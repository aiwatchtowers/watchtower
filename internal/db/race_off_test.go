//go:build !race

package db

// raceSlowdown scales wall-clock bounds for the race detector's overhead.
const raceSlowdown = 1
