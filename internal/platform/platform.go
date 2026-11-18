// Package platform holds the operating-system specifics of local unix
// sockets every Watchtower server shares: who is at the other end of a
// connection (PeerUID, PeerPID: LOCAL_PEERCRED / LOCAL_PEERPID on darwin,
// SO_PEERCRED on linux, refused elsewhere) and one listener per socket path
// guarded by a <path>.lock flock (ListenLocked). It imports nothing of
// Watchtower, so the hub, the chat engine, the session host and the owner
// confirmation can all use it.
package platform

import "errors"

// errNoPeerPID: the kernel named no process at the other end.
var errNoPeerPID = errors.New("platform: socket peer: no peer pid")
