package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/digest"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
	"watchtower/internal/streamline"
)

// maxStreamLine is the longest JSONL line Query decodes (streamline.MaxLine).
// A longer line — a tool item carrying a huge output — is read to its end
// and skipped, so the stream goes on and codex never blocks on a full pipe.
// A variable so tests can lower it.
var maxStreamLine = streamline.MaxLine

// messageSeparator goes between the text of two agent messages of one turn
// (the claude translator's separator).
const messageSeparator = "\n\n"

// errNoTurnCompleted fails a run that exited cleanly without turn.completed.
var errNoTurnCompleted = errors.New("codex exited without completing the turn")

// errNoAgentMessage fails a completed turn with no answer text (see
// queryStream.answerErr for the exception).
var errNoAgentMessage = errors.New("no agent_message found in codex output")

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
	// searchesPending are the web searches started without a query whose
	// step waits for it (tool); finish shows one never completed.
	searchesPending []string
	// anonymous numbers the ids given to items codex sent without one;
	// anonOpen lists the id-less tools started and not yet completed,
	// anonMsg the id-less agent message started and not yet completed.
	anonymous int
	anonOpen  []string
	anonMsg   string
	// skipped counts the lines over maxStreamLine, undecodable the lines
	// that are not a JSON event.
	skipped, undecodable int
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
		s.undecodable++
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
	s.noteUsage(event.Usage)
	item := event.Item
	switch {
	case item == nil:
		return true
	case item.Type == "mcp_tool_call" || item.Type == "command_execution" || item.Type == "web_search":
		if item.ID == "" {
			item.ID = s.anonTool(event.Type)
		}
		return s.tool(event.Type, item)
	case item.Type == "agent_message" && item.MessageText() != "":
		if item.ID == "" {
			item.ID = s.anonMessage(event.Type)
		}
		return s.message(item)
	}
	return true
}

// noteUsage adds an event's usage to the run's.
func (s *queryStream) noteUsage(u *CodexUsage) {
	if u == nil {
		return
	}
	if s.usage == nil {
		s.usage = &CodexUsage{}
	}
	s.usage.add(u)
}

// addUsage counts only the usage of a line the turn cap keeps from the
// consumer (the run is being stopped), so the ledger keeps codex's figures.
func (s *queryStream) addUsage(line []byte) {
	var event CodexEvent
	if json.Unmarshal(line, &event) == nil {
		s.noteUsage(event.Usage)
	}
}

// newAnon is a fresh per-run id for an item codex sent without one, so
// id-less tools stay separate steps and id-less messages stay separated.
func (s *queryStream) newAnon() string {
	s.anonymous++
	return "anon-" + strconv.Itoa(s.anonymous)
}

// anonMessage is the id of an id-less agent message's event: its stages up
// to item.completed share one id (no separator inside one message), and
// the next message gets a new one.
func (s *queryStream) anonMessage(eventType string) string {
	if s.anonMsg == "" {
		s.anonMsg = s.newAnon()
	}
	id := s.anonMsg
	if eventType == "item.completed" {
		s.anonMsg = ""
	}
	return id
}

// anonTool is the id of an id-less tool item's event: item.started opens a
// new one; item.updated and item.completed belong to the oldest open one,
// which item.completed closes (codex runs and reports tools in order). An
// update or completion with none open is a tool seen first there.
func (s *queryStream) anonTool(eventType string) string {
	switch {
	case eventType == "item.updated" && len(s.anonOpen) > 0:
		return s.anonOpen[0]
	case eventType == "item.completed" && len(s.anonOpen) > 0:
		id := s.anonOpen[0]
		s.anonOpen = s.anonOpen[1:]
		return id
	}
	id := s.newAnon()
	if eventType != "item.completed" {
		s.anonOpen = append(s.anonOpen, id)
	}
	return id
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
	if item.Type == "web_search" {
		// codex starts a search before it knows the query: the step starts
		// when the query is there, so it shows what was searched.
		if item.Query == "" && eventType != "item.completed" {
			if !slices.Contains(s.searchesPending, item.ID) {
				s.searchesPending = append(s.searchesPending, item.ID)
			}
			return true
		}
		s.searchesPending = slices.DeleteFunc(s.searchesPending, func(id string) bool { return id == item.ID })
	}
	if _, seen := s.toolsOpen[item.ID]; !seen {
		s.toolsOpen[item.ID] = true
		start := s.toolStart(item)
		s.toolOrder = append(s.toolOrder, ai.ToolEvent{ID: start.ID, Name: start.Name})
		if !s.send(ai.StreamChunk{Tool: start}) {
			s.toolsOpen[item.ID] = false // never shown: no end for it either
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
	distinct := s.lastMessage != "" && item.ID != s.lastMessage
	if distinct && s.answer.Len() > 0 && (s.v2 || !s.boundary) {
		text = messageSeparator + text
	}
	s.lastMessage = item.ID
	s.boundary = false
	s.answer.WriteString(text)
	return s.send(ai.StreamChunk{Text: text})
}

// flushGrace bounds the end of a stopped run's stream (queryStream.finish).
const flushGrace = time.Second

// finish ends the stream on every way a run's read ends — EOF, a read
// error, a stop: skipped and undecodable lines are logged (counts, never
// content); for a v2 consumer every tool still open gets a failed end — the
// owner stopped the turn, its result may have been in a line that could not
// be read, or codex stopped before reporting it — so no step stays running;
// then the turn's usage (the chat message's tokens; codex's input_tokens
// already count the cached ones). After a stop (the consumer's ctx ended)
// these sends get flushGrace in all instead of failing at once — a select on
// a closed ctx would drop them at random — so a consumer still draining the
// channel, as the chat does, gets them, and one that stopped reading holds
// the run at most that long.
func (s *queryStream) finish() {
	stopped := s.ctx.Err() != nil
	if stopped {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(s.ctx), flushGrace)
		defer cancel()
		s.ctx = ctx
	}
	if s.skipped > 0 {
		log.Printf("codex: skipped %d JSONL line(s) over %d bytes", s.skipped, maxStreamLine)
	}
	logUndecodable(s.undecodable)
	if !s.v2 {
		return
	}
	reason := "codex stopped before reporting this tool's result"
	switch {
	case stopped:
		reason = "stopped before the tool finished"
	case s.skipped > 0 || s.undecodable > 0:
		reason = "codex's report of this tool's result could not be read"
	}
	for _, id := range s.searchesPending {
		// A search that never reported its query is still shown, and closed.
		if s.send(ai.StreamChunk{Tool: &ai.ToolEvent{ID: id, Name: webSearchTool}}) {
			_ = s.send(ai.StreamChunk{Tool: &ai.ToolEvent{ID: id, Name: webSearchTool, Done: true, Result: reason}})
		}
	}
	s.searchesPending = nil
	for _, t := range s.toolOrder {
		if s.toolsOpen[t.ID] {
			s.toolsOpen[t.ID] = false
			_ = s.send(ai.StreamChunk{Tool: &ai.ToolEvent{ID: t.ID, Name: t.Name, Done: true, Result: reason}})
		}
	}
	if s.usage != nil {
		_ = s.send(ai.StreamChunk{Usage: &ai.TurnUsage{Model: s.model, Tokens: s.usage.tokens()}})
	}
}

// answerErr is the error of a completed turn that is no success, nil for
// one that is. A turn needs answer text — the rule QuerySync and the batch
// generator apply too — except, for a v2 consumer (the chat), a turn that
// ran tool steps: they are then the whole visible reply (an agent that only
// acted, as a Claude turn may end with an empty result). A v1 consumer shows
// text only, so for it an empty answer is never a blank "complete" one. With
// a line skipped as oversized or undecodable the empty answer fails even
// then: that line may have been the answer.
func (s *queryStream) answerErr() error {
	switch {
	case s.answer.Len() > 0:
		return nil
	case s.skipped > 0 || s.undecodable > 0:
		return providers.WithFailure("codex", providers.InvalidOutput,
			fmt.Errorf("%w (%d line(s) over %d bytes skipped, %d undecodable)", errNoAgentMessage, s.skipped, maxStreamLine, s.undecodable))
	case s.v2 && len(s.toolOrder) > 0:
		return nil
	}
	return providers.WithFailure("codex", providers.InvalidOutput, errNoAgentMessage)
}

// logUndecodable logs how many lines of codex's JSONL output were not a JSON
// event (a count, never content: FILES-01); nothing for none. A garbled
// turn.completed then explains an "exited without completing the turn".
func logUndecodable(n int) {
	if n > 0 {
		log.Printf("codex: %d undecodable JSONL line(s) ignored", n)
	}
}

// incompleteRunError is the error of a codex run that exited cleanly
// without turn.completed — the streaming Query, QuerySync and the batch
// generator alike — with what the run said about it: a failed turn in its
// JSONL events (classified as runError does); else codex's stderr, typed a
// transport failure when its last line reports codex's lost model stream
// (streamDisconnected; an earlier one was a retry codex recovered from) and
// otherwise left unclassified for the transport
// rules (digest.aiTransportFailure: a 5xx, 429 or login phrasing); else, with
// nothing said, an invalid-output failure.
func incompleteRunError(model string, jsonl []byte, stderr string) error {
	if turnErr := failedTurn(model, jsonl); turnErr != nil {
		return digest.WithCause(turnErr, errNoTurnCompleted)
	}
	if st := strings.TrimSpace(stderr); st != "" {
		err := logredact.Errorf("%w (stderr: %s)", errNoTurnCompleted, logredact.Text(st))
		if strings.Contains(strings.ToLower(lastLine(st)), streamDisconnected) {
			return providers.WithFailure("codex", providers.Transport, err)
		}
		return err
	}
	return providers.WithFailure("codex", providers.InvalidOutput, errNoTurnCompleted)
}

// lastLine is s's last line (s is trimmed, so the line is not empty).
func lastLine(s string) string {
	return s[strings.LastIndexByte(s, '\n')+1:]
}

// toolName is the item's tool name in the claude CLI's form, so the chat
// shows and summarises it the same way: mcp__watchtower__<tool> for the
// watchtower server whatever key it is mounted under, mcp__<server>__<tool>
// for another server, "shell" for a command, "WebSearch" for a web search.
func (s *queryStream) toolName(item *CodexItem) string {
	switch {
	case item.Type == "command_execution":
		return "shell"
	case item.Type == "web_search":
		return webSearchTool
	case s.watchtower != "" && item.Server == s.watchtower:
		return "mcp__watchtower__" + item.Tool
	}
	return "mcp__" + item.Server + "__" + item.Tool
}

func (s *queryStream) toolStart(item *CodexItem) *ai.ToolEvent {
	args := item.Arguments
	switch item.Type {
	case "command_execution":
		args, _ = json.Marshal(map[string]string{"command": item.Command})
	case "web_search":
		args = webSearchArgs(item)
	}
	return &ai.ToolEvent{ID: item.ID, Name: s.toolName(item), Args: args}
}

// webSearchTool is the name a web search step carries: Claude's WebSearch,
// so the chat summarises it and lists its pages the same way.
const webSearchTool = "WebSearch"

// webSearchArgs is a web_search item's query as the step's arguments; nil
// while codex has not said it.
func webSearchArgs(item *CodexItem) json.RawMessage {
	if item.Query == "" {
		return nil
	}
	args, _ := json.Marshal(map[string]string{"query": item.Query}) // strings only: never fails
	return args
}

// webSearchEnd is a finished web_search item's step end: failed with
// codex's error, or the pages found as Claude's WebSearch "Links:" line
// (chat.webSearchSources).
func webSearchEnd(ev *ai.ToolEvent, item *CodexItem) *ai.ToolEvent {
	if item.ToolError != nil || item.Status == "failed" {
		ev.Result = "the web search failed"
		if item.ToolError != nil && strings.TrimSpace(item.ToolError.Message) != "" {
			ev.Result = item.ToolError.Message
		}
		return ev
	}
	ev.OK = true
	links := make([]CodexWebResult, 0, len(item.Results))
	for _, r := range item.Results {
		if r.URL != "" {
			links = append(links, r)
		}
	}
	if len(links) == 0 {
		ev.Result = "No pages found"
		return ev
	}
	b, _ := json.Marshal(links) // strings only: never fails
	ev.Result = "Links: " + string(b)
	return ev
}

// toolEnd is the item's end: OK with its result text, or failed with the
// error (an MCP error, a failed or declined command, a non-zero exit) —
// never an empty reason.
func (s *queryStream) toolEnd(item *CodexItem) *ai.ToolEvent {
	ev := &ai.ToolEvent{ID: item.ID, Name: s.toolName(item), Done: true}
	if item.Type == "web_search" {
		return webSearchEnd(ev, item)
	}
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
