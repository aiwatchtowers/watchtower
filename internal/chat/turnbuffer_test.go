package chat

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func okPtr(v bool) *bool { return &v }

// TestTurnBuffer_KeepsTheWholeTurnUnderTheCap: under the cap a replay is
// the last session_ready and the turn's events verbatim; a new turn starts
// the buffer afresh.
func TestTurnBuffer_KeepsTheWholeTurnUnderTheCap(t *testing.T) {
	var b TurnBuffer
	b.Add(Event{Type: EventSessionReady, SessionID: "s1"})
	b.Add(Event{Type: EventTurnStart, TurnID: "t1"})
	b.Add(Event{Type: EventTextDelta, TurnID: "t1", Text: "old"})
	b.Add(Event{Type: EventTurnDone, TurnID: "t1", Status: StatusComplete})
	b.Add(Event{Type: EventSessionReady, SessionID: "s2"})
	b.Add(Event{Type: EventTurnStart, TurnID: "t2"})
	b.Add(Event{Type: EventTextDelta, TurnID: "t2", Text: "a"})
	b.Add(Event{Type: EventToolStart, TurnID: "t2", ID: "x"})
	b.Add(Event{Type: EventTextDelta, TurnID: "t2", Text: "b"})

	got := b.Replay()
	assert.Equal(t, []string{EventSessionReady, EventTurnStart, EventTextDelta, EventToolStart, EventTextDelta}, types(got))
	assert.Equal(t, "s2", got[0].SessionID)
	assert.Equal(t, "t2", b.TurnID())
}

// TestTurnBuffer_PastCapReplaysLatestTextAndEveryStep: past 600 KB of text
// the deltas fold into one delta of the whole text, placed before the
// turn's end; every step event is still there, in order.
func TestTurnBuffer_PastCapReplaysLatestTextAndEveryStep(t *testing.T) {
	var b TurnBuffer
	chunk := strings.Repeat("x", 64<<10)
	var whole strings.Builder
	b.Add(Event{Type: EventSessionReady, SessionID: "s1"})
	b.Add(Event{Type: EventTurnStart, TurnID: "t1"})
	for i := range 12 { // 768 KB
		b.Add(Event{Type: EventTextDelta, TurnID: "t1", Text: chunk})
		whole.WriteString(chunk)
		if i%4 == 0 {
			id := string(rune('a' + i))
			b.Add(Event{Type: EventToolStart, TurnID: "t1", ID: id})
			b.Add(Event{Type: EventToolEnd, TurnID: "t1", ID: id, OK: okPtr(true)})
		}
	}
	running := b.Replay()
	require.Equal(t, []string{EventSessionReady, EventTurnStart,
		EventToolStart, EventToolEnd, EventToolStart, EventToolEnd, EventToolStart, EventToolEnd,
		EventTextDelta}, types(running), "while it runs the snapshot is last")
	assert.Equal(t, whole.String(), running[len(running)-1].Text)

	b.Add(Event{Type: EventTextDelta, TurnID: "t1", Text: "tail"})
	whole.WriteString("tail")
	b.Add(Event{Type: EventTurnDone, TurnID: "t1", Status: StatusComplete})
	done := b.Replay()
	n := len(done)
	require.Equal(t, EventTurnDone, done[n-1].Type)
	require.Equal(t, EventTextDelta, done[n-2].Type, "the whole text comes before the end")
	assert.Equal(t, whole.String(), done[n-2].Text)
	deltas := 0
	for _, e := range done {
		if e.Type == EventTextDelta {
			deltas++
		}
	}
	assert.Equal(t, 1, deltas)
}
