package agentloop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode"

	"watchtower/internal/ai"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// messageSeparator starts a model message's text after the turn's earlier
// text, as claude and codex separate their messages.
const messageSeparator = "\n\n"

// maxStreamLine bounds one SSE line (a tool call's arguments can be long).
const maxStreamLine = 16 << 20

// textOut sends a turn's text to a streaming consumer (L7): each message's
// text as it arrives, a later message after a blank line. A v1 consumer
// wipes its text at a ToolBoundary, so after one nothing is shown and the
// next message starts without a separator; a v2 consumer (keep) never wipes.
// With a nil emit (the sync path) it sends nothing.
type textOut struct {
	emit      func(ai.StreamChunk)
	keep      bool // v2: a boundary leaves the consumer's text in place
	shown     bool // the consumer shows text of this turn
	inMessage bool // the current message has sent text
}

// startMessage opens the next model message.
func (o *textOut) startMessage() { o.inMessage = false }

// onText is the delta callback for a model call: nil on the sync path, so
// the request is not streamed.
func (o *textOut) onText() func(string) {
	if o.emit == nil {
		return nil
	}
	return o.send
}

// send sends a piece of the current message (a delta, or the whole text):
// the message's leading whitespace is dropped and its first piece carries
// the separator when the consumer already shows text.
func (o *textOut) send(s string) {
	if o.emit == nil {
		return
	}
	if !o.inMessage {
		s = strings.TrimLeftFunc(s, unicode.IsSpace)
		if s == "" {
			return
		}
		if o.shown {
			s = messageSeparator + s
		}
		o.inMessage = true
	}
	o.shown = true
	o.emit(ai.StreamChunk{Text: s})
}

// boundary marks a tool round; a v1 consumer drops the text it shows.
func (o *textOut) boundary() {
	if o.emit == nil {
		return
	}
	o.emit(ai.StreamChunk{ToolBoundary: true})
	if !o.keep {
		o.shown = false
	}
}

// jsonBody reports whether a 200 answer to a streaming request is one JSON
// body (a server that does not stream) rather than SSE: its first
// non-whitespace byte opens an object. A read error reports false, so
// readStream meets and types it.
func jsonBody(br *bufio.Reader) bool {
	for n := 1; ; n++ {
		b, err := br.Peek(n)
		if len(b) < n {
			return false
		}
		if c := b[n-1]; c != ' ' && c != '\t' && c != '\r' && c != '\n' {
			return c == '{'
		}
		if err != nil {
			return false
		}
	}
}

// Streaming wire types: the chat.completion.chunk subset the loop reads.
type oaStreamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

type oaStreamChunk struct {
	Choices []struct {
		Delta struct {
			Content   string            `json:"content"`
			ToolCalls []oaToolCallDelta `json:"tool_calls"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage *oaUsage       `json:"usage"`
	Error *oaStreamError `json:"error"`
}

type oaToolCallDelta struct {
	Index    *int       `json:"index"`
	ID       string     `json:"id"`
	Type     string     `json:"type"`
	Function oaFunction `json:"function"`
}

type oaStreamError struct {
	Message string `json:"message"`
	Type    string `json:"type"`
}

// streamMessage assembles one streamed assistant message.
type streamMessage struct {
	content strings.Builder
	calls   []oaToolCall
	byIndex map[int]int // a delta's index → position in calls
	choice  bool        // a choice was seen
	finish  string
}

// addToolCall merges one tool-call delta into its call.
func (m *streamMessage) addToolCall(d oaToolCallDelta) {
	c := &m.calls[m.callPos(d)]
	if d.ID != "" {
		c.ID = d.ID
	}
	if d.Type != "" {
		c.Type = d.Type
	}
	if c.Function.Name == "" {
		c.Function.Name = d.Function.Name
	}
	c.Function.Arguments += d.Function.Arguments
}

// callPos finds a delta's call: by its index when the server sends one, else
// the last call unless the delta opens a new one (an id); a delta that
// matches none opens a new call.
func (m *streamMessage) callPos(d oaToolCallDelta) int {
	if d.Index == nil {
		if d.ID == "" && len(m.calls) > 0 {
			return len(m.calls) - 1
		}
		m.calls = append(m.calls, oaToolCall{Type: "function"})
		return len(m.calls) - 1
	}
	if p, ok := m.byIndex[*d.Index]; ok && (d.ID == "" || m.calls[p].ID == "" || m.calls[p].ID == d.ID) {
		return p
	}
	if m.byIndex == nil {
		m.byIndex = map[int]int{}
	}
	m.calls = append(m.calls, oaToolCall{Type: "function"})
	m.byIndex[*d.Index] = len(m.calls) - 1
	return len(m.calls) - 1
}

// add takes one stream chunk: its usage into out, its deltas into the
// message (text passed on to onText). An error object in the stream is typed
// by its text; the text stays out of the error's log form (FILES-01).
func (m *streamMessage) add(ch *oaStreamChunk, out *oaResponse, onText func(string)) error {
	if e := ch.Error; e != nil {
		msg := strings.TrimSpace(e.Message)
		if e.Type != "" {
			msg += " (" + e.Type + ")"
		}
		return providers.OllamaFailure(0, msg, logredact.Errorf("model stream error: %s", logredact.Text(msg)))
	}
	if ch.Usage != nil {
		out.Usage = ch.Usage
	}
	for _, c := range ch.Choices {
		m.choice = true
		if c.FinishReason != "" {
			m.finish = c.FinishReason
		}
		for _, d := range c.Delta.ToolCalls {
			m.addToolCall(d)
		}
		if c.Delta.Content != "" {
			m.content.WriteString(c.Delta.Content)
			onText(c.Delta.Content)
		}
	}
	return nil
}

// readStream reads an SSE chat-completions stream into out, passing each
// text delta to onText as it arrives. The stream is complete at [DONE] or,
// at EOF, once a choice carried a finish_reason; one that ends with neither
// was cut short (Transport), or stopped (the context's error).
func readStream(ctx context.Context, br *bufio.Reader, out *oaResponse, onText func(string)) error {
	sc := bufio.NewScanner(br)
	sc.Buffer(make([]byte, 0, 64*1024), maxStreamLine)
	var m streamMessage
	done := false
	for !done && sc.Scan() {
		data, isData := strings.CutPrefix(sc.Text(), "data:")
		if !isData {
			continue // a blank separator, a comment or an event/id field
		}
		data = strings.TrimSpace(data)
		if data == "[DONE]" {
			done = true
			continue
		}
		var ch oaStreamChunk
		if json.Unmarshal([]byte(data), &ch) != nil {
			continue // not a chunk this loop reads (the ollama client's rule)
		}
		if err := m.add(&ch, out, onText); err != nil {
			return err
		}
	}
	if err := streamEnd(ctx, sc.Err(), done || m.finish != ""); err != nil {
		return err
	}
	if m.choice {
		out.Choices = []oaChoice{{
			Message:      oaMessage{Role: "assistant", Content: m.content.String(), ToolCalls: m.calls},
			FinishReason: m.finish,
		}}
	}
	return nil
}

// streamEnd types how a stream's read ended: a stop is the context's error,
// a read error is the request's failure, and a clean end that never
// completed was cut short (Transport). complete: [DONE] or a finish_reason
// was seen.
func streamEnd(ctx context.Context, readErr error, complete bool) error {
	switch {
	case ctx.Err() != nil && (readErr != nil || !complete):
		return providers.OllamaRequestFailure(fmt.Errorf("reading model stream: %w", ctx.Err()))
	case readErr != nil:
		return providers.OllamaRequestFailure(fmt.Errorf("reading model stream: %w", readErr))
	case !complete:
		return providers.WithFailure("ollama", providers.Transport,
			errors.New("model stream ended without [DONE] or a finish_reason (connection closed early)"))
	}
	return nil
}
