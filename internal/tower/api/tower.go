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

// EventChanged is ChangedEvent.Event's one value.
const EventChanged = "changed"

// ChangedEvent is a frame a watch command streams after its ok answer, until
// the client closes the connection: data its command reads may have changed,
// so the client reads again. Tables lists the tables a write through
// tower.Call changed; it is empty when the data_version poll saw a write by
// another process, which cannot tell tables apart.
type ChangedEvent struct {
	// ID is the watch request's id.
	ID string `json:"id"`
	// Event is always "changed".
	Event  string   `json:"event"`
	Tables []string `json:"tables,omitempty"`
}

// PauseRequest asks to pause sync (sync.pause) or resume it (sync.resume).
type PauseRequest struct {
	WriteParams
}

// PauseResponse answers sync.pause and sync.resume with the owner's pause
// as it is after the call.
type PauseResponse struct {
	Paused bool `json:"paused"`
}
