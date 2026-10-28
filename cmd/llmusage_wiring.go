package cmd

import (
	"path/filepath"
	"sync"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// ledgerFallbackBusy bounds the fallback insert's wait for the write lock: a
// hook on a hard budget may be the caller.
const ledgerFallbackBusy = 2 * time.Second

// wireLLMUsage points this process's LLM call records at their files. A
// process that cannot resolve a workspace — cfg nil (no config file) or a
// config with no active workspace after --workspace — has no workspace
// database, so its calls go to the setup spool under the data root (the
// first daemon cycle of any workspace claims it), with no fallback and the
// loss line in the data root's watchtower.log. Otherwise calls go to the
// workspace spool, the fallback is a direct insert into that workspace's
// database, and the loss line goes to its watchtower.log.
func wireLLMUsage(cfg *config.Config) {
	root, err := config.DataRoot()
	if err != nil {
		return // no home: Record reports each call lost on stderr
	}
	ws := ""
	if cfg != nil {
		ws = cfg.ActiveWorkspace
		if flagWorkspace != "" {
			ws = flagWorkspace
		}
	}
	if ws == "" {
		llmusage.SetSpoolPath(llmusage.SpoolPath(root))
		llmusage.SetFallback(nil)
		llmusage.SetLogPath(filepath.Join(root, "watchtower.log"))
		return
	}
	dir := filepath.Join(root, ws) // config.Config.WorkspaceDir for ws
	llmusage.SetSpoolPath(llmusage.SpoolPath(dir))
	llmusage.SetFallback(ledgerFallback(filepath.Join(dir, "watchtower.db")))
	llmusage.SetLogPath(filepath.Join(dir, "watchtower.log"))
}

// ledgerFallback inserts a call straight into the workspace database at
// dbPath when the spool cannot be written. The database is opened on the
// first use only, as an existing file with no migration (a process that
// never opens it never migrates it); a failed open is retried on the next
// call and its error makes Record write the loss line.
func ledgerFallback(dbPath string) func(llmusage.Call) error {
	var (
		mu       sync.Mutex
		database *db.DB
	)
	return func(c llmusage.Call) error {
		mu.Lock()
		defer mu.Unlock()
		if database == nil {
			d, err := db.OpenExistingRW(dbPath, ledgerFallbackBusy)
			if err != nil {
				return err
			}
			database = d
		}
		return database.InsertLLMCalls([]llmusage.Call{c})
	}
}
