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
// (`db compact --if-due`) did not run or did not finish. Mechanical, no AI,
// no pipeline_runs row; independent of the compaction's failure cap. It is
// inert when nothing is pending. A volume without room for the fill is
// logged once per daemon run and skipped every cycle; once the fill has
// reached the last message, only freeing the legacy index is left and the
// disk rule no longer applies (CheckMessagesSearchRebuild's FillDone).
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
	// DrainLegacy: hooks, MCP and the Desktop write beside the daemon, and one
	// DROP of a large legacy index would hold the write lock past their
	// budgets.
	res, err := d.db.RebuildMessagesSearch(ctx, db.FTSRebuildOptions{
		Budget: searchRebuildBudget, ChunkRows: searchRebuildChunkRows, DrainLegacy: true,
	})
	switch {
	case err != nil && isBenignShutdownErr(ctx, err):
		// Committed chunks keep their cursor; the next run resumes.
		d.logger.Printf("search index: stopped by shutdown")
	case err != nil:
		d.logger.Printf("search index: %v", err)
	case res.Done:
		d.logger.Printf("search index: rebuilt")
	case res.DrainChunks == 0:
		d.logger.Printf("search index: %d messages indexed, continuing next cycle", res.Indexed)
	case res.Indexed == 0:
		d.logger.Printf("search index: clearing the old index, continuing next cycle")
	default:
		d.logger.Printf("search index: %d messages indexed, clearing the old index, continuing next cycle", res.Indexed)
	}
}
