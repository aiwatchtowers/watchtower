package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEventWriter_OneJSONLinePerEventUnderConcurrency(t *testing.T) {
	var buf bytes.Buffer
	w := NewEventWriter(&buf)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			require.NoError(t, w.Emit(Event{Type: EventTextDelta, TurnID: "t1", Text: "chunk with\nnewline"}))
		}()
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
