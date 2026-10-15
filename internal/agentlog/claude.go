package agentlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// ParserVersion is stamped on agent_log_files; bump it when parsing changes
// so present files are reparsed from 0 (idempotent keys, AGENTLOG-03).
const ParserVersion = 1

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
	IsCompactSummary   bool            `json:"isCompactSummary"`
	AttributionSkill   string          `json:"attributionSkill"`
	ToolDenialKind     string          `json:"toolDenialKind"`
	PermissionDecision json.RawMessage `json:"permissionDecision"`
	ToolUseResult      json.RawMessage `json:"toolUseResult"`
	PRURL              string          `json:"prUrl"`
	TotalCostUSD       *float64        `json:"totalCostUSD"`
	Attachment         json.RawMessage `json:"attachment"`
	Message            claudeMessage   `json:"message"`
}

type claudeMessage struct {
	ID      string          `json:"id"`
	Model   string          `json:"model"`
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
	Usage   *claudeUsage    `json:"usage"`
}

type claudeUsage struct {
	Input          int64  `json:"input_tokens"`
	Output         int64  `json:"output_tokens"`
	CacheRead      int64  `json:"cache_read_input_tokens"`
	CacheCreation  int64  `json:"cache_creation_input_tokens"`
	Speed          string `json:"speed"`
	ServiceTier    string `json:"service_tier"`
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
}

type ParseResult struct {
	Sessions    map[string]*db.AgentLogSession
	Events      []db.AgentLogEvent
	ToolResults []db.AgentToolResult
	Unknown     map[string]int
	LongLines   int
	Consumed    int64
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
	p := &claudeParser{o: o, res: &ParseResult{Sessions: map[string]*db.AgentLogSession{}, Unknown: map[string]int{}},
		callIdx: map[string]int{}, toolIdx: map[string]int{}, skills: map[string]bool{}}
	for _, n := range o.KnownSkills {
		p.skills[n] = true
	}
	br := bufio.NewReaderSize(r, 64<<10)
	off := startOffset
	for {
		raw, n, complete, err := nextLine(br, maxLineBytes)
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
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("reading %s: %w", o.Path, err)
		}
	}
	return p.res, nil
}

// nextLine returns one '\n'-terminated line without the newline, the bytes
// consumed, and complete=false when the input ended before a newline. A line
// longer than limit comes back as nil (consumed and complete).
func nextLine(br *bufio.Reader, limit int) ([]byte, int64, bool, error) {
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
			p.add(rec, off, db.AgentLogEvent{Key: p.recKey("compaction", rec, off), Kind: "compaction"})
		}
	case "pr-link":
		if rec.PRURL != "" {
			p.add(rec, off, db.AgentLogEvent{Key: "pr_link:" + rec.SessionID + ":" + rec.PRURL, Kind: "pr_link", Target: rec.PRURL})
		}
	case "cost-state":
		if s := p.res.Sessions[rec.SessionID]; s != nil && rec.TotalCostUSD != nil {
			v := *rec.TotalCostUSD
			s.ReportedCostUSD = &v
		}
	case "attachment":
		p.attachment(rec)
	}
}

func (p *claudeParser) touchSession(rec claudeRecord) {
	s := p.res.Sessions[rec.SessionID]
	if s == nil {
		s = &db.AgentLogSession{SessionUUID: rec.SessionID, Agent: "claude", SourcePath: p.o.Path,
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
func (p *claudeParser) add(rec claudeRecord, off int64, e db.AgentLogEvent) int {
	e.SessionUUID, e.TS, e.UUID, e.ParentUUID, e.PromptID = rec.SessionID, rec.Timestamp, rec.UUID, rec.ParentUUID, rec.PromptID
	e.AgentID, e.IsSidechain = p.o.AgentID, rec.IsSidechain || p.o.Subagent
	e.SrcPath, e.SrcOffset = p.o.Path, off
	p.res.Events = append(p.res.Events, e)
	return len(p.res.Events) - 1
}

func (p *claudeParser) assistant(rec claudeRecord, off int64) {
	if rec.IsAPIError {
		p.add(rec, off, db.AgentLogEvent{Key: p.recKey("api_error", rec, off), Kind: "api_error"})
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
	e := db.AgentLogEvent{Key: key, Kind: "api_call", Name: m.Model, Skill: rec.AttributionSkill,
		InputTokens: u.Input, OutputTokens: u.Output, CacheReadTokens: u.CacheRead,
		CacheWrite5mTokens: cw5, CacheWrite1hTokens: cw1h, Speed: u.Speed, ServiceTier: u.ServiceTier,
		CostUSD: usd, CostEstimated: !known, PriceVersion: PriceVersion,
		MessageID: m.ID, SubagentReplayCheck: p.o.Subagent}
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
		if strings.HasPrefix(text, "<local-command") || strings.HasPrefix(text, "[Request interrupted by user") {
			return
		}
		p.add(rec, off, db.AgentLogEvent{Key: p.recKey("owner_turn", rec, off), Kind: "owner_turn"})
		p.slashSkill(rec, off, text) // Task 4
		return
	}
	var blocks []struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	hasResult := false
	for _, b := range blocks {
		if b.Type == "tool_result" {
			hasResult = true
		}
	}
	if hasResult {
		p.toolResults(rec) // Task 4
		return
	}
	p.add(rec, off, db.AgentLogEvent{Key: p.recKey("owner_turn", rec, off), Kind: "owner_turn"})
}

func (p *claudeParser) attachment(rec claudeRecord) {
	var a struct {
		Type  string   `json:"type"`
		Names []string `json:"names"`
	}
	if json.Unmarshal(rec.Attachment, &a) == nil && a.Type == "skill_listing" {
		for _, n := range a.Names { // union: a later listing never drops an earlier name
			p.skills[n] = true
		}
	}
}
