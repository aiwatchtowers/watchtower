package agentlog

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/db"
)

// subcommandPrograms keep their first argument in the target ("git commit")
// so #298 can find commits and PRs; nothing past it is ever stored.
var subcommandPrograms = map[string]bool{"git": true, "gh": true, "go": true, "make": true, "npm": true, "swift": true}

var fileTools = map[string]bool{"Read": true, "Edit": true, "Write": true, "MultiEdit": true, "NotebookEdit": true}

func (p *claudeParser) toolUses(rec claudeRecord, off int64) {
	var blocks []struct {
		Type  string          `json:"type"`
		ID    string          `json:"id"`
		Name  string          `json:"name"`
		Input json.RawMessage `json:"input"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	for _, b := range blocks {
		if b.Type != "tool_use" || b.ID == "" {
			continue
		}
		if _, seen := p.toolIdx[b.ID]; seen {
			continue
		}
		p.toolIdx[b.ID] = p.add(rec, off, db.AgentLogEvent{Key: "tool:" + b.ID, Kind: "tool", Name: b.Name,
			Target: toolTarget(b.Name, b.Input, p.o.Folder), Outcome: "pending", Skill: rec.AttributionSkill})
		switch {
		case b.Name == "Skill":
			var in struct {
				Skill string `json:"skill"`
			}
			if json.Unmarshal(b.Input, &in) == nil && in.Skill != "" {
				p.add(rec, off, db.AgentLogEvent{Key: "skill:" + b.ID, Kind: "skill", Name: in.Skill, Trigger: "proactive"})
			}
		case b.Name == "Read":
			var in struct {
				FilePath string `json:"file_path"`
			}
			if json.Unmarshal(b.Input, &in) == nil && filepath.Base(in.FilePath) == "SKILL.md" {
				p.add(rec, off, db.AgentLogEvent{Key: "skill:" + b.ID, Kind: "skill",
					Name: filepath.Base(filepath.Dir(in.FilePath)), Trigger: "read"})
			}
		}
	}
}

var commandNameRe = regexp.MustCompile(`<command-name>/?([^<\s]+)</command-name>`)

func (p *claudeParser) slashSkill(rec claudeRecord, off int64, text string) {
	m := commandNameRe.FindStringSubmatch(text)
	if m == nil || !p.skills[m[1]] {
		return
	}
	p.add(rec, off, db.AgentLogEvent{Key: "skill:" + rec.UUID + ":0", Kind: "skill", Name: m[1], Trigger: "slash"})
}

func (p *claudeParser) toolResults(rec claudeRecord) {
	var blocks []struct {
		Type      string          `json:"type"`
		ToolUseID string          `json:"tool_use_id"`
		Content   json.RawMessage `json:"content"`
		IsError   bool            `json:"is_error"`
	}
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	var tur struct {
		Interrupted     bool `json:"interrupted"`
		StructuredPatch []struct {
			Lines []string `json:"lines"`
		} `json:"structuredPatch"`
	}
	_ = json.Unmarshal(rec.ToolUseResult, &tur) // a string toolUseResult is fine: zero value
	for _, b := range blocks {
		if b.Type != "tool_result" || b.ToolUseID == "" {
			continue
		}
		text := resultText(b.Content)
		r := db.AgentToolResult{ToolUseID: b.ToolUseID, TS: rec.Timestamp, Outcome: "ok"}
		switch {
		case tur.Interrupted || strings.HasPrefix(text, "[Request interrupted by user"):
			r.Outcome = "interrupted"
		case rec.ToolDenialKind != "" || strings.Contains(text, "doesn't want to proceed with this tool use"):
			r.Outcome = "denied"
		case b.IsError:
			r.Outcome, r.ErrorClass = "error", errorClass(text)
		}
		for _, h := range tur.StructuredPatch {
			for _, l := range h.Lines {
				switch {
				case strings.HasPrefix(l, "+"):
					r.LinesAdded++
				case strings.HasPrefix(l, "-"):
					r.LinesRemoved++
				}
			}
		}
		p.res.ToolResults = append(p.res.ToolResults, r)
	}
}

// resultText reads a tool_result content (a string or a list of text
// blocks) for classification only; it is never stored.
func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil && len(blocks) > 0 {
		return blocks[0].Text
	}
	return ""
}

func errorClass(text string) string {
	t := strings.ToLower(text)
	switch {
	case strings.Contains(t, "exit code"):
		return "exit_code"
	case strings.Contains(t, "does not exist") || strings.Contains(t, "no such file") || strings.Contains(t, "not found"):
		return "not_found"
	case strings.Contains(t, "timed out") || strings.Contains(t, "timeout"):
		return "timeout"
	default:
		return "other"
	}
}

// toolTarget is the content-free description of what a tool touched
// (AGENTLOG-01): a folder-relative path, or a shell program (+ subcommand).
func toolTarget(name string, input json.RawMessage, folder string) string {
	var in struct {
		FilePath     string `json:"file_path"`
		NotebookPath string `json:"notebook_path"`
		Command      string `json:"command"`
	}
	if json.Unmarshal(input, &in) != nil {
		return ""
	}
	switch {
	case fileTools[name]:
		path := in.FilePath
		if path == "" {
			path = in.NotebookPath
		}
		return relativeTarget(path, folder)
	case name == "Bash":
		return shellTarget(in.Command)
	}
	return ""
}

func relativeTarget(path, folder string) string {
	if path == "" {
		return ""
	}
	rel, err := filepath.Rel(folder, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return "<outside>"
	}
	return rel
}

func shellTarget(cmd string) string {
	if i := strings.IndexAny(cmd, "&|;\n"); i >= 0 {
		cmd = cmd[:i]
	}
	fields := strings.Fields(cmd)
	for len(fields) > 0 && strings.Contains(fields[0], "=") {
		fields = fields[1:]
	}
	if len(fields) == 0 {
		return ""
	}
	prog := filepath.Base(fields[0])
	if subcommandPrograms[prog] && len(fields) > 1 && !strings.HasPrefix(fields[1], "-") {
		return prog + " " + fields[1]
	}
	return prog
}
