package sessionfeed

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	StatusRunning  = "running"
	StatusFinished = "finished"
	StatusUnknown  = "unknown"
)

// marker adds a subagent entry for an Agent tool_use (once per tool_use id).
func (st *state) marker(b block, at time.Time) {
	if _, ok := st.markers[b.ID]; ok || b.ID == "" {
		return
	}
	var in struct {
		Type        string `json:"subagent_type"`
		Description string `json:"description"`
	}
	_ = json.Unmarshal(b.Input, &in)
	if in.Type == "" {
		in.Type = "general-purpose"
	}
	st.markers[b.ID] = len(st.res.Entries)
	st.res.Entries = append(st.res.Entries, Entry{
		ID: b.ID, Kind: KindSubagent, At: at, Conversation: st.conv,
		Subagent: &SubagentRef{ToolUseID: b.ID, Type: in.Type, Description: in.Description, Status: StatusUnknown},
	})
}

// recordParentReport stores the tool_result text of an Agent call on its marker.
func (st *state) recordParentReport(rec record) {
	var blocks []block
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	for _, b := range blocks {
		i, ok := st.markers[b.ToolUseID]
		if b.Type != "tool_result" || !ok {
			continue
		}
		st.res.Entries[i].Subagent.ParentReport = resultText(b.Content)
	}
}

func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s)
	}
	var blocks []block
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var parts []string
	for _, b := range blocks {
		if b.Type == "text" && strings.TrimSpace(b.Text) != "" {
			parts = append(parts, strings.TrimSpace(b.Text))
		}
	}
	return strings.Join(parts, "\n\n")
}

type subagentMeta struct {
	ToolUseID   string `json:"toolUseId"`
	Finished    bool   `json:"finished"`
	Shape       string `json:"requestShape"`
	AgentType   string `json:"agentType"`
	Description string `json:"description"`
	agentID     string
}

// readMetas reads <sessionDir>/subagents/agent-*.meta.json by toolUseId, in
// file-name order. Symlinks are never read.
func readMetas(sessionDir string) (map[string]subagentMeta, []string) {
	metas := map[string]subagentMeta{}
	var order []string
	dir := filepath.Join(sessionDir, "subagents")
	fi, err := os.Lstat(dir)
	if err != nil || !fi.IsDir() {
		return metas, nil
	}
	files, _ := filepath.Glob(filepath.Join(dir, "agent-*.meta.json"))
	sort.Strings(files)
	for _, f := range files {
		fi, err := os.Lstat(f)
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var m subagentMeta
		if json.Unmarshal(raw, &m) != nil || m.ToolUseID == "" {
			continue
		}
		m.agentID = strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "agent-"), ".meta.json")
		if _, dup := metas[m.ToolUseID]; !dup {
			order = append(order, m.ToolUseID)
		}
		metas[m.ToolUseID] = m
	}
	return metas, order
}

// ResolveSubagents fills AgentID and Status of the subagent markers from
// <sessionDir>/subagents/agent-<id>.meta.json, matched by toolUseId. Without a
// meta file the status is "unknown". Symlinks are never read.
func ResolveSubagents(sessionDir string, entries []Entry) []Entry {
	metas, _ := readMetas(sessionDir)
	for i := range entries {
		ref := entries[i].Subagent
		if entries[i].Kind != KindSubagent || ref == nil {
			continue
		}
		m, ok := metas[ref.ToolUseID]
		if ok && m.Shape == "background" {
			ref.ParentReport = "" // the parent's result is only a launch notice
		}
		switch {
		case !ok:
			ref.Status = StatusUnknown
		case m.Finished:
			ref.AgentID, ref.Status = m.agentID, StatusFinished
		default:
			ref.AgentID, ref.Status = m.agentID, StatusRunning
		}
	}
	return entries
}

// metaMarkers builds marker entries from the sidecar meta files alone.
func metaMarkers(sessionDir, conv string) []Entry {
	metas, order := readMetas(sessionDir)
	var out []Entry
	for _, id := range order {
		m := metas[id]
		typ := m.AgentType
		if typ == "" {
			typ = "general-purpose"
		}
		out = append(out, Entry{ID: id, Kind: KindSubagent, Conversation: conv, Subagent: &SubagentRef{
			ToolUseID: id, AgentID: m.agentID, Type: typ, Description: m.Description, Status: StatusRunning,
		}})
		if m.Finished {
			out[len(out)-1].Subagent.Status = StatusFinished
		}
	}
	return out
}

// ParseSubagent reads a subagent transcript file into its own feed: the task
// (owner), the agent's text, nested Agent markers, and the report last — the
// subagent's own SubagentHandback message, else parentReport.
func ParseSubagent(path, parentReport string) (*Result, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("subagent transcript: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("subagent transcript %s: not a regular file", filepath.Base(path))
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("subagent transcript: %w", err)
	}
	defer func() { _ = f.Close() }()
	st := newState("", 0, true)
	res, err := st.run(f, maxLineBytes)
	if err != nil {
		return nil, err
	}
	report := st.handback
	if report == "" {
		report = parentReport
	}
	if report = strings.TrimSpace(report); report != "" {
		res.Entries = append(res.Entries, Entry{ID: "report", Kind: KindAgent, Text: report})
	}
	return res, nil
}
