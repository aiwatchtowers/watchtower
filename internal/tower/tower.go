// Package tower is the one interface every client reaches Watchtower's data
// through: a registry of named commands (domain.verb), an envelope, and a
// request ledger (tower_requests) that applies each write command once,
// whether it came over the daemon socket or through the hub. See
// docs/features/tower-interface.md.
package tower

import (
	"time"

	"watchtower/internal/db"
)

// InterfaceVersion is the version of the generated interface, answered by
// tower.hello. Task 2's generator replaces it with a generated constant.
var InterfaceVersion = "dev"

// Origin says where a call came from.
type Origin struct {
	Transport string // "socket" | "hub"
	Device    string
}

// Options configure a Tower.
type Options struct {
	// Registry holds the commands; nil means none (every call is refused).
	Registry *Registry
	// Build is the daemon's build string, answered by tower.hello.
	Build string
	// Now is the clock; nil means time.Now.
	Now func() time.Time
	// Paused reports whether sync is paused (tower.hello); nil means never.
	Paused func() bool
	// NoSync is true when the daemon runs without syncing (tower.hello).
	NoSync bool
	// Changed is called with a command's Spec.ChangeTables after each of its
	// write transactions commits, never on a rollback.
	Changed func(tables []string)
	// Sentence words a handler's fault (not a refusal) for the refusal shown
	// to the owner; nil means the error's text.
	Sentence func(command string, err error) string
}

// Tower runs commands against one database.
type Tower struct {
	db   *db.DB
	opts Options
}

// New returns a Tower over d.
func New(d *db.DB, o Options) *Tower {
	if o.Registry == nil {
		o.Registry = &Registry{}
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &Tower{db: d, opts: o}
}
