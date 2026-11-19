package cmd

import (
	"testing"
	"testing/synctest"
	"time"
)

// TestTowerBackground_WaitsForARunWithinTheBudget: the daemon's stop waits
// for a phone approval's apply before the database closes, at most the
// budget.
func TestTowerBackground_WaitsForARunWithinTheBudget(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var b towerBackground
		finished := false
		b.run(func() {
			time.Sleep(5 * time.Second)
			finished = true
		})
		start := time.Now()
		b.wait(towerBackgroundBudget)
		if !finished || time.Since(start) != 5*time.Second {
			t.Fatalf("wait returned after %v, finished %v", time.Since(start), finished)
		}
	})
	synctest.Test(t, func(t *testing.T) {
		var b towerBackground
		b.run(func() { time.Sleep(time.Hour) })
		start := time.Now()
		b.wait(towerBackgroundBudget)
		if waited := time.Since(start); waited != towerBackgroundBudget {
			t.Fatalf("waited %v, want the budget", waited)
		}
		time.Sleep(time.Hour) // the run ends inside the bubble
	})
}
