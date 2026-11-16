package inboxfeed

import (
	"context"

	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// Register registers inbox.feed (the feed, a read) and inbox.watch (a
// watch: answers ok, then streams a changed event whenever one of
// ChangeTables may have changed, so the client reads the feed again).
func Register(r *tower.Registry) {
	tower.Register(r, "inbox.feed", func(ctx context.Context, c *tower.Ctx, req api.FeedRequest) (api.Feed, error) {
		return Build(ctx, c.DB, Options{Folder: req.Folder, Limit: req.Limit, Clip: req.Clip, Now: c.Now()})
	}, tower.Spec{Read: true, ChangeTables: ChangeTables})
	tower.Register(r, "inbox.watch", func(context.Context, *tower.Ctx, api.WatchRequest) (api.WatchResponse, error) {
		return api.WatchResponse{}, nil
	}, tower.Spec{Watch: true, ChangeTables: ChangeTables})
}
