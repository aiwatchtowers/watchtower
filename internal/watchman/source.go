package watchman

import (
	"context"

	"watchtower/internal/db"
)

// Source reads one kind of owner decision for one workbench, newest first, resumable by an opaque cursor ("" = nothing seen yet).
type Source interface {
	Name() string
	Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) (ps []db.WatchmanPrecedent, next string, done bool, err error)
}
