// Package commands is the one place every package registers its tower
// commands, so the daemon socket, the hub and the generator see one table.
package commands

import (
	"watchtower/internal/chatstore"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tower"
)

// Deps are what some commands need at call time. Its zero value is valid:
// the generator and tests register with it, and a command whose dependency is
// missing answers unsupported when called.
type Deps struct {
	// DisabledFeatures returns the feature registry ids the config has off
	// now (inbox.feed reads attention detection's switch from it); nil
	// means none.
	DisabledFeatures func() []string
	// Act is what inbox.act needs (the tools registry, Run Now, the
	// executor's wake, the hub's Background); a missing one answers
	// unsupported for the verbs that need it.
	Act inboxfeed.ActDeps
}

// RegisterAll registers every tower command in r.
func RegisterAll(r *tower.Registry, d Deps) {
	tower.RegisterBuiltins(r)
	tower.RegisterPause(r)
	inboxfeed.Register(r, d.DisabledFeatures)
	inboxfeed.RegisterAct(r, d.Act)
	inboxfeed.RegisterScreens(r, d.Act)
	// Stage 3: the conversation-level chat writes (chat.*).
	chatstore.RegisterCommands(r)
}
