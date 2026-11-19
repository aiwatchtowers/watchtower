// Package tower is the one interface every client reaches Watchtower's data
// through: a registry of named commands (domain.verb), an envelope, and a
// request ledger (tower_requests) that applies each write command once,
// whether it came over the daemon socket or through the hub. See
// docs/features/tower-interface.md.
package tower

import (
	"context"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

// Origin says where a call came from.
type Origin struct {
	Transport string // "socket" | "hub"
	Device    string
	// Desktop reports whether the caller is the signed Watchtower Desktop
	// (nil error), checked once per socket connection: the owner gestures
	// of AGENT-07 run over the socket only for it. nil (the hub, a test
	// without it) means no Desktop is known.
	Desktop func(ctx context.Context) error
}

// Options configure a Tower.
type Options struct {
	// Registry holds the commands; nil means none (every call is refused).
	Registry *Registry
	// Build is the daemon's build string, answered by tower.hello.
	Build string
	// Now is the clock; nil means time.Now.
	Now func() time.Time
	// Workspace is the workspace directory: sync.pause and sync.resume write
	// <Workspace>/sync.paused (pause.go). Empty refuses them.
	Workspace string
	// Paused reports whether the owner paused sync (tower.hello); nil means
	// IsPaused(Workspace), or never without a Workspace.
	Paused func() bool
	// NoSync is true when the daemon runs without syncing (tower.hello).
	NoSync bool
	// Changed is called with a command's Spec.ChangeTables after each of its
	// write transactions commits, never on a rollback.
	Changed func(tables []string)
	// Changes is the change watch a Watch command streams from (watch.go);
	// New wires Changed to also publish into it. nil refuses Watch commands.
	Changes *Changes
	// VerifyDesktop checks that the process image a socket peer's audit
	// token names is the signed Watchtower Desktop (the daemon passes
	// ownerconfirm.VerifyDesktopPeer, the chat socket's check); nil trusts no
	// peer as the Desktop, so the owner gestures are refused over the socket.
	VerifyDesktop func(ctx context.Context, peer ownerconfirm.PeerToken) error
	// Sentence words a handler's fault (not a refusal) for the refusal shown
	// to the owner; nil means a fixed sentence (FaultSentence), never the
	// error's own text.
	Sentence func(command string, err error) string
	// ReadDB is the handle Spec.Read commands run on (reads.go: OpenReads, a
	// read-only handle of its own, so a read never queues behind the
	// daemon's one-connection pool); nil means the write handle. Writes and
	// the ledger always use the write handle.
	ReadDB *db.DB
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
	if o.Paused == nil && o.Workspace != "" {
		ws := o.Workspace
		o.Paused = func() bool { return IsPaused(ws) }
	}
	if ch := o.Changes; ch != nil {
		changed := o.Changed
		o.Changed = func(tables []string) {
			ch.Publish(tables)
			if changed != nil {
				changed(tables)
			}
		}
	}
	return &Tower{db: d, opts: o}
}
