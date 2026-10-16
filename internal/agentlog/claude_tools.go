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
	p.add(rec, off, db.AgentLogEvent{Key: p.recKey("skill", rec, off) + ":0", Kind: "skill", Name: m[1], Trigger: "slash"})
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
		case rec.ToolDenialKind != "" || rejected(rec.PermissionDecision) || strings.Contains(text, "doesn't want to proceed with this tool use"):
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

var (
	envAssignRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	progRe      = regexp.MustCompile(`^[A-Za-z0-9._+-]+$`)
	subcmdRe    = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// skipEnvAssign drops one leading NAME=value (value may be quoted) from s.
func skipEnvAssign(s string) (string, bool) {
	loc := envAssignRe.FindStringIndex(s)
	if loc == nil {
		return s, false
	}
	rest := s[loc[1]:]
	if rest != "" && (rest[0] == '"' || rest[0] == '\'') {
		end := strings.IndexByte(rest[1:], rest[0])
		if end < 0 {
			return "", true
		}
		rest = rest[end+2:]
	} else if i := strings.IndexAny(rest, " \t"); i >= 0 {
		rest = rest[i:]
	} else {
		rest = ""
	}
	return strings.TrimLeft(rest, " \t"), true
}

// skippedPrograms only move or configure the shell; the next command is the
// real one.
var skippedPrograms = map[string]bool{"cd": true, "pushd": true, "popd": true, "export": true, "set": true, "source": true, ".": true}

var segmentSplitRe = regexp.MustCompile(`&&|\|\||;|\n`)

// stripWrappers drops leading env assignments and the timeout/env/time/nice
// wrappers (with their numeric argument) from a command segment.
func stripWrappers(s string) string {
	for {
		s = strings.TrimSpace(s)
		if rest, ok := skipEnvAssign(s); ok {
			s = rest
			continue
		}
		fields := strings.Fields(s)
		if len(fields) == 0 {
			return ""
		}
		drop := 0
		switch fields[0] {
		case "env", "time":
			drop = 1
		case "timeout":
			drop = 1
			if len(fields) > 1 && !strings.HasPrefix(fields[1], "-") {
				drop = 2
			}
		case "nice":
			drop = 1
			if len(fields) > 2 && fields[1] == "-n" {
				drop = 3
			}
		default:
			return s
		}
		s = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(s), fields[0]))
		for i := 1; i < drop; i++ {
			s = strings.TrimSpace(strings.TrimPrefix(s, fields[i]))
		}
	}
}

// shellTarget returns the program and at most one subcommand of the first
// real command in a shell line, skipping cd/export-style segments, env
// assignments and wrappers. Nothing else from the line is ever kept.
func shellTarget(cmd string) string {
	for _, seg := range segmentSplitRe.Split(cmd, -1) {
		if i := strings.IndexByte(seg, '|'); i >= 0 {
			seg = seg[:i]
		}
		fields := strings.Fields(stripWrappers(seg))
		if len(fields) == 0 {
			continue
		}
		prog := filepath.Base(fields[0])
		if skippedPrograms[prog] {
			continue
		}
		if !progRe.MatchString(prog) {
			return ""
		}
		if len(fields) > 1 {
			switch {
			case prog == "bash" || prog == "sh" || prog == "zsh":
				if script := filepath.Base(fields[1]); !strings.HasPrefix(fields[1], "-") && progRe.MatchString(script) {
					return prog + " " + script
				}
			case subcommandPrograms[prog] && subcmdRe.MatchString(fields[1]) && !strings.HasPrefix(fields[1], "-"):
				return prog + " " + fields[1]
			}
		}
		return prog
	}
	return ""
}

// rejected reports an owner "reject" permission decision (an object on real
// records; anything else is treated as no decision).
func rejected(raw json.RawMessage) bool {
	var d struct {
		Decision string `json:"decision"`
	}
	return json.Unmarshal(raw, &d) == nil && d.Decision == "reject"
}
