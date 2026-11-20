package cmd

import (
	"context"
	"errors"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/sessioncleanup"
	"watchtower/internal/sessionstart"
)

// sessionCleanupPass is the daemon's automatic session-cleanup pass (board
// #2131): sessioncleanup.AutoRun over the daemon's database, with the
// session host's live runs of this workspace (none when no host answers:
// nothing runs then) and the workbench cleanup lock taken without waiting.
func sessionCleanupPass(cfg *config.Config, database *db.DB, port *sessionstart.Port, logger *log.Logger) func(context.Context) {
	return func(ctx context.Context) {
		res, err := sessioncleanup.AutoRun(ctx, sessioncleanup.AutoDeps{
			Deps:       cleanupDeps(database),
			Candidates: database.FinishedSessionsForCleanup,
			Live: func(ctx context.Context) (map[int64]bool, error) {
				return liveRows(port.Runs(ctx))
			},
			TryLock: func(workbenchID int64) (func(), bool, error) {
				return fsutil.TryLockFile(sessioncleanup.LockPath(cfg.DBPath(), workbenchID)) //nolint:wrapcheck // names the lock file
			},
			Logf: logger.Printf,
		}, time.Now())
		switch {
		case err != nil:
			logger.Printf("session cleanup: %v", err)
		case res.Applied+res.Failed > 0:
			logger.Printf("session cleanup: %d session(s) cleaned up, %d failed", res.Applied, res.Failed)
		}
	}
}

// liveRows turns the port's live runs into the set of live rows; no host
// answering means none runs.
func liveRows(runs map[int64]time.Time, err error) (map[int64]bool, error) {
	if errors.Is(err, sessionstart.ErrHostNotRunning) {
		return map[int64]bool{}, nil
	}
	if err != nil {
		return nil, err //nolint:wrapcheck // AutoRun says what it was listing
	}
	live := make(map[int64]bool, len(runs))
	for id := range runs {
		live[id] = true
	}
	return live, nil
}
