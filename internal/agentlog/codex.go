package agentlog

import (
	"bufio"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/sessionfeed"
)

// The agent column of a transcript's file and session rows: Claude Code, or a
// Codex rollout (ask #507, decision D).
const (
	AgentClaude = "claude"
	AgentCodex  = "codex"
)

// codexRolloutLine is one line of a Codex rollout: {timestamp, type, payload}.
type codexRolloutLine struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

// codexPayload is the subset of a payload the importer reads. Message and
// item text, tool arguments and outputs are decoded only to classify them
// in memory; none of it is stored (AGENTLOG-01).
type codexPayload struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Timestamp string          `json:"timestamp"`
	CWD       string          `json:"cwd"`
	Model     string          `json:"model"`
	Name      string          `json:"name"`
	CallID    string          `json:"call_id"`
	Arguments string          `json:"arguments"`
	Input     string          `json:"input"`
	Output    json.RawMessage `json:"output"`
	Message   json.RawMessage `json:"message"`
	Reason    string          `json:"reason"`
	// NewThreadID is a collab_agent_spawn_end's spawned sub-agent thread.
	NewThreadID string `json:"new_thread_id"`
	Git         *struct {
		Branch string `json:"branch"`
	} `json:"git"`
	Item *struct {
		Type    string `json:"type"`
		ID      string `json:"id"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"item"`
	Info *struct {
		Last  *codexUsage `json:"last_token_usage"`
		Total *codexUsage `json:"total_token_usage"`
	} `json:"info"`
}

type codexUsage struct {
	Input      int64 `json:"input_tokens"`
	Cached     int64 `json:"cached_input_tokens"`
	CacheWrite int64 `json:"cache_write_input_tokens"`
	Output     int64 `json:"output_tokens"`
	Reasoning  int64 `json:"reasoning_output_tokens"`
	Total      int64 `json:"total_tokens"`
}

// codexKnownTypes are the rollout line types the importer reads or
// deliberately ignores; any other is counted in Unknown (format drift).
var codexKnownTypes = map[string]bool{
	"session_meta": true, "turn_context": true, "event_msg": true, "response_item": true,
	"compacted": true, "token_usage_record": true, "world_state": true,
}

// codexShellTools run a shell command whose line is in `cmd` or `command`.
var codexShellTools = map[string]bool{"exec_command": true, "shell": true, "shell_command": true, "local_shell": true}

// ParseCodex reads complete lines of a Codex rollout from r (positioned at
// startOffset in the rollout's text; a compressed file is decompressed by the
// caller, rollout.Open) and returns the rows they produce for session
// o.SessionUUID, the terminal session row's id. It mirrors ParseClaude: a
// final line without '\n' waits for the next scan, a bad line never fails the
// file, Consumed is the new offset minus startOffset.
//
// Rows: one api_call per token_count response (its last_token_usage; a count
// with no info adds nothing), an owner_turn per owner message (the Watchtower
// brief is a hook turn) and per interrupted turn (trigger interrupt), a tool
// per function or custom tool call paired with its output. Keys are content
// keys a forked or resumed rollout replays unchanged, so a replayed line
// counts once (AGENTLOG-02): an api_call is keyed by the rollout's lineage
// (codexLineage; a read from a later offset takes it from o.CodexLineage)
// and its usage figures (the response's and the session's running totals),
// never by the line's time, so a repeated report of one response, or a replay
// re-stamped when written, stores one row; tools by call id, paginated owner
// turns by item id. Only the session's own session_meta sets its folder,
// branch and start; a replayed parent's is ignored. A token_count whose info
// lacks a usage block, a legacy user_message whose message is not a string
// and a tool call or output with no call id are counted in Unknown, never
// dropped silently.
func ParseCodex(r io.Reader, startOffset int64, o ParseOptions) (*ParseResult, error) {
	if o.SessionUUID == "" {
		return nil, errors.New("parsing a codex rollout: no session id")
	}
	p := &codexParser{o: o, res: &ParseResult{Sessions: map[string]*agentlogdb.AgentLogSession{}, Unknown: map[string]int{}},
		seen: map[string]bool{}, model: o.CodexModel, cwd: o.CodexCWD, fromStart: startOffset == 0,
		lineage: codexLineage{id: o.CodexLineage, done: startOffset > 0}}
	br := bufio.NewReaderSize(r, 64<<10)
	off := startOffset
	for {
		raw, n, complete, err := NextLine(br, maxLineBytes)
		if !complete {
			// Unlike ParseClaude, a read error here fails the file: a codex
			// rollout may be a zstd stream, whose decode errors surface here.
			if err != nil && !errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("reading the rollout: %w", err)
			}
			break
		}
		lineOff := off
		off += n
		p.res.Consumed += n
		if raw == nil {
			p.res.LongLines++
		} else {
			p.handle(raw, lineOff)
		}
		if p.err != nil {
			return nil, p.err
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("reading the rollout: %w", err)
		}
		if o.MaxRows > 0 && len(p.res.Events)+len(p.res.ToolResults) >= o.MaxRows {
			p.res.More = true
			break
		}
	}
	p.res.CodexLineage = p.lineage.id
	p.res.CodexModel, p.res.CodexCWD = p.model, p.cwd
	return p.res, nil
}

type codexParser struct {
	o         ParseOptions
	res       *ParseResult
	lineage   codexLineage
	model     string
	cwd       string          // the session's own working directory (its session_meta)
	seen      map[string]bool // event keys added in this read
	fromStart bool            // read from offset 0: the first line's time may start the session
	linked    map[string]bool // spawn links added in this read
	modelSeen bool            // a turn_context was read, or CodexPriorModel was asked
	err       error           // CodexPriorModel's failure: fails the read
}

// child reports a sub-agent rollout read under its root's session.
func (p *codexParser) child() bool { return p.o.AgentID != "" }

// self is the rollout's own thread id: the sub-agent's, else the session's.
func (p *codexParser) self() string { return cmp.Or(p.o.AgentID, p.o.SessionUUID) }

func (p *codexParser) handle(raw []byte, off int64) {
	var l codexRolloutLine
	if err := json.Unmarshal(raw, &l); err != nil {
		p.res.Unknown["<invalid>"]++
		return
	}
	if !codexKnownTypes[l.Type] {
		p.res.Unknown[l.Type]++
		return
	}
	var pl codexPayload
	if json.Unmarshal(l.Payload, &pl) != nil {
		p.res.Unknown["<invalid>"]++
		return
	}
	p.lineage.see(l.Type, pl.ID)
	s := p.session(l.Timestamp)
	switch l.Type {
	case "session_meta":
		if pl.ID == p.self() { // a fork replays its parent's session_meta: never ours
			s.HomeCWD = pl.CWD
			if pl.CWD != "" {
				p.cwd = pl.CWD
			}
			if pl.Git != nil {
				s.GitBranch = pl.Git.Branch
			}
			if pl.Timestamp != "" {
				s.StartedAt = pl.Timestamp
			}
		}
	case "turn_context":
		p.modelSeen = true
		if pl.Model != "" {
			p.model, s.Model = pl.Model, pl.Model
		}
	case "event_msg":
		p.event(l, pl, off)
	case "response_item":
		p.responseItem(l, pl, off)
	}
}

// session returns the parse's one session row, widening its end to ts. Its
// start is the session's own session_meta time, else the first line's of a
// read from offset 0; a later read leaves it "" (the stored start stays), so
// a fork's replayed parent lines never move its start back.
func (p *codexParser) session(ts string) *agentlogdb.AgentLogSession {
	if p.child() {
		return &agentlogdb.AgentLogSession{} // the root's session row is the only one; a sub-agent's fields are dropped
	}
	s := p.res.Sessions[p.o.SessionUUID]
	if s == nil {
		s = &agentlogdb.AgentLogSession{SessionUUID: p.o.SessionUUID, Agent: AgentCodex, SourcePath: p.o.Path, Model: p.model}
		if p.fromStart {
			s.StartedAt = ts
		}
		p.res.Sessions[p.o.SessionUUID] = s
	}
	if ts > s.EndedAt {
		s.EndedAt = ts
	}
	return s
}

// add appends e unless this read already added its key (a repeated report).
func (p *codexParser) add(l codexRolloutLine, off int64, e agentlogdb.AgentLogEvent) {
	if p.seen[e.Key] {
		return
	}
	p.seen[e.Key] = true
	e.SessionUUID, e.TS, e.SrcPath, e.SrcOffset = p.o.SessionUUID, l.Timestamp, p.o.Path, off
	if p.child() {
		e.AgentID, e.IsSidechain = p.o.AgentID, true
	}
	p.res.Events = append(p.res.Events, e)
}

func (p *codexParser) event(l codexRolloutLine, pl codexPayload, off int64) {
	switch pl.Type {
	case "token_count":
		p.tokens(l, pl, off)
	case "collab_agent_spawn_end":
		p.spawn(pl)
	}
	if p.child() {
		return // a sub-agent's user messages and aborts are its parent agent's, not the owner's
	}
	switch pl.Type {
	case "turn_aborted": // the owner stopped the turn (Esc), like Claude's interrupt line
		if pl.Reason == "interrupted" {
			p.add(l, off, agentlogdb.AgentLogEvent{Key: "owner_turn:codex:abort:" + l.Timestamp, Kind: "owner_turn", Trigger: "interrupt"})
		}
	case "user_message": // legacy dialect: no id, the line's timestamp keys it
		var text string
		if json.Unmarshal(pl.Message, &text) != nil {
			p.res.Unknown["<codex-user-message>"]++
			return
		}
		p.add(l, off, agentlogdb.AgentLogEvent{Key: "owner_turn:codex:" + l.Timestamp, Kind: "owner_turn", Trigger: codexTrigger(text)})
	case "item_completed": // paginated dialect
		if pl.Item == nil || pl.Item.Type != "UserMessage" {
			return
		}
		key := "owner_turn:codex:" + pl.Item.ID
		if pl.Item.ID == "" {
			key = "owner_turn:codex:" + l.Timestamp
		}
		text := ""
		for _, c := range pl.Item.Content {
			if strings.EqualFold(c.Type, "text") && strings.TrimSpace(c.Text) != "" {
				text = c.Text
				break
			}
		}
		p.add(l, off, agentlogdb.AgentLogEvent{Key: key, Kind: "owner_turn", Trigger: codexTrigger(text)})
	}
}

// spawn links the sub-agent a collab_agent_spawn_end names under the root
// session, one level below the reading rollout (at most
// sessionfeed.MaxSubagentDepth: a deeper link is counted, not stored, so
// never read), and sets it on the spawn tool row of the same call id when
// that row is stored (CodexSpawns: an update, never a new row). A link to the
// reading rollout itself or to the root (a fork's replay) is not one; a
// spawn with no thread id is counted.
func (p *codexParser) spawn(pl codexPayload) {
	id := pl.NewThreadID
	if !sessionfeed.IsCodexThreadID(id) {
		p.res.Unknown["<codex-spawn-no-thread>"]++
		return
	}
	if id == p.self() || id == p.o.SessionUUID {
		return
	}
	switch depth := p.o.Depth + 1; {
	case depth > sessionfeed.MaxSubagentDepth:
		p.res.Unknown["<codex-spawn-too-deep>"]++
	case !p.linked[id]:
		if p.linked == nil {
			p.linked = map[string]bool{}
		}
		p.linked[id] = true
		p.res.Subagents = append(p.res.Subagents, agentlogdb.AgentSubagent{SessionUUID: p.o.SessionUUID, AgentID: id, Depth: depth, SpawnLink: true})
	}
	if pl.CallID != "" {
		p.res.CodexSpawns = append(p.res.CodexSpawns, agentlogdb.AgentSpawn{Key: "tool:codex:" + pl.CallID, AgentID: id})
	}
}

// codexLineage is the id of the last session_meta before a rollout's first
// content line (event_msg or response_item). A fork writes its own
// session_meta, then replays its parent's rollout from the parent's first
// line, so the parent and every fork of it share one lineage (the root
// session's id) while unrelated sessions differ. It depends only on the
// rollout's head, so a read from a later offset is given it (codexHead).
type codexLineage struct {
	id   string
	done bool // a content line was seen: the lineage is fixed
}

func (c *codexLineage) see(typ, id string) {
	switch typ {
	case "session_meta":
		if !c.done && id != "" {
			c.id = id
		}
	case "event_msg", "response_item":
		c.done = true
	}
}

// codexBriefPrefix opens the brief Watchtower types into a new codex session
// (cmd/workbench_brief.go; keep in step with sessionfeed's briefPrefix).
const codexBriefPrefix = "Watchtower workbench #"

// codexTrigger is turnTrigger plus the Watchtower brief, which is a hook turn.
func codexTrigger(text string) string {
	if strings.HasPrefix(strings.TrimLeft(text, " \t\r\n"), codexBriefPrefix) {
		return "hook"
	}
	return turnTrigger(text)
}

// tokens stores one model response, keyed by its usage figures and the
// session's running totals: a repeated report of the same response and a
// fork's replay of it carry the same figures whatever their line time. The
// key leads with the rollout's lineage, so two unrelated sessions whose
// responses carry the same figures never share a row.
func (p *codexParser) tokens(l codexRolloutLine, pl codexPayload, off int64) {
	if pl.Info == nil {
		return // a rate-limit-only count
	}
	if pl.Info.Last == nil || pl.Info.Total == nil {
		p.res.Unknown["<codex-token-count>"]++
		return
	}
	if !p.modelSeen && p.o.CodexPriorModel != nil {
		p.modelSeen = true
		m, err := p.o.CodexPriorModel()
		if err != nil {
			p.err = err
			return
		}
		p.model = cmp.Or(m, p.model)
	}
	u, t := pl.Info.Last, pl.Info.Total
	// OpenAI's input_tokens include the cached and the cache-write parts;
	// output_tokens include the reasoning, stored apart, never added twice.
	in := u.Input - u.Cached - u.CacheWrite
	if in < 0 {
		in = 0
		p.res.CodexUsageMismatch++
	}
	usd, known := CostFor(AgentCodex, p.model, "", in, u.Output, u.Cached, u.CacheWrite, 0)
	// The key keeps its pre-cache-write figures, so no stored row changes key.
	key := fmt.Sprintf("api_call:codex:%s/%d.%d.%d.%d.%d/%d.%d.%d.%d.%d", p.lineage.id, u.Input, u.Cached, u.Output, u.Reasoning, u.Total,
		t.Input, t.Cached, t.Output, t.Reasoning, t.Total)
	p.add(l, off, agentlogdb.AgentLogEvent{Key: key,
		Kind: "api_call", Name: p.model, InputTokens: in, OutputTokens: u.Output, CacheReadTokens: u.Cached,
		CacheWrite5mTokens: u.CacheWrite, ThinkingTokens: u.Reasoning, CostUSD: usd, CostEstimated: !known, PriceVersion: PriceVersion})
}

func (p *codexParser) responseItem(l codexRolloutLine, pl codexPayload, off int64) {
	switch pl.Type {
	case "function_call", "custom_tool_call":
		if pl.CallID == "" {
			p.res.Unknown["<codex-no-call-id>"]++
			return
		}
		name, target := codexTool(pl, p.o.Folder, p.cwd)
		p.add(l, off, agentlogdb.AgentLogEvent{Key: "tool:codex:" + pl.CallID, Kind: "tool", Name: name, Target: target, Outcome: "pending"})
	case "function_call_output", "custom_tool_call_output":
		if pl.CallID == "" {
			p.res.Unknown["<codex-no-call-id>"]++
			return
		}
		text := resultText(pl.Output)
		r := agentlogdb.AgentToolResult{ToolUseID: "codex:" + pl.CallID, TS: l.Timestamp, Outcome: "ok", ResultBytes: resultSize(pl.Output)}
		if codexExitFailed(text) {
			r.Outcome, r.ErrorClass = "error", ClassExitCode
		}
		p.res.ToolResults = append(p.res.ToolResults, r)
	}
}

// codexTool maps a codex tool call to the stored name and content-free
// target: a shell call is "Bash" with shellTarget's program (+ subcommand),
// apply_patch is "Edit" with the first file's folder-relative path, an MCP
// call keeps its name (a workbench call its "#<id>"), anything else its name
// with no target.
func codexTool(pl codexPayload, folder, cwd string) (name, target string) {
	switch {
	case codexShellTools[pl.Name]:
		return "Bash", shellTarget(codexCommand(pl.Arguments))
	case pl.Type == "custom_tool_call" && (pl.Name == "exec" || pl.Name == "functions.exec"):
		if cmd, ok := customExecCommand(pl.Input); ok {
			return "Bash", shellTarget(cmd)
		}
		return pl.Name, ""
	case pl.Name == "apply_patch":
		patch := pl.Input
		if pl.Type == "function_call" {
			var in struct {
				Input string `json:"input"`
			}
			_ = json.Unmarshal([]byte(pl.Arguments), &in)
			patch = in.Input
		}
		path := patchFile(patch)
		if path != "" && !filepath.IsAbs(path) {
			path = filepath.Join(cmp.Or(cwd, folder), path) // apply_patch paths are relative to the session's cwd
		}
		return "Edit", relativeTarget(path, folder)
	case strings.HasPrefix(pl.Name, "mcp__"):
		return pl.Name, toolTarget(pl.Name, json.RawMessage(pl.Arguments), folder)
	}
	if !progRe.MatchString(pl.Name) {
		return "other", ""
	}
	return pl.Name, ""
}

// codexCommand is the shell line of a shell call's arguments: `cmd` or
// `command`, a string or an argv joined with spaces.
func codexCommand(arguments string) string {
	var args struct {
		Cmd     json.RawMessage `json:"cmd"`
		Command json.RawMessage `json:"command"`
	}
	if json.Unmarshal([]byte(arguments), &args) != nil {
		return ""
	}
	raw := args.Cmd
	if len(raw) == 0 {
		raw = args.Command
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var argv []string
	if json.Unmarshal(raw, &argv) == nil {
		if len(argv) == 3 && (argv[0] == "bash" || argv[0] == "sh" || argv[0] == "zsh") && (argv[1] == "-lc" || argv[1] == "-c") {
			return argv[2] // codex wraps a line as [bash, -lc, line]
		}
		return strings.Join(argv, " ")
	}
	return ""
}

// customExecCmdRe finds the first `cmd: "…"` string literal in an `exec`
// custom tool call's JS source.
var customExecCmdRe = regexp.MustCompile(`\bcmd\s*:\s*("(?:[^"\\]|\\.)*")`)

func customExecCommand(input string) (string, bool) {
	m := customExecCmdRe.FindStringSubmatch(input)
	if m == nil {
		return "", false
	}
	var cmd string
	if json.Unmarshal([]byte(m[1]), &cmd) != nil {
		return "", false
	}
	return cmd, true
}

// patchFile is the path of the first file an apply_patch body touches.
func patchFile(patch string) string {
	for line := range strings.Lines(patch) {
		for _, pre := range []string{"*** Update File: ", "*** Add File: ", "*** Delete File: "} {
			if rest, ok := strings.CutPrefix(line, pre); ok {
				return strings.TrimSpace(rest)
			}
		}
	}
	return ""
}

// codexExitRe finds a non-zero exit status in a codex tool output.
var codexExitRe = regexp.MustCompile(`(?:Process exited with code|Exit code:|"exit_code":)\s*(-?\d+)`)

// codexExitFailed reports whether a tool output records a non-zero exit;
// the text is read in memory and dropped.
func codexExitFailed(text string) bool {
	m := codexExitRe.FindStringSubmatch(text)
	return m != nil && m[1] != "0"
}
