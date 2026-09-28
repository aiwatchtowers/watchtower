// Package chat is the main AI Chat's engine: the protocol-v2 events a
// `watchtower ai session` process streams to the Desktop app, the translator
// from Claude's stream-json into those events, the system prompt, the replay
// transcript, and the session loop with its provider backends.
package chat

import (
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// Protocol v2 event types (spec §1.1). There is deliberately no "reset":
// text already shown is never wiped (CHAT-02).
const (
	EventSessionReady = "session_ready"
	EventTurnStart    = "turn_start"
	EventTextDelta    = "text_delta"
	EventToolStart    = "tool_start"
	EventToolEnd      = "tool_end"
	EventUsage        = "usage"
	EventTurnDone     = "turn_done"
	EventError        = "error"
)

// turn_done statuses.
const (
	StatusComplete    = "complete"
	StatusInterrupted = "interrupted"
)

// Error codes (spec §5).
const (
	CodeAuth                  = "auth"
	CodeRateLimit             = "rate_limit"
	CodeProviderUnavailable   = "provider_unavailable"
	CodeSessionLost           = "session_lost"
	CodeAttachmentUnsupported = "attachment_unsupported"
	CodeInterrupted           = "interrupted"
	CodeInternal              = "internal"
)

// Commands read from stdin.
const (
	CommandTurn   = "turn"
	CommandCancel = "cancel"
	CommandClose  = "close"
)

// Event is one NDJSON line on the session's stdout.
type Event struct {
	Type      string          `json:"type"`
	TurnID    string          `json:"turn_id,omitempty"`
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Args      json.RawMessage `json:"args,omitempty"`
	OK        *bool           `json:"ok,omitempty"`
	Summary   string          `json:"summary,omitempty"`
	Sources   []Source        `json:"sources,omitempty"`
	TokensIn  int             `json:"tokens_in,omitempty"`
	TokensOut int             `json:"tokens_out,omitempty"`
	Model     string          `json:"model,omitempty"`
	Provider  string          `json:"provider,omitempty"`
	SessionID string          `json:"session_id,omitempty"`
	Status    string          `json:"status,omitempty"`
	Code      string          `json:"code,omitempty"`
	Message   string          `json:"message,omitempty"`
	Retryable bool            `json:"retryable,omitempty"`
}

// Source is one cited source of a tool_end (spec §3.4). Group, Snippet and
// Date are optional presentation hints for the Desktop sources panel — Group
// is what the panel groups by ("#channel", a Jira project key, "Mail",
// "Meetings"; empty = "Other"), Snippet a short excerpt, Date a YYYY-MM-DD
// day. All three are omitempty, so sources persisted before they existed
// still decode (the Desktop derives a group from a legacy title).
type Source struct {
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	URL     string `json:"url,omitempty"`
	Ref     string `json:"ref"`
	Group   string `json:"group,omitempty"`
	Snippet string `json:"snippet,omitempty"`
	Date    string `json:"date,omitempty"`
}

// Attachment is a file the owner attached to a turn. Its path travels on
// stdin inside the turn command, never on argv (CHAT-04).
type Attachment struct {
	Path string `json:"path"`
	Mime string `json:"mime"`
	Name string `json:"name"`
}

// Command is one JSONL line on the session's stdin.
type Command struct {
	Type        string       `json:"type"`
	TurnID      string       `json:"turn_id,omitempty"`
	Text        string       `json:"text,omitempty"`
	Attachments []Attachment `json:"attachments,omitempty"`
	Replay      bool         `json:"replay,omitempty"`
}

// errorEvent builds an error event. A non-empty turnID makes it the turn's
// terminal event.
func errorEvent(turnID, code, msg string, retryable bool) Event {
	return Event{Type: EventError, TurnID: turnID, Code: code, Message: msg, Retryable: retryable}
}

// isTerminal reports whether e ends its turn: every turn ends with exactly one
// turn_done or one turn-scoped error.
func isTerminal(e Event) bool {
	return e.Type == EventTurnDone || (e.Type == EventError && e.TurnID != "")
}

// EventWriter writes events as NDJSON, one line per event. Safe for
// concurrent use; each event is a single Write, so lines never interleave.
type EventWriter struct {
	mu sync.Mutex
	w  io.Writer
}

// NewEventWriter wraps w.
func NewEventWriter(w io.Writer) *EventWriter { return &EventWriter{w: w} }

// Emit writes one event line.
func (w *EventWriter) Emit(e Event) error {
	b, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("encoding %s event: %w", e.Type, err)
	}
	b = append(b, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	_, err = w.w.Write(b)
	return err
}
