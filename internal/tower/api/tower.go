package api

// HelloRequest asks for the daemon's interface version and state (tower.hello).
type HelloRequest struct{}

// HelloResponse answers tower.hello.
type HelloResponse struct {
	// InterfaceVersion is the generated interface's version; a client built
	// against another one restarts the daemon or shows the mismatch.
	InterfaceVersion string `json:"interface_version"`
	// Build is the daemon's build string.
	Build string `json:"build"`
	// SyncPaused is true while the owner paused sync.
	SyncPaused bool `json:"sync_paused"`
	// NoSync is true when the daemon runs without syncing at all.
	NoSync bool `json:"no_sync"`
}

// PingRequest checks the daemon answers (tower.ping).
type PingRequest struct{}

// PingResponse answers tower.ping with the daemon's time (UTC, RFC 3339).
type PingResponse struct {
	At string `json:"at"`
}
