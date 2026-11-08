package config

import "context"

type routingSnapshotKey struct{}

// WithRoutingSnapshot binds immutable AI inputs for one logical job. Callers
// own the snapshot and must never mutate it after publication.
func WithRoutingSnapshot(ctx context.Context, cfg *Config) context.Context {
	return context.WithValue(ctx, routingSnapshotKey{}, cfg)
}

// RoutingSnapshot returns the job's AI inputs, or the host's startup inputs
// for callers outside a reloadable daemon.
func RoutingSnapshot(ctx context.Context, fallback *Config) *Config {
	if cfg, ok := ctx.Value(routingSnapshotKey{}).(*Config); ok {
		return cfg
	}
	return fallback
}
