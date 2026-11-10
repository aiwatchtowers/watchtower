package cloudkit

import (
	"context"
	"net"
	"time"
)

// SetPeerUID replaces c's peer-credential call (the Plan 1a peer seam).
func SetPeerUID(c *Client, f func(*net.UnixConn) (int, error)) { c.peerUID = f }

// SetSleep replaces s's backoff sleep.
func SetSleep(s *Supervisor, f func(context.Context, time.Duration) error) { s.sleep = f }
