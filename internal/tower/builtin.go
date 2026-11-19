package tower

import (
	"context"
	"time"

	"watchtower/internal/tower/api"
)

// RegisterBuiltins registers tower.hello and tower.ping.
func RegisterBuiltins(r *Registry) {
	Register(r, "tower.hello", func(_ context.Context, c *Ctx, _ api.HelloRequest) (api.HelloResponse, error) {
		o := c.tower.opts
		return api.HelloResponse{
			InterfaceVersion: InterfaceVersion,
			Build:            o.Build,
			SyncPaused:       o.Paused != nil && o.Paused(),
			NoSync:           o.NoSync,
		}, nil
	}, Spec{Read: true})
	Register(r, "tower.ping", func(_ context.Context, c *Ctx, _ api.PingRequest) (api.PingResponse, error) {
		return api.PingResponse{At: c.Now().UTC().Format(time.RFC3339)}, nil
	}, Spec{Read: true})
}
