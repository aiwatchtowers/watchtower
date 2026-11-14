package agentlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"sort"
	"strconv"
	"strings"

	"watchtower/internal/agentfiles"
	"watchtower/internal/agentlogdb"
)

// ParserVersion is stamped on a Claude transcript's agent_log_files row;
// bump it when parsing changes so present files are reparsed from 0
// (idempotent keys, AGENTLOG-03); 5 adds the per-source start weights
// (ContextSources) and a skill's own listing line. CodexParserVersion is a
// Codex rollout's (spec 2026-11-03 §4.7, D56): 5 corrects the stored fresh-input and
// cache-write split once without rereading Claude transcripts.
const (
	ParserVersion      = 5
	CodexParserVersion = 5
)

// parserVersionFor is the parser version a file row of agent must carry to
// count as read by this build. Every comparison with or stamp of a stored
// file's version goes through it (TestParserVersionComparedOnlyThroughHelper).
//
// The two versions are equal today, so it returns one value; it keeps the
// per-agent dispatch so a bump of either reparses only that agent's files.
//
//nolint:unparam // equal versions today; the dispatch is what a future one-agent bump needs
func parserVersionFor(agent string) int {
	if agent == AgentCodex {
		return CodexParserVersion
	}
	return ParserVersion
}

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
	// LaneBaseline, when set, is asked once per lane (session uuid) of a read
	// that does not start at offset 0, on the lane's first baseline record:
	// called says the lane's first API call is already stored (its baseline
	// is complete); otherwise parts are the bytes stored so far, which this
	// read continues until the lane's first call.
	LaneBaseline func(sid string) (called bool, parts map[string]int64, err error)
	// MaxRows stops the parse after the line that brings the produced events
	// plus tool results to MaxRows (0 = read to the end); More then says the
	// input may hold further complete lines.
	MaxRows int
	// SessionUUID is the codex session a rollout belongs to (ParseCodex
	// only): the terminal session row's id, known before the read, so a read
	// that starts past session_meta still knows its session.
	SessionUUID string
	// CodexModel and CodexCWD seed a codex read that does not start at
	// offset 0: the stored session's model and working directory (ParseCodex
	// only).
	CodexModel, CodexCWD string
	// CodexLineage seeds the same read with the rollout's lineage
	// (codexLineage, read from its head by codexHead): the session_meta lines
	// it comes from sit before the read's offset (ParseCodex only).
	CodexLineage string
	// CodexPriorModel, when set, returns the model of the last turn_context
	// before a sub-agent read's start offset. It is called at most once, on
	// a token line read before any turn_context of this read (the root's
	// model is seeded from its session row; a sub-agent has none).
	CodexPriorModel func() (string, error)
	// Depth is a Codex sub-agent rollout's depth below its root (1 = a
	// child of the root; 0 = the root). ParseCodex reads a rollout with
	// AgentID set as that sub-agent of SessionUUID (ParseCodex only).
	Depth int
}

type ParseResult struct {
	Sessions    map[string]*agentlogdb.AgentLogSession
	Events      []agentlogdb.AgentLogEvent
	ToolResults []agentlogdb.AgentToolResult
	// ContextParts are the baseline parts of each lane's first API call, as
	// far as they are known (a lane still before its first call stores what
	// it has; the next read continues it); SkillListing is every listed skill.
	ContextParts []agentlogdb.AgentContextPart
	SkillListing []agentlogdb.AgentSkillListed
	// ContextSources are the per-source start weights of each lane (a
	// skill's or agent's listing line, a tool's definition, a server's
	// instruction block), kept under the same lane rule as ContextParts.
	ContextSources []agentlogdb.AgentContextSource
	Unknown        map[string]int
	LongLines      int
	Consumed       int64
	More           bool     // stopped at MaxRows, not at the end of the input
	Skills         []string // every skill name known at the end of the parse (seed for the next slice)
	PriorLoaded    bool     // PriorSkills was called: Skills includes the listings before the start
	CodexLineage   string   // the rollout's lineage at the end of the parse (seed for the next slice; ParseCodex only)
	// CodexUsageMismatch counts the token lines of this parse whose fresh
	// input came out negative (input − cached − cache write < 0): stored as
	// 0 and counted, never floored silently (ParseCodex only).
	CodexUsageMismatch int
	// CodexModel and CodexCWD are the model and working directory at the end
	// of the parse (seed for the next slice; ParseCodex only).
	CodexModel, CodexCWD string
	// CodexModelSeen: the parse read a turn_context or asked CodexPriorModel,
	// so the next slice needs no prior model (ParseCodex only).
	CodexModelSeen bool
	// Subagents are the Codex sub-agent links of this parse's spawn events
	// (collab_agent_spawn_end), stored with the slice, and CodexSpawns the
	// spawn tool rows they link (ParseCodex only).
	Subagents   []agentlogdb.AgentSubagent
	CodexSpawns []agentlogdb.AgentSpawn
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
			return nil, fmt.Errorf("reading the stored state of %s: %w", o.Path, p.priorErr)
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

// NextLine returns one '\n'-terminated line (agentfiles.NextLine).
func NextLine(br *bufio.Reader, limit int) ([]byte, int64, bool, error) {
	return agentfiles.NextLine(br, limit)
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

	priorErr error // PriorSkills or LaneBaseline failed: the parse fails, the file is retried next scan
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
			p.shapeTools(rec.SessionID, rec.Shape.Tools)
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

// claudeAttachment is the part of an attachment record the parser reads.
// Its texts are measured, never stored: only names and lengths leave the
// parser (AGENTLOG-01).
type claudeAttachment struct {
	Type string `json:"type"`
	// skill_listing: the listed names and the listing text, one
	// "- <name>: …" line per skill.
	Names   []string `json:"names"`
	Content string   `json:"content"`
	// agent_listing_delta: added agent types and their lines, by index.
	AddedTypes []string `json:"addedTypes"`
	// agent_listing_delta and deferred_tools_delta.
	AddedLines []string `json:"addedLines"`
	// mcp_instructions_delta: server display names and their instruction
	// blocks, by index.
	AddedNames  []string `json:"addedNames"`
	AddedBlocks []string `json:"addedBlocks"`
	// deferred_tools_delta: deferred tools whose full definitions entered
	// the context.
	SurfacedDefinitions []struct {
		Name       string          `json:"name"`
		Definition json.RawMessage `json:"definition"`
	} `json:"surfacedDefinitions"`
}

func (p *claudeParser) attachment(rec claudeRecord) {
	var a claudeAttachment
	if json.Unmarshal(rec.Attachment, &a) != nil {
		return
	}
	var size int64 // what entered the context; no rendered list = 0, never a guess
	for _, r := range rec.Rendered {
		size += int64(len(r.Content))
	}
	sid := rec.SessionID
	p.addPart(sid, attachmentPart(a.Type), size)
	switch a.Type {
	case "skill_listing":
		p.skillListing(sid, a, size)
	case "agent_listing_delta":
		for i, n := range a.AddedTypes {
			if i < len(a.AddedLines) { // a type without its line is not measured
				p.addSource(sid, "agent", n, int64(len(a.AddedLines[i])))
			}
		}
	case "mcp_instructions_delta":
		for i, n := range a.AddedNames {
			if i < len(a.AddedBlocks) {
				p.addSource(sid, "mcp_instructions", n, int64(len(a.AddedBlocks[i])))
			}
		}
	case "deferred_tools_delta":
		for _, d := range a.SurfacedDefinitions {
			if len(d.Definition) > 0 && string(d.Definition) != "null" { // no definition: nothing entered the context
				p.addSource(sid, "tool", d.Name, int64(len(d.Definition)))
			}
		}
	}
}

// skillListing records the listed skills: each one's bytes are its own line
// of the listing; a name without a line of its own gets the listing's even
// split, for that name only.
func (p *claudeParser) skillListing(sid string, a claudeAttachment, size int64) {
	lines := skillLineBytes(a.Content, a.Names)
	for _, n := range a.Names { // union: a later listing never drops an earlier name
		p.skills[n] = true
		if sid == "" || n == "" {
			continue
		}
		b, ok := lines[n]
		if !ok {
			b = size / int64(len(a.Names))
		}
		p.res.SkillListing = append(p.res.SkillListing, agentlogdb.AgentSkillListed{SessionUUID: sid, Skill: n, Bytes: b})
		p.addSource(sid, "skill", n, b)
	}
}

// skillLineBytes maps each name to the length of its "- <name>:" line in a
// skill listing's content. A line belongs to the longest name it starts
// with, so "plugin" never takes the line of "plugin:skill".
func skillLineBytes(content string, names []string) map[string]int64 {
	if content == "" {
		return nil
	}
	byLen := slices.Clone(names)
	slices.SortFunc(byLen, func(x, y string) int { return len(y) - len(x) })
	out := map[string]int64{}
	for ln := range strings.SplitSeq(content, "\n") {
		ln = strings.TrimSuffix(ln, "\r")
		rest, ok := strings.CutPrefix(ln, "- ")
		if !ok {
			continue
		}
		for _, n := range byLen {
			if n != "" && strings.HasPrefix(rest, n+":") {
				if _, seen := out[n]; !seen {
					out[n] = int64(len(ln))
				}
				break
			}
		}
	}
	return out
}

// shapeTools records each tool definition of a request shape by name; a
// shape whose tools are not a list, or a tool without a name, adds nothing.
func (p *claudeParser) shapeTools(sid string, tools json.RawMessage) {
	var defs []json.RawMessage
	if json.Unmarshal(tools, &defs) != nil {
		return
	}
	for _, d := range defs {
		var t struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(d, &t) == nil {
			p.addSource(sid, "tool", t.Name, int64(len(d)))
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
// API call; closed once that call is seen. stored marks a lane whose first
// call an earlier read already stored: nothing of it is emitted.
type laneParts struct {
	order  []string
	bytes  map[string]int64
	closed bool
	stored bool
	// sources are the lane's per-source weights seen in this read (a
	// continued lane's stored ones are not loaded: the store keeps the MAX).
	sourceOrder []sourceKey
	sources     map[sourceKey]int64
}

// sourceKey names one source of a lane's start context.
type sourceKey struct{ kind, name string }

func (p *claudeParser) newLane(sid string, l *laneParts) *laneParts {
	if l.bytes == nil {
		l.bytes = map[string]int64{}
	}
	p.lanes[sid] = l
	p.laneOrder = append(p.laneOrder, sid)
	return l
}

// addPart adds n bytes to part of the session's lane in this file, until the
// lane's first API call. In a read that does not start at offset 0 the lane
// continues from the stored bytes (LaneBaseline) unless its first call is
// already stored; without LaneBaseline such a read tracks nothing.
func (p *claudeParser) addPart(sid, part string, n int64) {
	l := p.openLaneFor(sid)
	if l == nil {
		return
	}
	if _, ok := l.bytes[part]; !ok {
		l.order = append(l.order, part)
	}
	l.bytes[part] += n
}

// addSource sets the bytes of one named source of the session's lane in
// this file, under addPart's rule (until the lane's first API call). The
// same source seen twice keeps its larger size: it enters the context once.
func (p *claudeParser) addSource(sid, kind, name string, n int64) {
	if name == "" {
		return
	}
	l := p.openLaneFor(sid)
	if l == nil {
		return
	}
	if l.sources == nil {
		l.sources = map[sourceKey]int64{}
	}
	k := sourceKey{kind, name}
	old, ok := l.sources[k]
	if !ok {
		l.sourceOrder = append(l.sourceOrder, k)
	}
	l.sources[k] = max(old, n)
}

// openLaneFor returns the session's lane in this file while it is still
// before its first API call, opening it on first sight; nil once closed.
func (p *claudeParser) openLaneFor(sid string) *laneParts {
	if sid == "" {
		return nil
	}
	l := p.lanes[sid]
	if l == nil {
		l = p.newLane(sid, p.openLane(sid))
	}
	if l.closed {
		return nil
	}
	return l
}

// openLane is the state of a lane first seen in this read: empty from
// offset 0, else what LaneBaseline says is stored.
func (p *claudeParser) openLane(sid string) *laneParts {
	if p.fromStart {
		return &laneParts{}
	}
	if p.o.LaneBaseline == nil {
		return &laneParts{closed: true, stored: true}
	}
	called, parts, err := p.o.LaneBaseline(sid)
	if err != nil {
		if p.priorErr == nil {
			p.priorErr = err
		}
		return &laneParts{closed: true, stored: true}
	}
	if called {
		return &laneParts{closed: true, stored: true}
	}
	l := &laneParts{bytes: parts}
	for part := range parts {
		l.order = append(l.order, part)
	}
	sort.Strings(l.order)
	return l
}

// closeLane ends the lane's baseline at its first API call in this read. A
// lane with no baseline record before that call in this read needs no
// lookup: whatever is stored for it is already complete.
func (p *claudeParser) closeLane(sid string) {
	if sid == "" {
		return
	}
	if l := p.lanes[sid]; l != nil {
		l.closed = true
		return
	}
	p.newLane(sid, &laneParts{closed: true, stored: !p.fromStart})
}

// emitContextParts moves the parts and sources of every lane into the result: the whole
// baseline of a lane whose first API call is in this read, the bytes so far
// of one still before it (the stored row grows by MAX on the next read). A
// lane whose first call an earlier read stored emits nothing. The lane is
// this file's agent id ("" for the main transcript).
func (p *claudeParser) emitContextParts() {
	for _, sid := range p.laneOrder {
		l := p.lanes[sid]
		if l.stored {
			continue
		}
		for _, part := range l.order {
			p.res.ContextParts = append(p.res.ContextParts, agentlogdb.AgentContextPart{SessionUUID: sid,
				AgentID: p.o.AgentID, Part: part, Bytes: l.bytes[part]})
		}
		for _, k := range l.sourceOrder {
			p.res.ContextSources = append(p.res.ContextSources, agentlogdb.AgentContextSource{SessionUUID: sid,
				AgentID: p.o.AgentID, Kind: k.kind, Name: k.name, Bytes: l.sources[k]})
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
