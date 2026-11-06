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

	"watchtower/internal/llmusage"
	"watchtower/internal/providers"
)

// Protocol v2 event types (spec §1.1). There is deliberately no "reset":
// text already shown is never wiped (CHAT-02).
const (
	EventSessionReady = "session_ready"
	EventTurnStart    = "turn_start"
	EventTextDelta    = "text_delta"
	EventToolStart    = "tool_start"
	EventToolEnd      = "tool_end"
	// EventToolWait: a started tool call waits for the owner's Approve on
	// the agent_actions row ActionID (#737). Live only — the row is the
	// durable state; the step's tool_end follows (ok=false when rejected,
	// timed out or stopped).
	EventToolWait = "tool_wait"
	EventUsage    = "usage"
	EventTurnDone = "turn_done"
	EventError    = "error"
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
	// CodeWorkDirUnsafe: the chat's working folder is not private (a symlink
	// or another user's directory) — the owner must delete it.
	CodeWorkDirUnsafe = "workdir_unsafe"
)

// Commands read from stdin.
const (
	CommandTurn   = "turn"
	CommandCancel = "cancel"
	CommandClose  = "close"
)

// Event is one NDJSON line on the session's stdout.
type Event struct {
	// Cause retains a typed provider failure inside the host. It is deliberately
	// absent from protocol-v2 JSON; routing metadata is added by the chat adapter.
	Cause     error           `json:"-"`
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
	// FreshIn, CacheRead, CacheWrite (5 m + 1 h), CostUSD (the provider's
	// own) and Estimated are a usage event's split beside tokens_in, which
	// stays every input token (CHAT-01).
	FreshIn           int64    `json:"fresh_in,omitempty"`
	CacheRead         int64    `json:"cache_read,omitempty"`
	CacheWrite        int64    `json:"cache_write,omitempty"`
	CostUSD           *float64 `json:"cost_usd,omitempty"`
	Estimated         bool     `json:"estimated,omitempty"`
	Model             string   `json:"model,omitempty"`
	Provider          string   `json:"provider,omitempty"`
	SessionID         string   `json:"session_id,omitempty"`
	PreferredProvider string   `json:"preferred_provider,omitempty"`
	RoutingMode       string   `json:"routing_mode,omitempty"`
	Reason            string   `json:"reason,omitempty"`
	Status            string   `json:"status,omitempty"`
	Code              string   `json:"code,omitempty"`
	Message           string   `json:"message,omitempty"`
	Retryable         bool     `json:"retryable,omitempty"`
	ActionID          int64    `json:"action_id,omitempty"`
	// Capabilities is the actual provider's capability row on a
	// session_ready (EventWriter fills it from Provider): what this
	// session's transport offers, a fallback route's included.
	Capabilities *providers.Capabilities `json:"capabilities,omitempty"`
}

// usageEvent is turnID's usage event for model: tokens_in is every input
// token, the split rides beside it.
func usageEvent(turnID, model string, t llmusage.Tokens) Event {
	return Event{Type: EventUsage, TurnID: turnID, Model: model,
		TokensIn: int(t.AllInput()), TokensOut: int(t.Output),
		FreshIn: t.Input, CacheRead: t.CacheRead, CacheWrite: t.CacheWrite(),
		CostUSD: t.ReportedCostUSD, Estimated: t.Estimated}
}

// ToolWaitMessage is the waiting step's label.
const ToolWaitMessage = "Waiting for your approval"

// toolWaitEvent says the call toolUseID of turnID waits for the owner's
// decision on agent_actions row actionID.
func toolWaitEvent(turnID, toolUseID string, actionID int64) Event {
	return Event{Type: EventToolWait, TurnID: turnID, ID: toolUseID, ActionID: actionID, Message: ToolWaitMessage}
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

// SourceKindPublished marks the page or doc a turn published to the owner's
// claude.ai account; the Desktop renders it as a link card, only for an
// https://claude.ai/ URL.
const SourceKindPublished = "claude_ai_published"

// publishedSource is the source of a published artifact; Ref is its URL.
func publishedSource(url, title string) Source {
	return Source{Kind: SourceKindPublished, Title: title, URL: url, Ref: url}
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
	if e.Type == EventSessionReady && e.Provider != "" && e.Capabilities == nil {
		if c, ok := providers.CapsFor(e.Provider); ok {
			e.Capabilities = &c
		}
	}
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
