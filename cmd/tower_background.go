package cmd

import (
	"log"
	"sync"
	"time"
)

// towerBackgroundBudget bounds the daemon stop's wait for the tower's
// background work (a phone approval's tool apply), as the hub's chat
// applies are bounded.
const towerBackgroundBudget = 30 * time.Second

// towerBackground runs inbox.act's background work (ActDeps.Background: a
// tool the phone approved, applied after the hub answered) on goroutines the
// daemon waits for before the database closes.
type towerBackground struct{ wg sync.WaitGroup }

func (b *towerBackground) run(fn func()) {
	b.wg.Add(1)
	go func() {
		defer b.wg.Done()
		fn()
	}()
}

// wait returns once every run returned, or after budget.
func (b *towerBackground) wait(budget time.Duration) {
	done := make(chan struct{})
	go func() {
		b.wg.Wait()
		close(done)
	}()
	t := time.NewTimer(budget)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
		log.Printf("tower: a background apply is still running at stop; its outcome lands on its row if it finishes")
	}
}
