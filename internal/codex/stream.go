package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"strings"

	"watchtower/internal/ai"
	"watchtower/internal/digest"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// maxStreamLine is the longest JSONL line Query decodes (the claude warm
// reader's limit). A longer line — a tool item carrying a huge output — is
// read to its end and skipped, so the stream goes on and codex never blocks
// on a full pipe. A variable so tests can lower it.
var maxStreamLine = 64 << 20

// messageSeparator goes between the text of two agent messages of one turn
// (the claude translator's separator).
const messageSeparator = "\n\n"

// errNoTurnCompleted fails a run that exited cleanly without turn.completed.
var errNoTurnCompleted = errors.New("codex exited without completing the turn")

// readStreamLine reads one line (with its newline, if any) from r. A line
// longer than limit is consumed and reported as oversized with no content.
// err is the reader's: io.EOF after the last line. Unlike agentlog.NextLine,
// a last line without a newline is returned, not left unread: codex has
// exited by then and nothing will complete it.
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
	// watchtower is the key the watchtower server is mounted under
	// (watchtower-app when the owner's codex config has a watchtower).
	watchtower string

	usage  *CodexUsage
	answer strings.Builder
	// lastMessage is the id of the agent message last streamed; boundary
	// says a tool call came after it (a v1 consumer reset its text there).
	lastMessage string
	boundary    bool
	// toolsOpen: a started tool's id → still open; toolOrder lists the
	// started tools (id, name) in order, for closing the open ones.
	toolsOpen map[string]bool
	toolOrder []ai.ToolEvent
	// skipped counts the lines over maxStreamLine.
	skipped int
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
	case "error":
		s.errLines = append(append(s.errLines, line...), '\n')
		fallthrough
	case "turn.failed":
		if event.Error != nil {
			s.terminal = eventTurnError(s.model, event.Error)
		}
	case "turn.started":
		s.terminal, s.errLines, s.completed = nil, nil, false
	case "turn.completed":
		s.terminal, s.errLines, s.completed = nil, nil, true
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
	if _, seen := s.toolsOpen[item.ID]; !seen {
		s.toolsOpen[item.ID] = true
		start := s.toolStart(item)
		s.toolOrder = append(s.toolOrder, ai.ToolEvent{ID: start.ID, Name: start.Name})
		if !s.send(ai.StreamChunk{Tool: start}) {
			return false
		}
	}
	if eventType != "item.completed" || !s.toolsOpen[item.ID] {
		return true
	}
	s.toolsOpen[item.ID] = false
	return s.send(ai.StreamChunk{Tool: s.toolEnd(item)})
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

// finish ends the stream once codex's output is read: a skipped line is
// logged (a count, never content); for a v2 consumer every tool still open
// gets a failed end — its result was in a skipped line, or codex stopped
// before reporting it — so no step stays running; then the turn's usage
// (the chat message's tokens; codex's input_tokens already count the cached
// ones). A send cut by ctx needs no handling: the caller's Wait and
// outcome follow either way.
func (s *queryStream) finish() {
	if s.skipped > 0 {
		log.Printf("codex: skipped %d JSONL line(s) over %d bytes", s.skipped, maxStreamLine)
	}
	if !s.v2 {
		return
	}
	reason := "codex stopped before reporting this tool's result"
	if s.skipped > 0 {
		reason = "this tool's result was too large to show"
	}
	for _, t := range s.toolOrder {
		if s.toolsOpen[t.ID] {
			s.toolsOpen[t.ID] = false
			_ = s.send(ai.StreamChunk{Tool: &ai.ToolEvent{ID: t.ID, Name: t.Name, Done: true, Result: reason}})
		}
	}
	if s.usage != nil {
		_ = s.send(ai.StreamChunk{Usage: &ai.TurnUsage{Model: s.model,
			InputTokens: s.usage.InputTokens, OutputTokens: s.usage.OutputTokens}})
	}
}

// incompleteRunError is the error of a codex run that exited cleanly
// without turn.completed — the streaming Query, QuerySync and the batch
// generator alike — with what the run said about it: a failed turn in its
// JSONL events (classified as runError does); else codex's stderr, left
// unclassified so the transport rules (digest.aiTransportFailure) still read
// a "stream disconnected" or a 503 in it; else, with nothing said, an
// invalid-output failure.
func incompleteRunError(model string, jsonl []byte, stderr string) error {
	if turnErr := failedTurn(model, jsonl); turnErr != nil {
		return digest.WithCause(turnErr, errNoTurnCompleted)
	}
	if st := strings.TrimSpace(stderr); st != "" {
		return logredact.Errorf("%w (stderr: %s)", errNoTurnCompleted, logredact.Text(st))
	}
	return providers.WithFailure("codex", providers.InvalidOutput, errNoTurnCompleted)
}

// toolName is the item's tool name in the claude CLI's form, so the chat
// shows and summarises it the same way: mcp__watchtower__<tool> for the
// watchtower server whatever key it is mounted under, mcp__<server>__<tool>
// for another server, "shell" for a command.
func (s *queryStream) toolName(item *CodexItem) string {
	switch {
	case item.Type == "command_execution":
		return "shell"
	case s.watchtower != "" && item.Server == s.watchtower:
		return "mcp__watchtower__" + item.Tool
	}
	return "mcp__" + item.Server + "__" + item.Tool
}

func (s *queryStream) toolStart(item *CodexItem) *ai.ToolEvent {
	args := item.Arguments
	if item.Type == "command_execution" {
		args, _ = json.Marshal(map[string]string{"command": item.Command})
	}
	return &ai.ToolEvent{ID: item.ID, Name: s.toolName(item), Args: args}
}

// toolEnd is the item's end: OK with its result text, or failed with the
// error (an MCP error, a failed or declined command, a non-zero exit) —
// never an empty reason.
func (s *queryStream) toolEnd(item *CodexItem) *ai.ToolEvent {
	ev := &ai.ToolEvent{ID: item.ID, Name: s.toolName(item), Done: true}
	if item.Type == "command_execution" {
		ev.OK = item.Status == "completed" && (item.ExitCode == nil || *item.ExitCode == 0)
		ev.Result = item.AggregatedOutput
		switch {
		case ev.OK || strings.TrimSpace(ev.Result) != "":
		case item.Status == "declined":
			ev.Result = "the command was declined"
		case item.ExitCode != nil:
			ev.Result = "the command exited with code " + strconv.Itoa(*item.ExitCode)
		default:
			ev.Result = "the command failed"
		}
		return ev
	}
	if item.ToolError != nil {
		ev.Result = item.ToolError.Message
		if strings.TrimSpace(ev.Result) == "" {
			ev.Result = "the tool failed"
		}
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
	if !ev.OK && strings.TrimSpace(ev.Result) == "" {
		// A failed call codex reported with no error and no result text.
		ev.Result = "the tool failed"
	}
	return ev
}
