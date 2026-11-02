package sessionfeed

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const liveWindow = 4 << 20
const maxLiveAgents = 32
const maxLiveAgentCandidates = 128

// Live is an on-demand, cursor-independent snapshot. Activity keeps its old
// meaning; completed actions and agent state live only in this new envelope.
type Live struct {
	ObservedAt      time.Time   `json:"observed_at"`
	Conversation    string      `json:"conversation"`
	TurnAt          time.Time   `json:"turn_at"`
	TurnActive      bool        `json:"turn_active"`
	Current         *LiveAction `json:"current"`
	Latest          *LiveAction `json:"latest"`
	Agents          []LiveAgent `json:"agents"`
	AgentsState     string      `json:"agents_state"`
	AgentsMore      int         `json:"agents_more"`
	inspectedAgents int
}
type LiveAction struct {
	ID          string    `json:"id"`
	Tool        string    `json:"tool"`
	Summary     string    `json:"summary"`
	StartedAt   time.Time `json:"started_at"`
	CompletedAt time.Time `json:"completed_at"`
	More        int       `json:"more"`
}
type LiveAgent struct {
	Ref       SubagentRef `json:"ref"`
	StartedAt time.Time   `json:"started_at"`
	Action    *LiveAction `json:"action"`
	CanOpen   bool        `json:"can_open"`
	statusAt  time.Time
	resumedAt time.Time
}
type liveReader struct {
	live       *Live
	open       []LiveAction
	agents     map[string]*LiveAgent
	codex      bool
	sidechain  bool
	path       string
	recognized bool
}

// LiveOf reads a bounded tail independently of the dialog cursor. A truncated
// lifecycle is explicitly unknown. It never writes a transcript or database.
func LiveOf(c Conversation, sidechain bool, now time.Time) (*Live, error) {
	st, err := os.Lstat(c.Path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("live transcript is not a regular file")
	}
	tail, err := readTail(c.Path, liveWindow)
	if err != nil {
		return nil, err
	}
	if bytes.HasPrefix(tail, zstdMagic) {
		return nil, fmt.Errorf("compressed transcript activity unavailable")
	}
	live := &Live{ObservedAt: now.UTC(), Conversation: c.AgentSessionID, TurnActive: true, Agents: []LiveAgent{}, AgentsState: "known"}
	r := liveReader{live: live, agents: map[string]*LiveAgent{}, codex: c.Codex, sidechain: sidechain, path: c.Path}
	if st.Size() > liveWindow {
		live.AgentsState = "unknown"
	}
	// Only newline-terminated records are committed to a rollout.
	if last := bytes.LastIndexByte(tail, '\n'); last >= 0 {
		tail = tail[:last]
	} else {
		tail = nil
	}
	for _, line := range bytes.Split(tail, []byte{'\n'}) {
		if c.Codex {
			r.codexLine(line)
		} else {
			r.claudeLine(line)
		}
	}
	if !r.recognized {
		return nil, fmt.Errorf("no supported activity records")
	}
	if len(r.open) > 0 && live.TurnActive {
		a := r.open[len(r.open)-1]
		a.More = len(r.open) - 1
		live.Current = &a
	}
	if !live.TurnActive {
		live.Current = nil
		live.Latest = nil
	}
	if !c.Codex {
		r.claudeAgents()
	}
	r.reconcileAgents()
	return live, nil
}
func (r *liveReader) reset(at time.Time) {
	r.live.TurnAt = at
	r.live.TurnActive = true
	r.live.Current = nil
	r.live.Latest = nil
	r.open = nil
}
func (r *liveReader) start(a LiveAction) {
	if a.ID == "" {
		return
	}
	r.live.TurnActive = true
	for i := range r.open {
		if r.open[i].ID == a.ID {
			r.open[i] = a
			return
		}
	}
	r.open = append(r.open, a)
}
func (r *liveReader) complete(id string, at time.Time) {
	for i, a := range r.open {
		if a.ID == id {
			a.CompletedAt = at
			r.live.Latest = &a
			r.open = append(r.open[:i], r.open[i+1:]...)
			return
		}
	}
}
func (r *liveReader) claudeLine(line []byte) {
	var rec record
	if json.Unmarshal(line, &rec) != nil || (!r.sidechain && rec.IsSidechain) {
		return
	}
	at, _ := time.Parse(time.RFC3339Nano, rec.Timestamp)
	if rec.Type == "user" && !rec.IsMeta && !rec.IsCompact {
		if e, ok := userEntry(rec); ok {
			r.recognized = true
			if e.Kind == KindOwner || e.Kind == KindAskAnswer || e.Kind == KindWatchtower {
				r.reset(at)
			}
		}
		var blocks []block
		if json.Unmarshal(rec.Message.Content, &blocks) == nil {
			for _, b := range blocks {
				if b.Type == "tool_result" {
					r.recognized = true
					r.complete(b.ToolUseID, at)
				}
			}
		}
	}
	if rec.Type != "assistant" {
		return
	}
	var blocks []block
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	if len(blocks) > 0 {
		r.recognized = true
	}
	for _, b := range blocks {
		if b.Type == "tool_use" {
			r.start(LiveAction{ID: b.ID, Tool: b.Name, Summary: toolSummary(b.Name, b.Input), StartedAt: at})
			if b.Name == "Agent" || b.Name == "Task" {
				var in struct {
					Description string `json:"description"`
					Type        string `json:"subagent_type"`
				}
				_ = json.Unmarshal(b.Input, &in)
				r.agents[b.ID] = &LiveAgent{Ref: SubagentRef{ToolUseID: b.ID, Type: in.Type, Description: clipSummary(firstLine(in.Description)), Status: StatusUnknown}, StartedAt: at}
			}
		}
	}
	var envelope struct {
		Message struct {
			StopReason string `json:"stop_reason"`
		} `json:"message"`
	}
	_ = json.Unmarshal(line, &envelope)
	if envelope.Message.StopReason == "end_turn" {
		r.live.TurnActive = false
	}
}

func (r *liveReader) claudeAgents() {
	sessionDir := strings.TrimSuffix(r.path, ".jsonl")
	metas, err := readLiveMetas(sessionDir)
	if err != nil {
		r.live.AgentsState = "unknown"
	}
	for id, m := range metas {
		a := r.agents[id]
		if a == nil {
			a = &LiveAgent{Ref: SubagentRef{ToolUseID: id, Type: m.AgentType, Description: clipSummary(firstLine(m.Description))}}
			r.agents[id] = a
		}
		a.Ref.AgentID = m.agentID
		if m.Finished {
			a.Ref.Status = StatusFinished
		} else {
			a.Ref.Status = StatusRunning
		}
	}
}

func (r *liveReader) codexLine(line []byte) {
	var l codexLine
	if json.Unmarshal(line, &l) != nil {
		return
	}
	var p struct {
		Type             string                     `json:"type"`
		Name             string                     `json:"name"`
		Arguments        string                     `json:"arguments"`
		Input            string                     `json:"input"`
		CallID           string                     `json:"call_id"`
		Output           json.RawMessage            `json:"output"`
		NewThreadID      string                     `json:"new_thread_id"`
		ReceiverThreadID string                     `json:"receiver_thread_id"`
		Prompt           string                     `json:"prompt"`
		Status           json.RawMessage            `json:"status"`
		AgentStatuses    map[string]json.RawMessage `json:"agent_statuses"`
		Item             json.RawMessage            `json:"item"`
	}
	if json.Unmarshal(l.Payload, &p) != nil {
		return
	}
	at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
	if l.Type == "response_item" {
		if p.Type == "function_call" || p.Type == "custom_tool_call" || p.Type == "function_call_output" || p.Type == "custom_tool_call_output" {
			r.recognized = true
		}
		switch p.Type {
		case "function_call", "custom_tool_call":
			summary := codexSummary(p.Name, p.Arguments)
			if p.Type == "custom_tool_call" {
				summary = customToolSummary(p.Name, p.Input)
			}
			r.start(LiveAction{ID: p.CallID, Tool: p.Name, Summary: summary, StartedAt: at})
		case "function_call_output", "custom_tool_call_output":
			for _, a := range r.open {
				if a.ID == p.CallID {
					r.codexToolResult(a, p.Output, at)
					break
				}
			}
			r.complete(p.CallID, at)
		}
		return
	}
	if l.Type != "event_msg" {
		return
	}
	if p.Type == "task_started" || p.Type == "turn_started" || p.Type == "user_message" || p.Type == "agent_message" || p.Type == "item_completed" || p.Type == "item_started" || strings.HasPrefix(p.Type, "collab_") {
		r.recognized = true
	}
	switch p.Type {
	case "task_started", "turn_started":
		r.reset(at)
	case "task_complete", "task_completed", "turn_complete", "turn_aborted":
		r.live.TurnActive = false
		r.open = nil
		r.live.Latest = nil
	case "user_message":
		r.reset(at)
	case "item_completed", "item_started":
		var item struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(p.Item, &item)
		if item.Type == "UserMessage" || item.Type == "userMessage" {
			r.reset(at)
		}
		if strings.EqualFold(item.Type, "CollabAgentToolCall") || item.Type == "collab_agent_tool_call" {
			r.codexCollabItem(p.Item, at)
		}
	case "collab_agent_spawn_end":
		r.agent(p.NewThreadID, p.CallID, p.Prompt, normalizeAgentStatus(p.Status), at)
	case "collab_resume_end":
		r.resumeAgent(p.ReceiverThreadID, "", normalizeAgentStatus(p.Status), at)
	case "collab_close_end":
		r.agent(p.ReceiverThreadID, "", "", StatusFinished, at)
	case "collab_agent_interaction_end":
		r.agent(p.ReceiverThreadID, "", p.Prompt, normalizeAgentStatus(p.Status), at)
	case "collab_waiting_end":
		for id, status := range p.AgentStatuses {
			r.agent(id, "", "", normalizeAgentStatus(status), at)
		}
	default:
		if strings.HasPrefix(p.Type, "collab_") && !strings.HasSuffix(p.Type, "_begin") {
			r.live.AgentsState = "unknown"
		}
	}
}
func normalizeAgentStatus(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		var obj map[string]json.RawMessage
		if json.Unmarshal(raw, &obj) == nil {
			for k := range obj {
				s = k
				break
			}
		}
	}
	switch strings.ToLower(s) {
	case "running", "pendinginit", "pending_init":
		return StatusRunning
	case "completed", "errored", "shutdown", "interrupted", "closed":
		return StatusFinished
	default:
		return StatusUnknown
	}
}
func (r *liveReader) agent(id, toolID, description, status string, at time.Time) {
	if !codexIDRe.MatchString(id) {
		r.live.AgentsState = "unknown"
		return
	}
	a := r.agents[id]
	if a == nil {
		a = &LiveAgent{Ref: SubagentRef{ToolUseID: "codex:" + id, AgentID: id, Type: "Codex", Status: StatusUnknown}, StartedAt: at}
		r.agents[id] = a
	}
	// toolID is intentionally not the drill-in selector: resumes keep the id.
	_ = toolID
	if at.Before(a.statusAt) {
		return
	}
	if at.Equal(a.statusAt) && a.Ref.Status == StatusFinished && status == StatusRunning {
		return
	}
	a.statusAt = at
	if a.Ref.Status != StatusRunning && status == StatusRunning {
		a.StartedAt = at
	}
	if description != "" {
		a.Ref.Description = clipSummary(firstLine(description))
	}
	a.Ref.Status = status
}
func (r *liveReader) codexCollabItem(raw json.RawMessage, at time.Time) {
	var p struct {
		Tool          string   `json:"tool"`
		Status        string   `json:"status"`
		Prompt        string   `json:"prompt"`
		ReceiverIDs   []string `json:"receiverThreadIds"`
		ReceiverSnake []string `json:"receiver_thread_ids"`
		States        map[string]struct {
			Status json.RawMessage `json:"status"`
		} `json:"agentsStates"`
		StatesSnake map[string]struct {
			Status json.RawMessage `json:"status"`
		} `json:"agents_states"`
	}
	if json.Unmarshal(raw, &p) != nil {
		r.live.AgentsState = "unknown"
		return
	}
	if p.ReceiverIDs == nil {
		p.ReceiverIDs = p.ReceiverSnake
	}
	if p.States == nil {
		p.States = p.StatesSnake
	}
	for _, id := range p.ReceiverIDs {
		status := StatusUnknown
		if v, ok := p.States[id]; ok {
			status = normalizeAgentStatus(v.Status)
		}
		if (p.Tool == "closeAgent" || p.Tool == "close_agent") && p.Status == "completed" {
			status = StatusFinished
		}
		if p.Tool == "resumeAgent" || p.Tool == "resume_agent" {
			r.resumeAgent(id, p.Prompt, status, at)
		} else {
			r.agent(id, "", p.Prompt, status, at)
		}
	}
}
func (r *liveReader) codexToolResult(a LiveAction, raw json.RawMessage, at time.Time) {
	name := a.Tool
	if i := strings.LastIndexAny(name, "."); i >= 0 {
		name = name[i+1:]
	}
	if name != "spawn_agent" && name != "resume_agent" && name != "close_agent" && name != "wait" {
		return
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		raw = []byte(text)
	}
	var result struct {
		AgentID string          `json:"agent_id"`
		Status  json.RawMessage `json:"status"`
	}
	if json.Unmarshal(raw, &result) != nil {
		r.live.AgentsState = "unknown"
		return
	}
	if name == "wait" {
		var statuses map[string]json.RawMessage
		if json.Unmarshal(result.Status, &statuses) == nil {
			for id, status := range statuses {
				r.agent(id, "", "", normalizeAgentStatus(status), at)
			}
		}
		return
	}
	status := normalizeAgentStatus(result.Status)
	// A successful spawn response acknowledges a live child, not its completion.
	if name == "spawn_agent" && result.AgentID != "" && status == StatusUnknown {
		status = StatusRunning
	}
	if name == "close_agent" {
		status = StatusFinished
	}
	if result.AgentID != "" {
		if name == "resume_agent" {
			r.resumeAgent(result.AgentID, "", status, at)
		} else {
			r.agent(result.AgentID, a.ID, "", status, at)
		}
	}
}
func (r *liveReader) agentPath(ref SubagentRef) (string, bool) {
	if r.codex {
		return codexChildPath(r.path, r.live.Conversation, ref.AgentID)
	}
	if ref.AgentID == "" || strings.ContainsAny(ref.AgentID, "/\\.") {
		return "", false
	}
	path := filepath.Join(strings.TrimSuffix(r.path, ".jsonl"), "subagents", "agent-"+ref.AgentID+".jsonl")
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() {
		return "", false
	}
	return path, true
}

// A child is discovered only under the rollout's sessions root, by UUID,
// and must declare this exact parent in session_meta. A transcript-provided
// path is never accepted. Symlinked files and escaped directories are refused.
func codexChildPath(parentPath, parentID, childID string) (string, bool) {
	if !codexIDRe.MatchString(childID) {
		return "", false
	}
	root := filepath.Dir(parentPath)
	for range 3 {
		root = filepath.Dir(root)
	}
	if filepath.Base(root) != "sessions" {
		return "", false
	}
	matches, _ := filepath.Glob(filepath.Join(root, "*", "*", "*", "rollout-*-"+childID+".jsonl"))
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}
	for _, path := range matches {
		st, e := os.Lstat(path)
		if e != nil || !st.Mode().IsRegular() {
			continue
		}
		resolved, e := filepath.EvalSymlinks(path)
		if e != nil || !strings.HasPrefix(resolved, resolvedRoot+string(filepath.Separator)) {
			continue
		}
		f, e := os.Open(path)
		if e != nil {
			continue
		}
		// Metadata is first; read only a small fixed prefix, never arbitrary file data.
		buf := make([]byte, 64<<10)
		n, _ := f.Read(buf)
		_ = f.Close()
		first, _, ok := bytes.Cut(buf[:n], []byte{'\n'})
		if !ok {
			continue
		}
		var meta struct {
			Type    string `json:"type"`
			Payload struct {
				ID     string          `json:"id"`
				Source json.RawMessage `json:"source"`
				Parent string          `json:"parent_thread_id"`
			} `json:"payload"`
		}
		if json.Unmarshal(first, &meta) != nil || meta.Type != "session_meta" || meta.Payload.ID != childID {
			continue
		}
		if meta.Payload.Parent == parentID || sourceParent(meta.Payload.Source) == parentID {
			return path, true
		}
	}
	return "", false
}
func sourceParent(raw json.RawMessage) string {
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return ""
	}
	var parent string
	if json.Unmarshal(obj["parent_thread_id"], &parent) == nil && parent != "" {
		return parent
	}
	for _, key := range []string{"subagent", "thread_spawn", "threadSpawn"} {
		if p := sourceParent(obj[key]); p != "" {
			return p
		}
	}
	return ""
}

// One bounded read for a child's current call and own lifecycle. No nested
// snapshot/agent traversal happens during a routine poll.
func codexChildHint(path string) (*LiveAction, string, time.Time, error) {
	tail, err := readTail(path, activityWindow)
	if err != nil {
		return nil, "", time.Time{}, err
	}
	if i := bytes.LastIndexByte(tail, '\n'); i >= 0 {
		tail = tail[:i]
	} else {
		tail = nil
	}
	calls := codexOpenCalls(tail)
	var action *LiveAction
	if len(calls) > 0 {
		a := calls[len(calls)-1]
		action = &LiveAction{ID: a.id, Tool: a.tool, Summary: a.summary, StartedAt: a.at}
	}
	status := ""
	var at time.Time
	for _, line := range bytes.Split(tail, []byte{'\n'}) {
		var l codexLine
		var p struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(line, &l) != nil || l.Type != "event_msg" || json.Unmarshal(l.Payload, &p) != nil {
			continue
		}
		switch p.Type {
		case "task_started", "turn_started", "user_message":
			status = StatusRunning
		case "task_complete", "task_completed", "turn_complete", "turn_aborted":
			status = StatusFinished
		default:
			continue
		}
		at, _ = time.Parse(time.RFC3339Nano, l.Timestamp)
	}
	if status == StatusFinished {
		action = nil
	}
	return action, status, at, nil
}

// A resume is a new interval, even when a provider's timestamp resolution
// gives it the same stamp as the previous terminal event.
func (r *liveReader) resumeAgent(id, description, status string, at time.Time) {
	r.agent(id, "", description, status, at)
	a := r.agents[id]
	if a == nil || at.Before(a.statusAt) || status != StatusRunning {
		return
	}
	a.Ref.Status = StatusRunning
	a.statusAt = at
	a.resumedAt = at
	a.StartedAt = at
}

// Inspect a bounded, newest-first set before applying the visible cap. A
// parent's stale spawn acknowledgement is not proof a child still runs.
func (r *liveReader) reconcileAgents() {
	ids := make([]string, 0, len(r.agents))
	for id := range r.agents {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		a, b := r.agents[ids[i]], r.agents[ids[j]]
		// Explicitly terminal parents need not displace potentially active
		// candidates from the bounded inspection budget.
		if (a.Ref.Status == StatusFinished) != (b.Ref.Status == StatusFinished) {
			return b.Ref.Status == StatusFinished
		}
		at, bt := a.statusAt, b.statusAt
		if at.IsZero() {
			at = a.StartedAt
		}
		if bt.IsZero() {
			bt = b.StartedAt
		}
		if at.Equal(bt) {
			return ids[i] > ids[j]
		}
		return at.After(bt)
	})
	if len(ids) > maxLiveAgentCandidates {
		ids = ids[:maxLiveAgentCandidates]
		r.live.AgentsState = "unknown"
	}
	for _, id := range ids {
		a := r.agents[id]
		r.live.inspectedAgents++
		if path, ok := r.agentPath(a.Ref); ok {
			a.CanOpen = true
			if r.codex {
				action, status, at, err := codexChildHint(path)
				if err != nil {
					a.Ref.Status = StatusUnknown
				} else {
					newer := at.After(a.statusAt)
					equalTerminal := at.Equal(a.statusAt) && status == StatusFinished && !at.Equal(a.resumedAt)
					if status != "" && (newer || equalTerminal) {
						if status == StatusRunning && a.Ref.Status != StatusRunning {
							a.StartedAt = at
						}
						a.Ref.Status = status
						a.statusAt = at
					}
					if a.Ref.Status == StatusRunning {
						a.Action = action
					}
				}
			} else if activity, err := ActivityOf(path, false, true); err == nil && activity != nil {
				a.Action = &LiveAction{Tool: activity.Tool, Summary: activity.Summary, StartedAt: activity.StartedAt}
			}
		}
		if a.Ref.Status == StatusUnknown {
			r.live.AgentsState = "unknown"
		}
	}
	// Reconciliation can finish old children: only now choose visible rows.
	sort.Slice(ids, func(i, j int) bool {
		a, b := r.agents[ids[i]], r.agents[ids[j]]
		if (a.Ref.Status == StatusFinished) != (b.Ref.Status == StatusFinished) {
			return b.Ref.Status == StatusFinished
		}
		if a.StartedAt.Equal(b.StartedAt) {
			return ids[i] < ids[j]
		}
		return a.StartedAt.Before(b.StartedAt)
	})
	for _, id := range ids {
		a := r.agents[id]
		if len(r.live.Agents) >= maxLiveAgents {
			if a.Ref.Status == StatusRunning {
				r.live.AgentsMore++
			}
			continue
		}
		r.live.Agents = append(r.live.Agents, *a)
	}
}

// Metadata absence is a known empty set; unreadability/malformed files are
// not. Limit every sidecar read and the number examined during a live poll.
func readLiveMetas(sessionDir string) (map[string]subagentMeta, error) {
	dir := filepath.Join(sessionDir, "subagents")
	out := map[string]subagentMeta{}
	st, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	if !st.IsDir() {
		return out, fmt.Errorf("subagent metadata is not a directory")
	}
	files, err := os.ReadDir(dir)
	if err != nil {
		return out, err
	}
	var firstErr error
	examined := 0
	for _, entry := range files {
		name := entry.Name()
		if !strings.HasPrefix(name, "agent-") || !strings.HasSuffix(name, ".meta.json") {
			continue
		}
		if examined >= maxLiveAgentCandidates {
			firstErr = fmt.Errorf("subagent metadata exceeds live budget")
			break
		}
		examined++
		path := filepath.Join(dir, name)
		st, e := os.Lstat(path)
		if e != nil || !st.Mode().IsRegular() || st.Size() > 64<<10 {
			firstErr = fmt.Errorf("subagent metadata unavailable")
			continue
		}
		f, e := os.Open(path)
		if e != nil {
			firstErr = e
			continue
		}
		raw, e := io.ReadAll(io.LimitReader(f, (64<<10)+1))
		_ = f.Close()
		if e != nil {
			firstErr = e
			continue
		}
		if len(raw) > 64<<10 {
			firstErr = fmt.Errorf("subagent metadata exceeds live budget")
			continue
		}
		var m subagentMeta
		if json.Unmarshal(raw, &m) != nil || m.ToolUseID == "" {
			firstErr = fmt.Errorf("invalid subagent metadata")
			continue
		}
		m.agentID = strings.TrimSuffix(strings.TrimPrefix(name, "agent-"), ".meta.json")
		out[m.ToolUseID] = m
	}
	return out, firstErr
}
