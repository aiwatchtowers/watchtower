package chat

import "strings"

// TurnBufferCap is how much of a turn's text a TurnBuffer keeps as the
// separate deltas it streamed (the feed record's cap, unified chat spec
// §7); past it the deltas are folded into one snapshot of the whole text.
const TurnBufferCap = 600 << 10

// TurnBuffer is what an `ai session --listen` keeps for the next attach
// (spec §7): its last session_ready and every event of its current turn,
// from the turn's first event. Past TurnBufferCap of text it keeps the
// turn's whole text as one snapshot plus every other event (each step), so
// a replay still writes the whole answer. A new turn id starts it afresh.
// Not safe for concurrent use (the EventWriter's lock guards it).
type TurnBuffer struct {
	ready  *Event
	turnID string
	events []Event
	text   strings.Builder
	folded bool // past the cap: the deltas are no longer kept one by one
}

// Add keeps ev.
func (b *TurnBuffer) Add(ev Event) {
	if ev.Type == EventSessionReady {
		e := ev
		b.ready = &e
		return
	}
	if ev.TurnID != "" && ev.TurnID != b.turnID {
		b.turnID, b.events, b.folded = ev.TurnID, nil, false
		b.text.Reset()
	}
	if ev.Type != EventTextDelta {
		b.events = append(b.events, ev)
		return
	}
	b.text.WriteString(ev.Text)
	switch {
	case b.folded:
	case b.text.Len() > TurnBufferCap:
		b.folded = true
		kept := b.events[:0]
		for _, e := range b.events {
			if e.Type != EventTextDelta {
				kept = append(kept, e)
			}
		}
		b.events = kept
	default:
		b.events = append(b.events, ev)
	}
}

// TurnID is the buffered turn's id ("" = none yet).
func (b *TurnBuffer) TurnID() string { return b.turnID }

// Replay is what an attach sends: the last session_ready, then the turn's
// events in order — past the cap with every delta replaced by one delta of
// the whole text, placed before the turn's end (or last while it runs).
func (b *TurnBuffer) Replay() []Event {
	out := make([]Event, 0, len(b.events)+2)
	if b.ready != nil {
		out = append(out, *b.ready)
	}
	if !b.folded {
		return append(out, b.events...)
	}
	snapshot := Event{Type: EventTextDelta, TurnID: b.turnID, Text: b.text.String()}
	placed := false
	for _, e := range b.events {
		if !placed && (e.Type == EventTurnDone || e.Type == EventError) { // an end, also a session-level error
			out = append(out, snapshot)
			placed = true
		}
		out = append(out, e)
	}
	if !placed {
		out = append(out, snapshot)
	}
	return out
}
