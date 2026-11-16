// Package commands is the one place every package registers its tower
// commands, so the daemon socket, the hub and the generator see one table.
package commands

import (
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tower"
)

// Deps are what some commands need at call time. Its zero value is valid:
// the generator and tests register with it, and a command whose dependency is
// missing answers unsupported when called.
type Deps struct{}

// RegisterAll registers every tower command in r.
func RegisterAll(r *tower.Registry, _ Deps) {
	tower.RegisterBuiltins(r)
	tower.RegisterPause(r)
	inboxfeed.Register(r)
}
