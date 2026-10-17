package automations

import "context"

// EventSource turns one sync phase into content-free events (spec §8): Before
// snapshots the phase's watermarks read-only before it runs, and the returned
// diff's After compares them with the watermarks the phase left behind. No
// transaction spans the phase.
type EventSource interface {
	// Type is the event type the source emits.
	Type() string
	Before(ctx context.Context) (EventDiff, error)
}

// EventDiff is one Before snapshot; After reads the post-phase state and
// returns the events the phase produced. Read-only.
type EventDiff interface {
	After(ctx context.Context) ([]Event, error)
}
