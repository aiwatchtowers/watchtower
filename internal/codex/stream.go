package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"strings"

	"watchtower/internal/ai"
)

// maxStreamLine is the longest JSONL line Query decodes (the claude warm
// reader's limit). A longer line — a tool item carrying a huge output — is
// read to its end and skipped, so the stream goes on and codex never blocks
// on a full pipe. A variable so tests can lower it.
var maxStreamLine = 64 << 20

// messageSeparator goes between the text of two agent messages of one turn
// (the claude translator's separator).
const messageSeparator = "\n\n"

// readStreamLine reads one line (with its newline, if any) from r. A line
// longer than limit is consumed and reported as oversized with no content.
// err is the reader's: io.EOF after the last line.
func readStreamLine(r *bufio.Reader, limit int) (line []byte, oversized bool, err error) {
	for {
		frag, err := r.ReadSlice('\n')
		if !oversized {
			if len(line)+len(frag) > limit {
				oversized, line = true, nil
			} else {
				line = append(line, frag...)
			}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return line, oversized, err
	}
}

// queryStream is one Query run's view of codex's JSONL events: what it
// streams to the consumer and what decides the run's outcome.
type queryStream struct {
	ctx   context.Context
	out   chan<- ai.StreamChunk
	model string
	// v2: the consumer switched the chat events on (EmitToolEvents): tool
	// starts/ends and the turn's usage are streamed, and agent messages are
	// always separated (protocol v2 never wipes text at a tool boundary).
	v2 bool

	usage  *CodexUsage
	answer strings.Builder
	// lastMessage is the id of the agent message last streamed; boundary
	// says a tool call came after it (a v1 consumer reset its text there).
	lastMessage string
	boundary    bool
	toolsOpen   map[string]bool
	// completed: codex reported turn.completed — the only successful end.
	completed bool

	// errLines are top-level "error" events, kept for runError: they explain
	// a run that exits non-zero without a turn.failed event. terminal is the
	// last turn failure.
	errLines []byte
	terminal error
}

// send streams c; false when ctx ended first.
func (s *queryStream) send(c ai.StreamChunk) bool {
	select {
	case s.out <- c:
		return true
	case <-s.ctx.Done():
		return false
	}
}

// handle processes one JSONL line; false when ctx ended while streaming.
func (s *queryStream) handle(line []byte) bool {
	var event CodexEvent
	if err := json.Unmarshal(line, &event); err != nil {
		return true
	}
	switch event.Type {
	case "turn.failed", "error":
		if event.Error != nil {
			s.terminal = eventTurnError(s.model, event.Error)
		}
	case "turn.started":
		s.terminal, s.errLines, s.completed = nil, nil, false
	case "turn.completed":
		s.terminal, s.errLines, s.completed = nil, nil, true
	}
	if event.Type == "error" {
		s.errLines = append(append(s.errLines, line...), '\n')
	}
	if event.Usage != nil {
		if s.usage == nil {
			s.usage = &CodexUsage{}
		}
		s.usage.add(event.Usage)
	}
	item := event.Item
	switch {
	case item == nil:
		return true
	case item.Type == "mcp_tool_call" || item.Type == "command_execution":
		return s.tool(event.Type, item)
	case item.Type == "agent_message" && item.MessageText() != "":
		return s.message(item)
	}
	return true
}

// tool streams a tool item. A tool call interrupts the turn: a boundary
// tells a v1 consumer to drop the pre-tool preamble and start the answer
// fresh from what follows (the ai.Client tool_use precedent). Codex wraps one
// item across item.started/updated/completed, so a single call fires a
// boundary per stage — idempotent, each extra boundary re-clears an empty
// accumulator. With the v2 events on, the item's start and end become one
// tool start/end pair.
func (s *queryStream) tool(eventType string, item *CodexItem) bool {
	s.boundary = true
	if !s.send(ai.StreamChunk{ToolBoundary: true}) {
		return false
	}
	if !s.v2 {
		return true
	}
	if s.toolsOpen == nil {
		s.toolsOpen = map[string]bool{}
	}
	if !s.toolsOpen[item.ID] {
		s.toolsOpen[item.ID] = true
		if !s.send(ai.StreamChunk{Tool: toolStart(item)}) {
			return false
		}
	}
	if eventType != "item.completed" {
		return true
	}
	return s.send(ai.StreamChunk{Tool: toolEnd(item)})
}

// message streams an agent message's text, separated from the turn's
// earlier message: always for a v2 consumer, and for a v1 one unless a tool
// boundary came between them (it reset its text there).
func (s *queryStream) message(item *CodexItem) bool {
	text := item.MessageText()
	distinct := s.lastMessage != "" && item.ID != "" && item.ID != s.lastMessage
	if distinct && s.answer.Len() > 0 && (s.v2 || !s.boundary) {
		text = messageSeparator + text
	}
	if item.ID != "" {
		s.lastMessage = item.ID
	}
	s.boundary = false
	s.answer.WriteString(text)
	return s.send(ai.StreamChunk{Text: text})
}

// sendUsage streams the turn's usage to a v2 consumer (the chat message's
// tokens). Codex's input_tokens already count the cached ones.
func (s *queryStream) sendUsage() {
	if !s.v2 || s.usage == nil {
		return
	}
	s.send(ai.StreamChunk{Usage: &ai.TurnUsage{Model: s.model,
		InputTokens: s.usage.InputTokens, OutputTokens: s.usage.OutputTokens}})
}

// toolName is the item's tool name in the claude CLI's form, so the chat
// shows and summarises it the same way: mcp__<server>__<tool> for an MCP
// call, "shell" for a command.
func toolName(item *CodexItem) string {
	if item.Type == "command_execution" {
		return "shell"
	}
	return "mcp__" + item.Server + "__" + item.Tool
}

func toolStart(item *CodexItem) *ai.ToolEvent {
	args := item.Arguments
	if item.Type == "command_execution" {
		args, _ = json.Marshal(map[string]string{"command": item.Command})
	}
	return &ai.ToolEvent{ID: item.ID, Name: toolName(item), Args: args}
}

// toolEnd is the item's end: OK with its result text, or failed with the
// error (an MCP error, a failed or declined command, a non-zero exit).
func toolEnd(item *CodexItem) *ai.ToolEvent {
	ev := &ai.ToolEvent{ID: item.ID, Name: toolName(item), Done: true}
	if item.Type == "command_execution" {
		ev.OK = item.Status == "completed" && (item.ExitCode == nil || *item.ExitCode == 0)
		ev.Result = item.AggregatedOutput
		return ev
	}
	if item.ToolError != nil {
		ev.Result = item.ToolError.Message
		return ev
	}
	ev.OK = item.Status != "failed"
	if item.Result != nil {
		var parts []string
		for _, c := range item.Result.Content {
			if c.Type == "text" {
				parts = append(parts, c.Text)
			}
		}
		ev.Result = strings.Join(parts, "\n")
	}
	return ev
}
