package tower

import (
	"context"
	"log"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
)

// PruneInterval is how often RunPrune prunes the request ledger.
const PruneInterval = time.Hour

// Prune deletes the request ledger rows of both states older than the hub's
// ledger window (actions.LedgerRetention), so both ledgers keep one window.
func Prune(ctx context.Context, d *db.DB, now time.Time) (int64, error) {
	return d.PruneTowerRequests(ctx, now.Add(-actions.LedgerRetention))
}

// RunPrune prunes at start and then every PruneInterval until ctx ends. The
// daemon runs it whether or not the hub runs.
func RunPrune(ctx context.Context, d *db.DB, now func() time.Time) {
	tick := time.NewTicker(PruneInterval)
	defer tick.Stop()
	for {
		if _, err := Prune(ctx, d, now()); err != nil && ctx.Err() == nil {
			log.Printf("tower: pruning the request ledger: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
