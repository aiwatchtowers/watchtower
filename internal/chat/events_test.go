package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
)

func TestEventWriter_OneJSONLinePerEventUnderConcurrency(t *testing.T) {
	var buf bytes.Buffer
	w := NewEventWriter(&buf)
	var wg sync.WaitGroup
	for range 50 {
		wg.Go(func() {
			require.NoError(t, w.Emit(Event{Type: EventTextDelta, TurnID: "t1", Text: "chunk with\nnewline"}))
		})
	}
	wg.Wait()

	sc := bufio.NewScanner(&buf)
	n := 0
	for sc.Scan() {
		var e Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e), "every line is one complete JSON event")
		assert.Equal(t, "chunk with\nnewline", e.Text)
		n++
	}
	assert.Equal(t, 50, n)
}

func TestEvent_FalseOKIsSerialized(t *testing.T) {
	ok := false
	b, err := json.Marshal(Event{Type: EventToolEnd, TurnID: "t", ID: "x", OK: &ok})
	require.NoError(t, err)
	assert.Contains(t, string(b), `"ok":false`, "a failed step must reach Swift as ok:false, not as a missing field")
	assert.NotContains(t, string(b), `"text"`, "empty fields are omitted")
}

func TestCommand_DecodesSpecShape(t *testing.T) {
	var c Command
	require.NoError(t, json.Unmarshal([]byte(
		`{"type":"turn","turn_id":"u1","text":"hi","attachments":[{"path":"/abs/x.png","mime":"image/png","name":"x.png"}],"replay":true}`), &c))
	assert.Equal(t, Command{Type: CommandTurn, TurnID: "u1", Text: "hi",
		Attachments: []Attachment{{Path: "/abs/x.png", Mime: "image/png", Name: "x.png"}}, Replay: true}, c)
}

func TestRoutingProtocolV2FixtureUnknownFieldsAndPrivateCause(t *testing.T) {
	data, err := os.ReadFile("testdata/routing_v2.jsonl")
	require.NoError(t, err)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	n := 0
	for scanner.Scan() {
		var e Event
		require.NoError(t, json.Unmarshal(scanner.Bytes(), &e))
		require.Equal(t, "preferred_reserve", e.RoutingMode)
		e.Cause = errors.New("private provider failure")
		encoded, err := json.Marshal(e)
		require.NoError(t, err)
		require.JSONEq(t, string(scanner.Bytes()), string(encoded))
		require.NotContains(t, string(encoded), "private")
		var legacy struct {
			Type, Provider, Model, Message string
			Retryable                      bool
		}
		require.NoError(t, json.Unmarshal(encoded, &legacy))
		require.NotEmpty(t, legacy.Type)
		if e.Type == EventError {
			require.False(t, legacy.Retryable)
		}
		n++
	}
	require.NoError(t, scanner.Err())
	require.Equal(t, 3, n)
	var future Event
	require.NoError(t, json.Unmarshal([]byte(`{"type":"session_ready","routing_mode":"future_mode","future_field":true}`), &future))
	require.Equal(t, "future_mode", future.RoutingMode)
}

// A session_ready names what the actual provider's transport offers: the
// row of the provider that answers, a fallback route's included, so the
// Desktop decides nothing from a name (spec §3.3).
func TestSessionReady_CarriesActualProvidersCapabilities(t *testing.T) {
	var buf bytes.Buffer
	w := NewEventWriter(&buf)
	require.NoError(t, w.Emit(Event{Type: EventSessionReady, Provider: "claude", Model: "opus"}))
	// The router picked the reserve: the routed session_ready.
	for _, e := range ChunkEvents("t1", ai.StreamChunk{Routing: &ai.RoutingMetadata{Provider: "codex", Model: "m",
		PreferredProvider: "claude", Mode: "preferred_reserve", Reason: "quota"}}) {
		require.NoError(t, w.Emit(e))
	}
	require.NoError(t, w.Emit(Event{Type: EventTurnStart, TurnID: "t1"}))
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	require.Len(t, lines, 3)
	var first, routed, other struct {
		Capabilities *struct {
			ReservePeer string `json:"reserve_peer"`
			PDFs        bool   `json:"pdfs"`
		} `json:"capabilities"`
	}
	require.NoError(t, json.Unmarshal([]byte(lines[0]), &first))
	require.NoError(t, json.Unmarshal([]byte(lines[1]), &routed))
	require.NoError(t, json.Unmarshal([]byte(lines[2]), &other))
	require.NotNil(t, first.Capabilities)
	assert.Equal(t, "codex", first.Capabilities.ReservePeer)
	assert.True(t, first.Capabilities.PDFs)
	require.NotNil(t, routed.Capabilities, "the fallback route carries its own row")
	assert.Equal(t, "claude", routed.Capabilities.ReservePeer)
	assert.False(t, routed.Capabilities.PDFs)
	assert.Nil(t, other.Capabilities, "only session_ready carries the row")
}
