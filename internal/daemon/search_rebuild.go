package daemon

import (
	"context"
	"time"

	"watchtower/internal/db"
)

// searchRebuildBudget bounds one cycle's messages search fill, so a large
// index spreads across cycles instead of delaying every later phase. Tests
// mutate it; no t.Parallel.
var searchRebuildBudget = 30 * time.Second

// searchRebuildChunkRows is the fill's chunk size, 0 = the db default. Tests
// mutate it; no t.Parallel.
var searchRebuildChunkRows = 0

// phaseMessagesSearchRebuild finishes a pending messages search fill
// (migration 00146) in the background, for installs whose launch step
// (`db compact --if-due`) did not run, did not finish or gave up after
// failures. Mechanical, no AI, no pipeline_runs row; independent of the
// compaction's and the launch fill's failure caps. It is inert when nothing
// is pending. A volume below the fill's small free-space floor is skipped
// every cycle and logged once, again after a cycle found room. The fill
// frees the legacy index first, so it never needs room for both indexes.
func (d *Daemon) phaseMessagesSearchRebuild(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	check, err := d.db.CheckMessagesSearchRebuild()
	if err != nil {
		d.logger.Printf("search index: %v", err)
		return
	}
	if !check.Pending {
		return
	}
	if !check.DiskOK {
		if d.searchRebuildDiskLogged.CompareAndSwap(false, true) {
			d.logger.Printf("search index: rebuild needs %d MB free, %d MB available; skipped until there is room",
				check.NeedsDiskBytes>>20, check.FreeDiskBytes>>20)
		}
		return
	}
	d.searchRebuildDiskLogged.Store(false)
	// DrainLegacy: hooks, MCP and the Desktop write beside the daemon, and one
	// DROP of a large legacy index would hold the write lock past their
	// budgets.
	res, err := d.db.RebuildMessagesSearch(ctx, db.FTSRebuildOptions{
		Budget: searchRebuildBudget, ChunkRows: searchRebuildChunkRows, DrainLegacy: true,
	})
	switch {
	case err != nil && isBenignShutdownErr(ctx, err):
		// Committed chunks stay; the next run resumes.
		d.logger.Printf("search index: stopped by shutdown")
	case err != nil:
		d.logger.Printf("search index: %v (this cycle: %d messages indexed in %d chunks)", err, res.Indexed, res.Chunks)
	case res.Done:
		d.logger.Printf("search index: rebuilt")
	case res.DrainChunks == 0:
		d.logger.Printf("search index: %d messages indexed, continuing next cycle", res.Indexed)
	case res.Indexed == 0:
		d.logger.Printf("search index: clearing the old index, continuing next cycle")
	default:
		// Fill chunks run only once the old index is gone.
		d.logger.Printf("search index: old index cleared, %d messages indexed, continuing next cycle", res.Indexed)
	}
}
