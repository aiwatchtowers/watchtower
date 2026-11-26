package cmd

import (
	"context"
	"errors"
	"io/fs"
	"log"
	"syscall"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/sessioncleanup"
	"watchtower/internal/sessionstart"
)

// sessionCleanupPass is the daemon's automatic session-cleanup pass (board
// #2131): sessioncleanup.AutoRun over the daemon's database, with the
// session host's live runs of this workspace and each repository's cleanup
// lock only tried — the session applies, then the repository pass over the
// repositories of every workbench's folders (#2402). It logs a line only
// when a session's apply or a repository's pass removed something or
// failed, or the pass failed.
func sessionCleanupPass(cfg *config.Config, database *db.DB, port *sessionstart.Port, logger *log.Logger) func(context.Context) {
	return func(ctx context.Context) {
		res, err := sessioncleanup.AutoRun(ctx, sessioncleanup.AutoDeps{
			Deps:       cleanupDeps(database),
			Candidates: sessioncleanup.DBCandidates(database, time.Now),
			Live: func(ctx context.Context) (map[int64]bool, error) {
				return liveRows(port.Runs(ctx))
			},
			TryLock: func(repo string) (func(), bool, error) {
				return fsutil.TryLockFile(sessioncleanup.LockPath(cfg.DBPath(), repo)) //nolint:wrapcheck // names the lock file
			},
			Logf:        logger.Printf,
			Workbenches: sessioncleanup.DBWorkbenches(database),
		}, time.Now())
		if err != nil {
			logger.Printf("session cleanup: %v", err)
		}
		if res.Changed+res.Failed+res.RepoChanged+res.RepoFailed > 0 {
			logger.Printf("session cleanup: %d session(s) cleaned up, %d failed; %d repositor(ies) cleaned up, %d failed",
				res.Changed, res.Failed, res.RepoChanged, res.RepoFailed)
		}
	}
}

// liveRows turns the port's live runs into the set of live rows. Only a
// session host that is certainly not running — no socket file, or nothing
// listening on it — means no live run; any other failure (a handshake that
// timed out, a refused protocol) is an error, and the pass applies nothing.
func liveRows(runs map[int64]time.Time, err error) (map[int64]bool, error) {
	if errors.Is(err, sessionstart.ErrHostNotRunning) &&
		(errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED)) {
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
