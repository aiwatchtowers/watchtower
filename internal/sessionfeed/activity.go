package sessionfeed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// activityWindow is how much of a transcript's tail ActivityOf reads.
const activityWindow = 256 << 10

// activitySummaryRunes caps Activity.Summary.
const activitySummaryRunes = 120

// Activity is the agent's open tool call: what it is doing right now.
type Activity struct {
	Tool      string    `json:"tool"`       // as recorded, e.g. "Bash", "mcp__watchtower-workbench__ask_owner"
	Summary   string    `json:"summary"`    // at most 120 runes
	StartedAt time.Time `json:"started_at"` // the tool_use record's timestamp
	More      int       `json:"more"`       // other open calls besides this one
}

type openCall struct {
	id      string
	tool    string
	summary string
	at      time.Time
}

// ActivityOf reads at most activityWindow bytes before EOF of path and returns
// the newest open tool call (a tool_use with no tool_result inside the window)
// of the main conversation, or of a subagent file when sidechain is set. Nil
// when nothing is open. It is independent of any feed cursor.
func ActivityOf(path string, codex, sidechain bool) (*Activity, error) {
	tail, err := readTail(path, activityWindow)
	if err != nil {
		return nil, err
	}
	var calls []openCall
	if codex {
		calls = codexOpenCalls(tail)
	} else {
		calls = claudeOpenCalls(tail, sidechain)
	}
	if len(calls) == 0 {
		return nil, nil
	}
	last := calls[len(calls)-1]
	a := &Activity{Tool: last.tool, Summary: last.summary, StartedAt: last.at, More: len(calls) - 1}
	allReads := len(calls) >= 2
	for _, c := range calls {
		if c.tool != "Read" {
			allReads = false
			break
		}
	}
	if allReads {
		a.Summary, a.More = fmt.Sprintf("%d files", len(calls)), 0
	}
	return a, nil
}

// readTail returns the last limit bytes of path, dropping a first partial line.
func readTail(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	start := int64(0)
	if st.Size() > limit {
		start = st.Size() - limit
	}
	buf := make([]byte, st.Size()-start)
	if _, err := f.ReadAt(buf, start); err != nil && err != io.EOF {
		return nil, err
	}
	if start > 0 {
		i := bytes.IndexByte(buf, '\n')
		if i < 0 {
			return nil, nil
		}
		buf = buf[i+1:]
	}
	return buf, nil
}

func claudeOpenCalls(tail []byte, sidechain bool) []openCall {
	var open []openCall
	for _, line := range bytes.Split(tail, []byte{'\n'}) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var r record
		if json.Unmarshal(line, &r) != nil {
			continue
		}
		if r.Type != "assistant" && r.Type != "user" {
			continue
		}
		if !sidechain && r.IsSidechain {
			continue
		}
		var blocks []block
		if json.Unmarshal(r.Message.Content, &blocks) != nil {
			continue // a plain string content has no tool blocks
		}
		at, _ := time.Parse(time.RFC3339Nano, r.Timestamp)
		for _, b := range blocks {
			switch {
			case r.Type == "assistant" && b.Type == "tool_use" && b.ID != "":
				open = append(open, openCall{id: b.ID, tool: b.Name, summary: toolSummary(b.Name, b.Input), at: at})
			case r.Type == "user" && b.Type == "tool_result":
				open = dropCall(open, b.ToolUseID)
			}
		}
	}
	return open
}

func dropCall(open []openCall, id string) []openCall {
	for i, c := range open {
		if c.id == id {
			return append(open[:i], open[i+1:]...)
		}
	}
	return open
}

// codexOpenCalls: response_item function_call lines without a
// function_call_output for their call_id.
func codexOpenCalls(tail []byte) []openCall {
	var open []openCall
	for _, line := range bytes.Split(tail, []byte{'\n'}) {
		var l codexLine
		if len(line) == 0 || json.Unmarshal(line, &l) != nil || l.Type != "response_item" {
			continue
		}
		var p struct {
			Type      string `json:"type"`
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
			Input     string `json:"input"`
			CallID    string `json:"call_id"`
		}
		if json.Unmarshal(l.Payload, &p) != nil || p.CallID == "" {
			continue
		}
		switch p.Type {
		case "function_call":
			at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
			open = append(open, openCall{id: p.CallID, tool: p.Name, summary: codexSummary(p.Name, p.Arguments), at: at})
		case "custom_tool_call":
			at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
			open = append(open, openCall{id: p.CallID, tool: p.Name, summary: customToolSummary(p.Name, p.Input), at: at})
		case "function_call_output", "custom_tool_call_output":
			open = dropCall(open, p.CallID)
		}
	}
	return open
}

// customCmdRe finds the first `cmd: "..."` string literal in a custom tool
// call's JS source.
var customCmdRe = regexp.MustCompile(`\bcmd\s*:\s*("(?:[^"\\]|\\.)*")`)

func customToolSummary(name, input string) string {
	if m := customCmdRe.FindStringSubmatch(input); m != nil {
		var cmd string
		if json.Unmarshal([]byte(m[1]), &cmd) == nil {
			if cmd = firstLine(cmd); cmd != "" {
				return clipSummary(cmd)
			}
		}
	}
	return clipSummary(name)
}

func codexSummary(name, arguments string) string {
	var args struct {
		Command json.RawMessage `json:"command"`
		Cmd     json.RawMessage `json:"cmd"`
	}
	if json.Unmarshal([]byte(arguments), &args) != nil {
		return clipSummary(name)
	}
	raw := args.Command
	if len(raw) == 0 {
		raw = args.Cmd
	}
	var s string
	var parts []string
	switch {
	case json.Unmarshal(raw, &parts) == nil && len(parts) > 0:
		s = strings.Join(parts, " ")
	case json.Unmarshal(raw, &s) == nil:
	}
	if s = firstLine(s); s == "" {
		return clipSummary(name)
	}
	return clipSummary(s)
}

func toolSummary(name string, input json.RawMessage) string {
	var in struct {
		Command     string `json:"command"`
		Description string `json:"description"`
		FilePath    string `json:"file_path"`
		Notebook    string `json:"notebook_path"`
		Pattern     string `json:"pattern"`
		URL         string `json:"url"`
		Query       string `json:"query"`
	}
	_ = json.Unmarshal(input, &in)
	s := ""
	switch name {
	case "Bash":
		s = firstLine(in.Description)
		if s == "" {
			s = firstLine(in.Command)
		}
	case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
		if p := firstNonEmpty(in.FilePath, in.Notebook); p != "" {
			s = filepath.Base(p)
		}
	case "Grep", "Glob":
		s = in.Pattern
	case "Agent", "Task":
		s = in.Description
	case "WebFetch":
		if u, err := url.Parse(in.URL); err == nil {
			s = u.Host
		}
	case "WebSearch":
		s = in.Query
	default:
		if rest, ok := strings.CutPrefix(name, "mcp__"); ok {
			if server, tool, ok := strings.Cut(rest, "__"); ok && tool != "" {
				s = tool + " · " + server
			}
		}
	}
	if s = firstLine(s); s == "" {
		s = name
	}
	return clipSummary(s)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(s)
}

func clipSummary(s string) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= activitySummaryRunes {
		return s
	}
	r := []rune(s)
	return string(r[:activitySummaryRunes-1]) + "…"
}
