package agentfiles

import (
	"encoding/json"
	"path/filepath"
	"strings"
)

// SubagentsDir is the folder that holds the subagent transcripts and meta
// files of the Claude Code session whose main transcript is transcriptPath:
// <dir>/<session>.jsonl keeps them in <dir>/<session>/subagents. "" for a
// path that is not an absolute .jsonl file.
func SubagentsDir(transcriptPath string) string {
	if !filepath.IsAbs(transcriptPath) || !strings.HasSuffix(transcriptPath, ".jsonl") ||
		strings.ContainsRune(transcriptPath, 0) {
		return ""
	}
	base := strings.TrimSuffix(transcriptPath, ".jsonl")
	if b := filepath.Base(base); b == "." || b == string(filepath.Separator) {
		return ""
	}
	return filepath.Join(base, "subagents")
}

// SubagentParent is the parentAgentId of subagent agentID in its meta file
// under subagentsDir (agent-<id>.meta.json): the agent that launched it, ""
// for one the main agent launched, or when the file is missing, special
// (a symlink included), too large, invalid, or the id is not a plain agent
// id. Only that key is decoded (AGENTLOG-01: the description is never read
// into a field).
func SubagentParent(subagentsDir, agentID string) string {
	if subagentsDir == "" || !plainAgentID(agentID) {
		return ""
	}
	raw, ok := readMetaFile(filepath.Join(subagentsDir, "agent-"+agentID+".meta.json"))
	if !ok {
		return ""
	}
	var m struct {
		ParentAgentID string `json:"parentAgentId"`
	}
	if json.Unmarshal(raw, &m) != nil || m.ParentAgentID == agentID || !plainAgentID(m.ParentAgentID) {
		return ""
	}
	return m.ParentAgentID
}

// plainAgentID says id can name a meta file: 1–128 ASCII letters, digits,
// '-' or '_' (subagent ids are hex, teammates' a<name>-<hex>).
func plainAgentID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
