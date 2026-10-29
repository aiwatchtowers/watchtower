package daemon

import (
	"context"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/llmusage"
)

const (
	// llmLedgerRetention is how long llm_calls rows are kept.
	llmLedgerRetention = 90 * 24 * time.Hour
	// llmLedgerPruneEvery is how often the ledger is pruned.
	llmLedgerPruneEvery = 24 * time.Hour
)

// phaseLLMLedger moves the LLM calls other processes spooled into llm_calls
// — the workspace spool, then the setup spool of the calls made before any
// config existed (claimed by the first workspace's daemon to import it; the
// rename under the spool lock gives each line to exactly one workspace) —
// and once a day deletes the rows past the retention. Errors are logged;
// the cycle goes on.
func (d *Daemon) phaseLLMLedger(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	d.importLLMSpool("workspace", llmusage.SpoolPath(d.config.WorkspaceDir()))
	if root, err := config.DataRoot(); err != nil {
		d.logger.Printf("llm ledger: setup spool: %v", err)
	} else {
		d.importLLMSpool("setup", llmusage.SpoolPath(root))
	}

	now := time.Now()
	if !d.lastLLMPrune.IsZero() && now.Sub(d.lastLLMPrune) < llmLedgerPruneEvery {
		return
	}
	d.lastLLMPrune = now
	n, err := d.db.PruneLLMCalls(now.Add(-llmLedgerRetention))
	if err != nil {
		d.logger.Printf("llm ledger: prune: %v", err)
		return
	}
	if n > 0 {
		d.logger.Printf("llm ledger: pruned %d calls older than 90 days", n)
	}
}

func (d *Daemon) importLLMSpool(which, path string) {
	n, err := d.db.ImportLLMSpool(path)
	if err != nil {
		d.logger.Printf("llm ledger: importing the %s spool: %v", which, err)
		return
	}
	if n > 0 {
		d.logger.Printf("llm ledger: imported %d calls from the %s spool", n, which)
	}
}
