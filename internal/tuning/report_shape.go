package tuning

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"watchtower/internal/tools"
)

// The agent CLIs cap one MCP tool result well below tools.MaxReadResultBytes
// (Claude Code at about 25k tokens), and a whole agents report or session
// drill-down passes that cap on a busy workbench. So the report reads give
// the chat what fits: the sections it asks for, lists cut to a row limit, a
// session's timeline folded into per-lane totals, and a refusal that names
// every section's size when the result is still too big.
const maxReportBytes = 48 * 1024

// reportMeta are the agents report keys every report read keeps: the period,
// the filter and the analytics state (an empty report while analytics is off
// or the first import runs is not an all-clear).
var reportMeta = []string{"workbench_id", "since", "until", "agent", "agents", "agent_filter",
	"enabled", "old_format_sessions", "import"}

// sessionMeta are the session drill-down keys every session read keeps.
var sessionMeta = []string{"session"}

// reportRows is the row limit a read asked for, defaulted and clamped like
// every list read (tools.DefaultListLimit, tools.MaxListLimit), so READ-01's
// row backstop never refuses a shaped result.
func reportRows(n int) int {
	switch {
	case n <= 0:
		return tools.DefaultListLimit
	case n > tools.MaxListLimit:
		return tools.MaxListLimit
	}
	return n
}

// The retry hints of the size refusal: each names only arguments its tool
// takes.
const (
	retryReport   = "ask for fewer sections, a smaller limit or fewer days"
	retrySessions = "ask for a smaller limit or fewer days"
	retrySession  = "ask for fewer sections or a smaller limit"
)

// shapeReport turns a report value into what the chat reads: the meta keys
// plus the asked sections (every section when none is asked), each top-level
// list cut to limit rows with the cut rows counted in "<key>_more" (added to a
// count the report already carries), refused when it is still over
// maxReportBytes. The report lists sessions oldest first; the chat gets them
// newest first, so a cut keeps the recent ones.
func shapeReport(v any, meta, sections []string, limit int, retry string) (map[string]json.RawMessage, error) {
	all, err := asObject(v)
	if err != nil {
		return nil, err
	}
	var known []string
	for k := range all {
		if !slices.Contains(meta, k) && !strings.HasSuffix(k, "_more") {
			known = append(known, k)
		}
	}
	sort.Strings(known)
	for _, s := range sections {
		if !slices.Contains(known, s) {
			return nil, &tools.ValidationError{Msg: fmt.Sprintf("unknown section %q: one of %s", s, strings.Join(known, ", "))}
		}
	}
	if len(sections) == 0 {
		sections = known
	}
	out := map[string]json.RawMessage{}
	for _, k := range meta {
		if raw, ok := all[k]; ok {
			out[k] = raw
		}
	}
	for _, k := range sections {
		raw, more, err := cutList(all[k], limit, k == "sessions")
		if err != nil {
			return nil, fmt.Errorf("section %s: %w", k, err)
		}
		out[k] = raw
		if prev, ok := all[k+"_more"]; ok {
			var n int
			if json.Unmarshal(prev, &n) == nil {
				more += n
			}
		}
		if more > 0 {
			out[k+"_more"] = json.RawMessage(fmt.Sprint(more))
		}
	}
	if err := checkReportSize(out, retry); err != nil {
		return nil, err
	}
	return out, nil
}

// cutList keeps the first limit rows of a JSON list (after reversing it when
// reverse) and says how many it cut. An object section (skills: rows,
// never_used) has each of its own lists cut the same way, the cut rows
// counted in "<field>_more" inside it; any other value passes as it is.
func cutList(raw json.RawMessage, limit int, reverse bool) (json.RawMessage, int, error) {
	if len(raw) > 0 && raw[0] == '{' {
		return cutObjectLists(raw, limit)
	}
	if len(raw) == 0 || raw[0] != '[' {
		return raw, 0, nil
	}
	var rows []json.RawMessage
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, 0, err
	}
	if reverse {
		slices.Reverse(rows)
	}
	if len(rows) <= limit {
		out, err := json.Marshal(rows)
		return out, 0, err
	}
	cut, err := json.Marshal(rows[:limit])
	return cut, len(rows) - limit, err
}

func cutObjectLists(raw json.RawMessage, limit int) (json.RawMessage, int, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, 0, err
	}
	changed := false
	for k, v := range obj {
		if len(v) == 0 || v[0] != '[' {
			continue
		}
		cut, more, err := cutList(v, limit, false)
		if err != nil {
			return nil, 0, fmt.Errorf("%s: %w", k, err)
		}
		if more > 0 {
			obj[k], obj[k+"_more"] = cut, json.RawMessage(fmt.Sprint(more))
			changed = true
		}
	}
	if !changed {
		return raw, 0, nil
	}
	out, err := json.Marshal(obj)
	return out, 0, err
}

// checkReportSize refuses a shaped report over maxReportBytes, naming each
// section's size so the chat can ask for less. Sizes are of the indented JSON
// the MCP server sends (internal/mcp renders results with MarshalIndent).
func checkReportSize(out map[string]json.RawMessage, retry string) error {
	whole, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding the agent report: %w", err)
	}
	if len(whole) <= maxReportBytes {
		return nil
	}
	type size struct {
		key string
		n   int
	}
	sizes := make([]size, 0, len(out))
	for k, raw := range out {
		var b bytes.Buffer
		n := len(raw)
		if json.Indent(&b, raw, "  ", "  ") == nil {
			n = b.Len()
		}
		sizes = append(sizes, size{k, n})
	}
	sort.Slice(sizes, func(i, j int) bool {
		if sizes[i].n != sizes[j].n {
			return sizes[i].n > sizes[j].n
		}
		return sizes[i].key < sizes[j].key
	})
	parts := make([]string, 0, len(sizes))
	for _, s := range sizes {
		parts = append(parts, fmt.Sprintf("%s %d", s.key, s.n))
	}
	return &tools.ValidationError{
		Msg: fmt.Sprintf("the result is %d bytes, over the %d one read may return — %s; bytes per section: %s",
			len(whole), maxReportBytes, retry, strings.Join(parts, ", ")),
		Err: tools.ErrResultTooLarge,
	}
}

func asObject(v any) (map[string]json.RawMessage, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("encoding the agent report: %w", err)
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, fmt.Errorf("reading the agent report: %w", err)
	}
	return all, nil
}

// laneIn is the part of an agents report lane the summary reads.
type laneIn struct {
	AgentID      string `json:"agent_id"`
	SubagentType string `json:"subagent_type"`
	Background   bool   `json:"background"`
	Segments     []struct {
		Start     string `json:"start"`
		End       string `json:"end"`
		Category  string `json:"category"`
		ToolClass string `json:"tool_class"`
	} `json:"segments"`
}

// laneSummary is one lane of a session folded from its timeline segments
// (thousands on a long session, drawn by the Desktop chart and useless to the
// chat) into totals.
type laneSummary struct {
	AgentID      string           `json:"agent_id"`
	SubagentType string           `json:"subagent_type,omitempty"`
	Background   bool             `json:"background"`
	Segments     int              `json:"segments"`
	Start        string           `json:"start,omitempty"`
	End          string           `json:"end,omitempty"`
	MSByCategory map[string]int64 `json:"ms_by_category"`
	MSByTool     map[string]int64 `json:"ms_by_tool_class,omitempty"`
}

// summarizeLanes replaces a session drill-down's "lanes" with laneSummary
// rows; a value without lanes passes as it is.
func summarizeLanes(v any) (any, error) {
	all, err := asObject(v)
	if err != nil {
		return nil, err
	}
	raw, ok := all["lanes"]
	if !ok {
		return all, nil
	}
	var lanes []laneIn
	if err := json.Unmarshal(raw, &lanes); err != nil {
		return nil, fmt.Errorf("reading the session's lanes: %w", err)
	}
	out := make([]laneSummary, 0, len(lanes))
	for _, l := range lanes {
		s := laneSummary{AgentID: l.AgentID, SubagentType: l.SubagentType, Background: l.Background,
			Segments: len(l.Segments), MSByCategory: map[string]int64{}}
		for _, seg := range l.Segments {
			if s.Start == "" || seg.Start < s.Start {
				s.Start = seg.Start
			}
			if seg.End > s.End {
				s.End = seg.End
			}
			ms := segmentMS(seg.Start, seg.End)
			s.MSByCategory[seg.Category] += ms
			if seg.ToolClass != "" {
				if s.MSByTool == nil {
					s.MSByTool = map[string]int64{}
				}
				s.MSByTool[seg.ToolClass] += ms
			}
		}
		out = append(out, s)
	}
	if all["lanes"], err = json.Marshal(out); err != nil {
		return nil, fmt.Errorf("encoding the lane totals: %w", err)
	}
	return all, nil
}

// segmentMS is a segment's length; an unreadable or reversed stretch is 0.
func segmentMS(start, end string) int64 {
	s, err1 := time.Parse(time.RFC3339Nano, start)
	e, err2 := time.Parse(time.RFC3339Nano, end)
	if err1 != nil || err2 != nil || e.Before(s) {
		return 0
	}
	return e.Sub(s).Milliseconds()
}
