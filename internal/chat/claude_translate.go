package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
)

// claudeLine is the union of the stream-json line shapes the translator reads.
type claudeLine struct {
	Type      string       `json:"type"`
	Subtype   string       `json:"subtype"`
	SessionID string       `json:"session_id"`
	IsError   bool         `json:"is_error"`
	Result    string       `json:"result"`
	Usage     *claudeUsage `json:"usage"`
	// CostUSD and ModelUsage are a result line's reported cost and
	// per-model usage (the LLM usage ledger's numbers).
	CostUSD    float64                    `json:"total_cost_usd"`
	ModelUsage map[string]json.RawMessage `json:"modelUsage"`
	Event      *claudeStreamEv            `json:"event"`
	// Message is a user line's message object; other lines may carry a
	// string "message" (system/permission_denied), so it is decoded only
	// for "user".
	Message         json.RawMessage `json:"message"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
	Errors          []string        `json:"errors"`
	// APIKeySource is the init event's auth source: "none" under the
	// claude.ai login (probe answer 9).
	APIKeySource string `json:"apiKeySource"`
}

type claudeUsage struct {
	InputTokens   int `json:"input_tokens"`
	OutputTokens  int `json:"output_tokens"`
	CacheRead     int `json:"cache_read_input_tokens"`
	CacheCreation int `json:"cache_creation_input_tokens"`
	// CacheCreationTTL splits CacheCreation by cache TTL.
	CacheCreationTTL struct {
		FiveMin int `json:"ephemeral_5m_input_tokens"`
		OneHour int `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`
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

// toolCall is a started tool call's raw CLI name and input.
type toolCall struct {
	raw  string
	args json.RawMessage
}

// toolResult is one tool_result a line carried, for the permission gate,
// which records the outcome of a call it let run (FinishCall).
type toolResult struct {
	toolUseID, text string
	isError         bool
	// newLink is the link of a page or doc this call published fresh (not
	// an update of a link its input named): the gate counts it as the
	// session's own unless the call ran only after the owner's Approve.
	newLink string
}

// fedLine is what one stdout line translates to: its events, the session id
// the line itself carries ("" when none) and its tool results.
type fedLine struct {
	events    []Event
	sessionID string
	results   []toolResult
	// init marks a system/init line; apiKeySource is its auth source ("" when
	// the line has none).
	init         bool
	apiKeySource string
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
	toolNames   map[string]string   // tool_use id → display name
	calls       map[string]toolCall // tool_use id → raw name and input, until its result
	hidden      map[string]bool     // tool_use ids of Claude-internal tools
	model       string
	sessionID   string
	interrupted bool
	// turnStart is when the first line after the previous result arrived:
	// the start of the turn the next result ends, for the ledger's duration.
	turnStart time.Time
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
		toolNames: map[string]string{}, calls: map[string]toolCall{}, hidden: map[string]bool{}}
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
	f, err := t.feed(line)
	return f.events, err
}

// feed is Feed that also returns the session id the line itself carries —
// the backend learns a fresh child's id from its first line, long before the
// turn's result reports it — and the line's tool results.
func (t *ClaudeTranslator) feed(line []byte) (fedLine, error) {
	f, call, err := t.translate(line)
	if call != nil {
		// Outside the lock: the record is a file append.
		recordTurn(*call)
	}
	return f, err
}

// translate is feed under the lock; a result line also returns its ledger
// call, which feed records.
func (t *ClaudeTranslator) translate(line []byte) (fedLine, *llmusage.Call, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return fedLine{}, nil, nil
	}
	var l claudeLine
	if err := json.Unmarshal(line, &l); err != nil {
		return fedLine{}, nil, fmt.Errorf("decoding claude stream line: %w", err)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.turnStart.IsZero() {
		t.turnStart = time.Now()
	}
	var call *llmusage.Call
	if l.SessionID != "" {
		t.sessionID = l.SessionID
	}
	f := fedLine{sessionID: l.SessionID}
	switch l.Type {
	case "stream_event":
		if l.Event != nil && (l.ParentToolUseID == nil || *l.ParentToolUseID == "") {
			f.events = t.streamEvent(l.Event)
		}
	case "user":
		var m *claudeMessage
		if l.Message != nil {
			if err := json.Unmarshal(l.Message, &m); err != nil {
				return f, nil, fmt.Errorf("decoding claude user message: %w", err)
			}
		}
		f.events, f.results = t.toolResults(m)
	case "result":
		f.events = t.result(l)
		c := t.usageCall(l)
		call = &c
	case "system":
		if l.Subtype == "init" {
			f.init, f.apiKeySource = true, l.APIKeySource
		}
	}
	return f, call, nil
}

// usageCall is the ledger call a result line ends: the turn's usage with
// the cache split and reported cost, estimated (from the result text) when
// the line carries no usage. It starts the next turn's clock.
func (t *ClaudeTranslator) usageCall(l claudeLine) llmusage.Call {
	c := llmusage.Call{
		Provider:   "claude",
		Model:      digest.ModelFromUsage(l.ModelUsage, t.model),
		DurationMS: time.Since(t.turnStart).Milliseconds(),
		OK:         l.Subtype == "success" && !l.IsError,
	}
	t.turnStart = time.Time{}
	if l.CostUSD > 0 {
		cost := l.CostUSD
		c.ReportedCostUSD = &cost
	}
	u := l.Usage
	if u == nil || u.InputTokens+u.OutputTokens+u.CacheRead+u.CacheCreation == 0 {
		c.Estimated = true
		c.Output = llmusage.EstimateTokens(l.Result)
		return c
	}
	c.Input, c.CacheRead, c.Output = int64(u.InputTokens), int64(u.CacheRead), int64(u.OutputTokens)
	c.CacheWrite5m, c.CacheWrite1h = int64(u.CacheCreationTTL.FiveMin), int64(u.CacheCreationTTL.OneHour)
	if rest := int64(u.CacheCreation) - c.CacheWrite5m - c.CacheWrite1h; rest > 0 {
		// A total the CLI did not split counts at its default 5-minute TTL.
		c.CacheWrite5m += rest
	}
	return c
}

// recordTurn records one chat turn's call in the LLM usage ledger; the
// session's surface and purpose come from the process (ai session).
func recordTurn(c llmusage.Call) {
	llmusage.Record(context.Background(), c)
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
	args := toolArgs(b.args.String())
	t.calls[b.id] = toolCall{raw: b.name, args: args}
	return []Event{{Type: EventToolStart, TurnID: t.turnID(), ID: b.id, Name: name, Args: args}}
}

func (t *ClaudeTranslator) toolResults(m *claudeMessage) ([]Event, []toolResult) {
	var out []Event
	var results []toolResult
	for _, c := range m.blocks() {
		if c.Type != "tool_result" {
			continue
		}
		if t.hidden[c.ToolUseID] {
			delete(t.hidden, c.ToolUseID)
			continue
		}
		text := toolResultText(c.Content)
		call := t.calls[c.ToolUseID]
		delete(t.calls, c.ToolUseID)
		ok := !c.IsError
		res := toolResult{toolUseID: c.ToolUseID, text: text, isError: c.IsError}
		var summary string
		var sources []Source
		switch src, fresh, published := publishedLink(call, text); {
		case ok && published:
			summary, sources = truncateRunes("Published "+src.Title, SummaryMaxRunes), []Source{src}
			if fresh {
				res.newLink = src.URL
			}
		case ok:
			summary, sources = SummarizeToolResult(t.toolNames[c.ToolUseID], text)
		default:
			summary = truncateRunes(collapseSpace(text), SummaryMaxRunes)
		}
		results = append(results, res)
		out = append(out, Event{Type: EventToolEnd, TurnID: t.turnID(), ID: c.ToolUseID, OK: &ok,
			Summary: summary, Sources: sources})
	}
	return out, results
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

// claudeAIArtifactURL matches a claude.ai page or doc link: scheme https,
// host exactly claude.ai (the Desktop renders a link card for nothing else).
var claudeAIArtifactURL = regexp.MustCompile(`https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+`)

// claudeDocsBatchTool is the Claude Docs tool that births a doc.
const claudeDocsBatchTool = "mcp__claude_ai_Claude_Docs__batch"

// publishedLink returns the link card of a successful Artifact publish or a
// Claude Docs batch that created a doc: the first claude.ai link in the
// result whose id the call's input never mentions (fresh) — a new page's id
// cannot be in it, while a link the model wrote into the page or doc can,
// and the session must never take such a link for one it published
// (gate.noteOwn). An Artifact update of the link its input names keeps that
// link (not fresh).
func publishedLink(call toolCall, result string) (src Source, fresh, ok bool) {
	title, update, ok := publishTitle(call)
	if !ok {
		return Source{}, false, false
	}
	mentioned := inputText(call.args)
	for _, link := range claudeAIArtifactURL.FindAllString(result, -1) {
		if id := artifactID(link); id != "" && !strings.Contains(mentioned, strings.ToLower(id)) {
			return publishedSource(link, title), true, true
		}
	}
	if update != "" && claudeAIArtifactURL.FindString(update) == update && strings.Contains(result, artifactID(update)) {
		return publishedSource(update, title), false, true
	}
	return Source{}, false, false
}

// publishTitle is the card title of a call that publishes — an Artifact
// publish (update = the url it names) or a Claude Docs batch that creates a
// doc; false for any other call.
func publishTitle(call toolCall) (title, update string, ok bool) {
	in, ok := decodeObject(call.args)
	if !ok {
		return "", "", false
	}
	switch call.raw {
	case "Artifact":
		if action := in.str("action"); (action != "" && action != "publish") || string(in["asset"]) == "true" {
			return "", "", false
		}
		title, update = in.str("title"), in.str("url")
		if path := in.str("file_path"); title == "" && path != "" {
			title = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		}
		if title == "" {
			title = "claude.ai page"
		}
		return title, update, true
	case claudeDocsBatchTool:
		container, _ := decodeObject(in["container"])
		create, ok := decodeObject(container["create"])
		if !ok {
			return "", "", false
		}
		if title = create.str("name"); title == "" {
			title = "claude.ai doc"
		}
		return title, "", true
	}
	return "", "", false
}

// inputText is everything a tool input says, lower-cased: its raw bytes and
// every key and string value decoded (so a \u escape or another case hides
// nothing). An id found in it is not a fresh one.
func inputText(args json.RawMessage) string {
	var b strings.Builder
	b.Write(args)
	var walk func(v any)
	walk = func(v any) {
		switch t := v.(type) {
		case string:
			b.WriteString("\x00" + t)
		case map[string]any:
			for k, val := range t {
				b.WriteString("\x00" + k)
				walk(val)
			}
		case []any:
			for _, val := range t {
				walk(val)
			}
		}
	}
	var v any
	if json.Unmarshal(args, &v) == nil {
		walk(v)
	}
	return strings.ToLower(b.String())
}

// uuidSuffix is a UUID at the end of a link segment.
var uuidSuffix = regexp.MustCompile(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// artifactShortIDLen is the length of a claude.ai artifact's short id.
const artifactShortIDLen = 22

// artifactID returns the id a claude.ai page or doc is known by: a bare id
// as given (a UUID lower-cased), or the id a https://claude.ai/[code/]artifact/
// [<title>-]<id> link ends with — a UUID, or the last 22 characters after
// the title's "-". "" for a link to anywhere else.
func artifactID(s string) string {
	s = strings.TrimSpace(s)
	if !strings.Contains(s, "/") {
		if uuidSuffix.MatchString(s) && len(s) == 36 {
			return strings.ToLower(s)
		}
		return s
	}
	if !strings.HasPrefix(s, "https://claude.ai/") {
		return ""
	}
	_, seg, ok := strings.Cut(s, "/artifact/")
	if !ok {
		return ""
	}
	if i := strings.IndexAny(seg, "/?#"); i >= 0 {
		seg = seg[:i]
	}
	if m := uuidSuffix.FindString(seg); m != "" {
		return strings.ToLower(m)
	}
	if n := len(seg); n > artifactShortIDLen && seg[n-artifactShortIDLen-1] == '-' {
		return seg[n-artifactShortIDLen:]
	}
	return seg
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
