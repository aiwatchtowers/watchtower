package chat

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync"
)

// claudeLine is the union of the stream-json line shapes the translator reads.
type claudeLine struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	SessionID       string          `json:"session_id"`
	IsError         bool            `json:"is_error"`
	Result          string          `json:"result"`
	Usage           *claudeUsage    `json:"usage"`
	Event           *claudeStreamEv `json:"event"`
	Message         *claudeMessage  `json:"message"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
	Errors          []string        `json:"errors"`
}

type claudeUsage struct {
	InputTokens   int `json:"input_tokens"`
	OutputTokens  int `json:"output_tokens"`
	CacheRead     int `json:"cache_read_input_tokens"`
	CacheCreation int `json:"cache_creation_input_tokens"`
}

type claudeStreamEv struct {
	Type         string         `json:"type"`
	Index        int            `json:"index"`
	ContentBlock *claudeBlock   `json:"content_block"`
	Delta        *claudeDelta   `json:"delta"`
	Message      *claudeMessage `json:"message"`
}

type claudeBlock struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Name string `json:"name"`
}

type claudeDelta struct {
	Type        string `json:"type"`
	Text        string `json:"text"`
	PartialJSON string `json:"partial_json"`
}

type claudeMessage struct {
	Model   string          `json:"model"`
	Content json.RawMessage `json:"content"`
}

type claudeContent struct {
	Type      string          `json:"type"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

// blocks decodes the message content leniently: a plain-string content (or an
// unknown shape) yields no blocks rather than failing the line.
func (m *claudeMessage) blocks() []claudeContent {
	if m == nil || len(m.Content) == 0 {
		return nil
	}
	var out []claudeContent
	if err := json.Unmarshal(m.Content, &out); err != nil {
		return nil
	}
	return out
}

type pendingBlock struct {
	kind, id, name string
	args           strings.Builder
}

// ClaudeTranslator maps `claude --output-format stream-json
// --include-partial-messages` lines onto protocol-v2 events:
// text_delta per token, tool_start when a tool_use block closes (with its
// accumulated input JSON), tool_end per tool_result, usage + turn_done (or a
// turn error) per result. Thinking blocks, full assistant messages and
// subagent events are dropped. Safe for concurrent use: the backend feeds it
// from its reader goroutine and marks interrupts from Cancel.
type ClaudeTranslator struct {
	turnID func() string

	mu          sync.Mutex
	blocks      map[int]*pendingBlock
	toolNames   map[string]string // tool_use id → display name
	hidden      map[string]bool   // tool_use ids of Claude-internal tools
	model       string
	sessionID   string
	interrupted bool
	// textTurn is the turn id that last emitted text; newMessage records that
	// a new assistant message started since that text. Together they put a
	// paragraph break between the text of separate assistant messages of one
	// turn (text, tool call, more text) instead of gluing them together.
	textTurn   string
	newMessage bool
}

// NewClaudeTranslator returns a translator stamping events with turnID().
func NewClaudeTranslator(turnID func() string) *ClaudeTranslator {
	return &ClaudeTranslator{turnID: turnID, blocks: map[int]*pendingBlock{},
		toolNames: map[string]string{}, hidden: map[string]bool{}}
}

// MarkInterrupted records that an interrupt was requested for the running
// turn, so its error_during_execution result ends it as "interrupted".
func (t *ClaudeTranslator) MarkInterrupted() {
	t.mu.Lock()
	t.interrupted = true
	t.mu.Unlock()
}

// SessionID is the most recent Claude session id seen on any line.
func (t *ClaudeTranslator) SessionID() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sessionID
}

// Feed translates one stdout line. A blank line yields nothing; a line that
// is not JSON is an error the caller may log and skip.
func (t *ClaudeTranslator) Feed(line []byte) ([]Event, error) {
	evs, _, err := t.feed(line)
	return evs, err
}

// feed is Feed that also returns the session id the line itself carries
// ("" when it carries none) — the backend learns a fresh child's id from its
// first line, long before the turn's result reports it.
func (t *ClaudeTranslator) feed(line []byte) ([]Event, string, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, "", nil
	}
	var l claudeLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, "", fmt.Errorf("decoding claude stream line: %w", err)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if l.SessionID != "" {
		t.sessionID = l.SessionID
	}
	switch l.Type {
	case "stream_event":
		if l.Event == nil || (l.ParentToolUseID != nil && *l.ParentToolUseID != "") {
			return nil, l.SessionID, nil
		}
		return t.streamEvent(l.Event), l.SessionID, nil
	case "user":
		return t.toolResults(l.Message), l.SessionID, nil
	case "result":
		return t.result(l), l.SessionID, nil
	}
	return nil, l.SessionID, nil
}

func (t *ClaudeTranslator) streamEvent(ev *claudeStreamEv) []Event {
	switch ev.Type {
	case "message_start":
		t.blocks = map[int]*pendingBlock{}
		t.newMessage = true
		if ev.Message != nil && ev.Message.Model != "" {
			t.model = ev.Message.Model
		}
	case "content_block_start":
		if ev.ContentBlock != nil {
			t.blocks[ev.Index] = &pendingBlock{kind: ev.ContentBlock.Type, id: ev.ContentBlock.ID, name: ev.ContentBlock.Name}
		}
	case "content_block_delta":
		if ev.Delta == nil {
			return nil
		}
		switch ev.Delta.Type {
		case "text_delta":
			if ev.Delta.Text != "" {
				return []Event{{Type: EventTextDelta, TurnID: t.turnID(), Text: t.separated(ev.Delta.Text)}}
			}
		case "input_json_delta":
			if b := t.blocks[ev.Index]; b != nil {
				b.args.WriteString(ev.Delta.PartialJSON)
			}
		}
	case "content_block_stop":
		b := t.blocks[ev.Index]
		delete(t.blocks, ev.Index)
		return t.toolStart(b)
	}
	return nil
}

// messageSeparator goes between the text of two assistant messages of one turn.
const messageSeparator = "\n\n"

// separated prefixes text with messageSeparator when it is the first text of
// a later assistant message in a turn that already emitted text.
func (t *ClaudeTranslator) separated(text string) string {
	turn := t.turnID()
	sep := t.newMessage && t.textTurn == turn
	t.textTurn, t.newMessage = turn, false
	if sep {
		return messageSeparator + text
	}
	return text
}

// toolStart turns a closed tool_use block into a tool_start; any other block,
// or a Claude-internal tool, yields nothing.
func (t *ClaudeTranslator) toolStart(b *pendingBlock) []Event {
	if b == nil || b.kind != "tool_use" {
		return nil
	}
	if claudeInternalTools[b.name] {
		t.hidden[b.id] = true
		return nil
	}
	name := displayToolName(b.name)
	t.toolNames[b.id] = name
	return []Event{{Type: EventToolStart, TurnID: t.turnID(), ID: b.id, Name: name, Args: toolArgs(b.args.String())}}
}

func (t *ClaudeTranslator) toolResults(m *claudeMessage) []Event {
	var out []Event
	for _, c := range m.blocks() {
		if c.Type != "tool_result" {
			continue
		}
		if t.hidden[c.ToolUseID] {
			delete(t.hidden, c.ToolUseID)
			continue
		}
		text := toolResultText(c.Content)
		ok := !c.IsError
		var summary string
		var sources []Source
		if ok {
			summary, sources = SummarizeToolResult(t.toolNames[c.ToolUseID], text)
		} else {
			summary = truncateRunes(collapseSpace(text), SummaryMaxRunes)
		}
		out = append(out, Event{Type: EventToolEnd, TurnID: t.turnID(), ID: c.ToolUseID, OK: &ok,
			Summary: summary, Sources: sources})
	}
	return out
}

func (t *ClaudeTranslator) result(l claudeLine) []Event {
	turnID := t.turnID()
	interrupted := t.interrupted
	t.interrupted = false
	t.textTurn = "" // the turn is over: its successor starts without a break
	usage := Event{Type: EventUsage, TurnID: turnID, Model: t.model}
	if l.Usage != nil {
		usage.TokensIn = l.Usage.InputTokens + l.Usage.CacheRead + l.Usage.CacheCreation
		usage.TokensOut = l.Usage.OutputTokens
	}
	switch {
	case l.Subtype == "success" && !l.IsError:
		return []Event{usage, {Type: EventTurnDone, TurnID: turnID, Status: StatusComplete, SessionID: t.sessionID}}
	case interrupted:
		return []Event{usage, {Type: EventTurnDone, TurnID: turnID, Status: StatusInterrupted, SessionID: t.sessionID}}
	default:
		msg := strings.TrimSpace(l.Result)
		if msg == "" {
			// A failed start (e.g. a rejected --resume) carries its reason
			// only in "errors".
			msg = strings.TrimSpace(strings.Join(l.Errors, "; "))
		}
		if msg == "" {
			msg = "claude turn failed: " + l.Subtype
		}
		code, retry := ClassifyClaudeError(msg)
		return []Event{usage, errorEvent(turnID, code, msg, retry)}
	}
}

// claudeInternalTools are Claude Code's own plumbing tools (ToolSearch loads
// deferred MCP tool schemas). They are not steps the owner asked for, so they
// never surface as tool_start/tool_end. They stay allowed: hiding ToolSearch
// would leave the deferred watchtower tools unloadable.
var claudeInternalTools = map[string]bool{"ToolSearch": true}

// displayToolName strips the built-in server prefix and renders an external
// MCP tool as server:tool (spec §1.1).
func displayToolName(raw string) string {
	if n, ok := strings.CutPrefix(raw, "mcp__watchtower__"); ok {
		return n
	}
	if rest, ok := strings.CutPrefix(raw, "mcp__"); ok {
		if server, tool, ok := strings.Cut(rest, "__"); ok {
			return server + ":" + tool
		}
	}
	return raw
}

// toolArgs returns the accumulated tool input as JSON: {} when empty, the
// input itself when valid, otherwise {"_raw": "<text>"} so an event never
// carries invalid JSON.
func toolArgs(s string) json.RawMessage {
	s = strings.TrimSpace(s)
	if s == "" {
		return json.RawMessage(`{}`)
	}
	if json.Valid([]byte(s)) {
		return json.RawMessage(s)
	}
	b, _ := json.Marshal(map[string]string{"_raw": s})
	return b
}

// toolResultText flattens a tool_result's content: a string, or the text
// parts of a content-block array.
func toolResultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return ""
	}
	var b strings.Builder
	for _, p := range parts {
		if p.Type == "text" {
			b.WriteString(p.Text)
		}
	}
	return b.String()
}

var httpStatusRe = regexp.MustCompile(`\b(401|403|429|529)\b`)

// ClassifyClaudeError maps a provider error message onto a spec §5 code.
// Order matters: a rejected --resume is session_lost even if it also says
// "error"; an HTTP status is matched as a whole word so an issue key like
// PROJ-4291 is never mistaken for a 429.
func ClassifyClaudeError(msg string) (code string, retryable bool) {
	m := strings.ToLower(msg)
	status := httpStatusRe.FindString(m)
	switch {
	case containsAny(m, "no conversation found", "session not found", "could not find session"):
		return CodeSessionLost, false
	case status == "401" || status == "403" ||
		containsAny(m, "not logged in", "/login", "invalid api key", "authentication_error", "oauth token has expired"):
		return CodeAuth, false
	case status == "429" || status == "529" ||
		containsAny(m, "rate limit", "rate_limit", "usage limit", "overloaded"):
		return CodeRateLimit, true
	case containsAny(m, "executable file not found", "cli not found", "no such file or directory"):
		return CodeProviderUnavailable, true
	}
	return CodeInternal, true
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// clearInterrupted drops a pending interrupt mark. Called when a turn starts:
// a child killed after an interrupt never delivers the result that consumes
// the mark, and a stale mark would turn the next turn's error into
// "interrupted".
func (t *ClaudeTranslator) clearInterrupted() {
	t.mu.Lock()
	t.interrupted = false
	t.mu.Unlock()
}
