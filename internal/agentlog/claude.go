package agentlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"

	"watchtower/internal/agentlogdb"
)

// ParserVersion is stamped on agent_log_files; bump it when parsing changes
// so present files are reparsed from 0 (idempotent keys, AGENTLOG-03).
const ParserVersion = 3

const maxLineBytes = 8 << 20

// claudeRecord is the subset of a Claude Code transcript line the core
// reads. Every field is optional; unknown fields are ignored.
type claudeRecord struct {
	Type               string          `json:"type"`
	Subtype            string          `json:"subtype"`
	SessionID          string          `json:"sessionId"`
	UUID               string          `json:"uuid"`
	ParentUUID         string          `json:"parentUuid"`
	PromptID           string          `json:"promptId"`
	Timestamp          string          `json:"timestamp"`
	CWD                string          `json:"cwd"`
	GitBranch          string          `json:"gitBranch"`
	RequestID          string          `json:"requestId"`
	IsMeta             bool            `json:"isMeta"`
	IsSidechain        bool            `json:"isSidechain"`
	IsAPIError         bool            `json:"isApiErrorMessage"`
	APIErrorStatus     json.RawMessage `json:"apiErrorStatus"`
	IsCompactSummary   bool            `json:"isCompactSummary"`
	AttributionSkill   string          `json:"attributionSkill"`
	ToolDenialKind     string          `json:"toolDenialKind"`
	PermissionDecision json.RawMessage `json:"permissionDecision"`
	ToolUseResult      json.RawMessage `json:"toolUseResult"`
	PRURL              string          `json:"prUrl"`
	TotalCostUSD       *float64        `json:"totalCostUSD"`
	Attachment         json.RawMessage `json:"attachment"`
	Rendered           []struct {
		Content string `json:"content"`
	} `json:"rendered"` // an attachment record's text as it entered the context (next to attachment)
	CompactMetadata *struct {
		Trigger    string `json:"trigger"`
		PreTokens  *int64 `json:"preTokens"`
		PostTokens *int64 `json:"postTokens"`
	} `json:"compactMetadata"`
	Shape *struct {
		System json.RawMessage `json:"system"`
		Tools  json.RawMessage `json:"tools"`
	} `json:"shape"`
	Message claudeMessage `json:"message"`
}

type claudeMessage struct {
	ID      string          `json:"id"`
	Model   string          `json:"model"`
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
	Usage   *claudeUsage    `json:"usage"`
}

type claudeUsage struct {
	Input         int64  `json:"input_tokens"`
	Output        int64  `json:"output_tokens"`
	CacheRead     int64  `json:"cache_read_input_tokens"`
	CacheCreation int64  `json:"cache_creation_input_tokens"`
	Speed         string `json:"speed"`
	ServiceTier   string `json:"service_tier"`
	OutputDetails *struct {
		Thinking int64 `json:"thinking_tokens"`
	} `json:"output_tokens_details"`
	CacheBreakdown *struct {
		FiveMin int64 `json:"ephemeral_5m_input_tokens"`
		OneHour int64 `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`
}

type ParseOptions struct {
	Path     string
	Folder   string
	Subagent bool
	AgentID  string
	// KnownSkills seeds the slash-skill set: names from skill_listing
	// attachments before the parse's start offset (Claude Code writes the
	// listing once near the start of a session).
	KnownSkills []string
	// PriorSkills, when set, returns the skill_listing names before the
	// parse's start offset. It is called at most once, on the first slash
	// command whose name is not already known, so an incremental read does
	// not reread the file's prefix every scan.
	PriorSkills func() ([]string, error)
	// MaxRows stops the parse after the line that brings the produced events
	// plus tool results to MaxRows (0 = read to the end); More then says the
	// input may hold further complete lines.
	MaxRows int
}

type ParseResult struct {
	Sessions    map[string]*agentlogdb.AgentLogSession
	Events      []agentlogdb.AgentLogEvent
	ToolResults []agentlogdb.AgentToolResult
	// ContextParts are the baseline parts of each lane's first API call (a
	// read from offset 0 only); SkillListing is every listed skill.
	ContextParts []agentlogdb.AgentContextPart
	SkillListing []agentlogdb.AgentSkillListed
	Unknown      map[string]int
	LongLines    int
	Consumed     int64
	More         bool     // stopped at MaxRows, not at the end of the input
	Skills       []string // every skill name known at the end of the parse (seed for the next slice)
	PriorLoaded  bool     // PriorSkills was called: Skills includes the listings before the start
}

// knownTypes are record types the core reads or deliberately ignores; any
// other type is counted in Unknown so format drift shows in `agents scan`.
var knownTypes = map[string]bool{
	"assistant": true, "user": true, "system": true, "attachment": true, "pr-link": true, "cost-state": true,
	"summary": true, "queue-operation": true, "last-prompt": true, "mode": true, "permission-mode": true,
	"ai-title": true, "file-history-snapshot": true, "file-history-delta": true, "api-request": true,
	"api-request-blob": true, "api-request-shape": true, "atis-latch": true, "bridge-session": true,
	"frame-link": true, "relocated": true, "worktree-state": true, "artifact-autoreact-ledger": true,
	"artifact-comment-monitor": true,
}

// ParseClaude reads complete lines from r (positioned at startOffset) and
// returns the rows they produce. A final line without '\n' is left for the
// next scan; a bad line never fails the file.
func ParseClaude(r io.Reader, startOffset int64, o ParseOptions) (*ParseResult, error) {
	p := &claudeParser{o: o, res: &ParseResult{Sessions: map[string]*agentlogdb.AgentLogSession{}, Unknown: map[string]int{}},
		callIdx: map[string]int{}, toolIdx: map[string]int{}, skills: map[string]bool{},
		lanes: map[string]*laneParts{}, fromStart: startOffset == 0}
	for _, n := range o.KnownSkills {
		p.skills[n] = true
	}
	br := bufio.NewReaderSize(r, 64<<10)
	off := startOffset
	for {
		raw, n, complete, err := NextLine(br, maxLineBytes)
		if !complete {
			break // EOF mid-line, or plain EOF: the rest waits for the next scan
		}
		lineOff := off
		off += n
		p.res.Consumed += n
		if raw == nil {
			p.res.LongLines++
		} else {
			p.handle(raw, lineOff)
		}
		if p.priorErr != nil {
			return nil, fmt.Errorf("reading skill listings of %s: %w", o.Path, p.priorErr)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("reading %s: %w", o.Path, err)
		}
		if o.MaxRows > 0 && len(p.res.Events)+len(p.res.ToolResults) >= o.MaxRows {
			p.res.More = true
			break
		}
	}
	for n := range p.skills {
		p.res.Skills = append(p.res.Skills, n)
	}
	p.emitContextParts()
	sort.Strings(p.res.Skills)
	return p.res, nil
}

// NextLine returns one '\n'-terminated line without the newline, the bytes
// consumed, and complete=false when the input ended before a newline. A line
// longer than limit comes back as nil (consumed and complete).
func NextLine(br *bufio.Reader, limit int) ([]byte, int64, bool, error) {
	var buf []byte
	var n int64
	tooLong := false
	for {
		chunk, err := br.ReadSlice('\n')
		n += int64(len(chunk))
		if !tooLong {
			buf = append(buf, chunk...)
			if len(buf) > limit {
				tooLong, buf = true, nil
			}
		}
		if err == nil {
			if tooLong {
				return nil, n, true, nil
			}
			return buf[:len(buf)-1], n, true, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return nil, n, false, err // EOF without newline: not consumed
	}
}

type claudeParser struct {
	o       ParseOptions
	res     *ParseResult
	callIdx map[string]int  // api_call key → index in res.Events
	toolIdx map[string]int  // tool_use_id → index in res.Events
	skills  map[string]bool // KnownSkills plus every skill_listing attachment seen

	lanes     map[string]*laneParts // session uuid → this file's lane baseline parts
	laneOrder []string
	fromStart bool // read from offset 0: the lanes' starts are in this read

	priorErr error // PriorSkills failed: the parse fails, the file is retried next scan
}

// knowsSkill reports whether name is a listed skill, loading the listings
// before the start offset (PriorSkills) the first time a name is unknown.
func (p *claudeParser) knowsSkill(name string) bool {
	if !p.skills[name] && p.o.PriorSkills != nil {
		prior, err := p.o.PriorSkills()
		p.o.PriorSkills, p.priorErr, p.res.PriorLoaded = nil, err, true
		for _, n := range prior {
			p.skills[n] = true
		}
	}
	return p.skills[name]
}

// readTypes are the record types that produce sessions or events; one
// without a sessionId is counted, never stored (its event would have no
// session row).
var readTypes = map[string]bool{"assistant": true, "user": true, "system": true, "pr-link": true, "cost-state": true}

func (p *claudeParser) handle(raw []byte, off int64) {
	var rec claudeRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		p.res.Unknown["<invalid>"]++
		return
	}
	if !knownTypes[rec.Type] {
		p.res.Unknown[rec.Type]++
		return
	}
	if rec.SessionID == "" {
		if readTypes[rec.Type] {
			p.res.Unknown["<no-session>"]++
			return
		}
	} else {
		p.touchSession(rec)
	}
	switch rec.Type {
	case "assistant":
		p.assistant(rec, off)
	case "user":
		p.user(rec, off)
	case "system":
		if rec.Subtype == "compact_boundary" {
			e := agentlogdb.AgentLogEvent{Key: p.recKey("compaction", rec, off), Kind: "compaction"}
			if m := rec.CompactMetadata; m != nil {
				e.Trigger, e.PreTokens, e.PostTokens = compactTrigger(m.Trigger), m.PreTokens, m.PostTokens
			}
			p.add(rec, off, e)
		}
	case "pr-link":
		if rec.PRURL != "" {
			p.add(rec, off, agentlogdb.AgentLogEvent{Key: "pr_link:" + rec.SessionID + ":" + rec.PRURL, Kind: "pr_link", Target: rec.PRURL})
		}
	case "cost-state":
		if s := p.res.Sessions[rec.SessionID]; s != nil && rec.TotalCostUSD != nil {
			v := *rec.TotalCostUSD
			s.ReportedCostUSD = &v
		}
	case "attachment":
		p.attachment(rec)
	case "api-request-shape":
		if rec.Shape != nil {
			p.addPart(rec.SessionID, "system", int64(len(rec.Shape.System)))
			p.addPart(rec.SessionID, "tools", int64(len(rec.Shape.Tools)))
		}
	}
}

func (p *claudeParser) touchSession(rec claudeRecord) {
	s := p.res.Sessions[rec.SessionID]
	if s == nil {
		s = &agentlogdb.AgentLogSession{SessionUUID: rec.SessionID, Agent: "claude", SourcePath: p.o.Path,
			StartedAt: rec.Timestamp, EndedAt: rec.Timestamp}
		p.res.Sessions[rec.SessionID] = s
	}
	if s.HomeCWD == "" && rec.CWD != "" {
		s.HomeCWD = rec.CWD
	}
	if s.GitBranch == "" && rec.GitBranch != "" {
		s.GitBranch = rec.GitBranch
	}
	if rec.Timestamp != "" {
		if s.StartedAt == "" || rec.Timestamp < s.StartedAt {
			s.StartedAt = rec.Timestamp
		}
		if rec.Timestamp > s.EndedAt {
			s.EndedAt = rec.Timestamp
		}
	}
}

// recKey is "<kind>:<record uuid>", or "<kind>:<src path>:<byte offset>"
// for a record without a uuid, so such records never share one row.
func (p *claudeParser) recKey(kind string, rec claudeRecord, off int64) string {
	if rec.UUID != "" {
		return kind + ":" + rec.UUID
	}
	return kind + ":" + p.o.Path + ":" + strconv.FormatInt(off, 10)
}

// add fills the common columns of e from rec and appends it.
func (p *claudeParser) add(rec claudeRecord, off int64, e agentlogdb.AgentLogEvent) int {
	e.SessionUUID, e.TS, e.UUID, e.ParentUUID, e.PromptID = rec.SessionID, rec.Timestamp, rec.UUID, rec.ParentUUID, rec.PromptID
	e.AgentID, e.IsSidechain = p.o.AgentID, rec.IsSidechain || p.o.Subagent
	e.SrcPath, e.SrcOffset = p.o.Path, off
	p.res.Events = append(p.res.Events, e)
	return len(p.res.Events) - 1
}

func (p *claudeParser) assistant(rec claudeRecord, off int64) {
	if rec.IsAPIError {
		p.add(rec, off, agentlogdb.AgentLogEvent{Key: p.recKey("api_error", rec, off), Kind: "api_error",
			ErrorClass: apiErrorStatus(rec.APIErrorStatus)})
		return
	}
	m := rec.Message
	if m.Usage != nil && m.Model != "<synthetic>" && m.ID != "" {
		p.apiCall(rec, off)
	}
	p.toolUses(rec, off) // Task 4
}

func (p *claudeParser) apiCall(rec claudeRecord, off int64) {
	m, u := rec.Message, rec.Message.Usage
	key := m.ID + ":" + rec.RequestID
	if rec.RequestID == "" {
		key = m.ID + ":" + rec.SessionID
	}
	cw5, cw1h := u.CacheCreation, int64(0)
	if u.CacheBreakdown != nil && u.CacheBreakdown.FiveMin+u.CacheBreakdown.OneHour > 0 {
		cw5, cw1h = u.CacheBreakdown.FiveMin, u.CacheBreakdown.OneHour
	}
	usd, known := Cost(m.Model, u.Speed, u.Input, u.Output, u.CacheRead, cw5, cw1h)
	e := agentlogdb.AgentLogEvent{Key: key, Kind: "api_call", Name: m.Model, Skill: rec.AttributionSkill,
		InputTokens: u.Input, OutputTokens: u.Output, CacheReadTokens: u.CacheRead,
		CacheWrite5mTokens: cw5, CacheWrite1hTokens: cw1h, Speed: u.Speed, ServiceTier: u.ServiceTier,
		CostUSD: usd, CostEstimated: !known, PriceVersion: PriceVersion,
		MessageID: m.ID, SubagentReplayCheck: p.o.Subagent}
	if u.OutputDetails != nil {
		e.ThinkingTokens = u.OutputDetails.Thinking
	}
	p.closeLane(rec.SessionID)
	if i, ok := p.callIdx[key]; ok {
		if u.Output >= p.res.Events[i].OutputTokens {
			e.SessionUUID, e.TS, e.UUID, e.ParentUUID, e.PromptID = rec.SessionID, p.res.Events[i].TS, p.res.Events[i].UUID, p.res.Events[i].ParentUUID, p.res.Events[i].PromptID
			e.AgentID, e.IsSidechain, e.SrcPath, e.SrcOffset = p.res.Events[i].AgentID, p.res.Events[i].IsSidechain, p.res.Events[i].SrcPath, p.res.Events[i].SrcOffset
			p.res.Events[i] = e
		}
		return
	}
	if s := p.res.Sessions[rec.SessionID]; s != nil {
		s.Model = m.Model
	}
	p.callIdx[key] = p.add(rec, off, e)
}

func (p *claudeParser) user(rec claudeRecord, off int64) {
	if rec.IsMeta || rec.IsCompactSummary || rec.Message.Role != "user" {
		return
	}
	var text string
	if json.Unmarshal(rec.Message.Content, &text) == nil {
		if strings.HasPrefix(text, "<local-command") {
			return
		}
		p.add(rec, off, agentlogdb.AgentLogEvent{Key: p.recKey("owner_turn", rec, off), Kind: "owner_turn", Trigger: turnTrigger(text)})
		p.slashSkill(rec, off, text) // Task 4
		return
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	hasResult, firstText := false, ""
	for _, b := range blocks {
		if b.Type == "tool_result" {
			hasResult = true
		}
		if b.Type == "text" && firstText == "" {
			firstText = b.Text
		}
	}
	if hasResult {
		p.toolResults(rec) // Task 4
		return
	}
	p.add(rec, off, agentlogdb.AgentLogEvent{Key: p.recKey("owner_turn", rec, off), Kind: "owner_turn", Trigger: turnTrigger(firstText)})
}

// turnTrigger tells the owner's own turn from a system-injected one: a task or
// sub-agent notification, or a hook / reminder block. Leading whitespace is
// ignored.
func turnTrigger(text string) string {
	text = strings.TrimLeft(text, " \t\r\n")
	switch {
	case strings.HasPrefix(text, "[Request interrupted by user"):
		return "interrupt"
	case strings.HasPrefix(text, "<task-notification>"), strings.HasPrefix(text, "<agent-message"):
		return "notification"
	case strings.HasPrefix(text, "<system-reminder>"), strings.HasPrefix(text, "Stop hook feedback:"):
		return "hook"
	}
	return "owner"
}

func (p *claudeParser) attachment(rec claudeRecord) {
	var a struct {
		Type  string   `json:"type"`
		Names []string `json:"names"`
	}
	if json.Unmarshal(rec.Attachment, &a) != nil {
		return
	}
	var size int64 // what entered the context; no rendered list = 0, never a guess
	for _, r := range rec.Rendered {
		size += int64(len(r.Content))
	}
	p.addPart(rec.SessionID, attachmentPart(a.Type), size)
	if a.Type != "skill_listing" {
		return
	}
	for _, n := range a.Names { // union: a later listing never drops an earlier name
		p.skills[n] = true
		if rec.SessionID != "" && n != "" {
			p.res.SkillListing = append(p.res.SkillListing, agentlogdb.AgentSkillListed{SessionUUID: rec.SessionID,
				Skill: n, Bytes: size / int64(len(a.Names))})
		}
	}
}

// attachmentPart names the context part an attachment type adds to.
func attachmentPart(typ string) string {
	switch {
	case typ == "instructions":
		return "instructions"
	case typ == "skill_listing":
		return "skills"
	case typ == "agent_listing_delta":
		return "agents"
	case typ == "mcp_instructions_delta":
		return "mcp"
	case typ == "deferred_tools_record", typ == "deferred_tools_delta":
		return "deferred_tools"
	case strings.HasPrefix(typ, "hook_"):
		return "hooks"
	}
	return "other"
}

// laneParts are the bytes per part a lane's context held before its first
// API call; closed once that call is seen.
type laneParts struct {
	order  []string
	bytes  map[string]int64
	closed bool
}

func (p *claudeParser) lane(sid string) *laneParts {
	l := p.lanes[sid]
	if l == nil {
		l = &laneParts{bytes: map[string]int64{}}
		p.lanes[sid] = l
		p.laneOrder = append(p.laneOrder, sid)
	}
	return l
}

// addPart adds n bytes to part of the session's lane in this file, until the
// lane's first API call. A read not from offset 0 tracks nothing: the read
// that saw the lane's start stored its parts.
func (p *claudeParser) addPart(sid, part string, n int64) {
	if !p.fromStart || sid == "" {
		return
	}
	if l := p.lane(sid); !l.closed {
		if _, ok := l.bytes[part]; !ok {
			l.order = append(l.order, part)
		}
		l.bytes[part] += n
	}
}

func (p *claudeParser) closeLane(sid string) {
	if p.fromStart && sid != "" {
		p.lane(sid).closed = true
	}
}

// emitContextParts moves the parts of every closed lane into the result; a
// lane whose first API call is not in this read stores nothing (its baseline
// is not complete yet). The lane is this file's agent id ("" for the main
// transcript).
func (p *claudeParser) emitContextParts() {
	for _, sid := range p.laneOrder {
		l := p.lanes[sid]
		if !l.closed {
			continue
		}
		for _, part := range l.order {
			p.res.ContextParts = append(p.res.ContextParts, agentlogdb.AgentContextPart{SessionUUID: sid,
				AgentID: p.o.AgentID, Part: part, Bytes: l.bytes[part]})
		}
	}
}

// compactTrigger keeps only the known compaction triggers.
func compactTrigger(t string) string {
	if t == "auto" || t == "manual" {
		return t
	}
	return ""
}

// apiErrorStatus is the HTTP status of an API error record as text ("429"),
// or "" when absent or not a number.
func apiErrorStatus(raw json.RawMessage) string {
	var n int64
	if json.Unmarshal(raw, &n) == nil && n > 0 {
		return strconv.FormatInt(n, 10)
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil && n > 0 {
			return strconv.FormatInt(n, 10)
		}
	}
	return ""
}
