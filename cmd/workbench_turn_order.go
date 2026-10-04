package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
)

// The transcript spans toolCallTurn reads around a Stop's turn end: the
// ended turn's tail before it, the next turn's head after it. Past either the
// answer is unknown and the hook falls back to ordering by time. Vars for
// tests.
var (
	transcriptLookback  int64 = 16 << 20
	transcriptLookahead int64 = 16 << 20
)

// toolCallPlace is where a tool call sits in the transcript against a Stop's
// turn end.
type toolCallPlace int

const (
	toolCallUnknown    toolCallPlace = iota // not found, unreadable, or out of the scanned span
	toolCallBeforeStop                      // the call belongs to the turn that Stop ended
	toolCallAfterStop                       // a later turn's call
)

// transcriptLine is the part of a Claude Code transcript entry that carries
// tool calls: an assistant message's tool_use blocks and a user message's
// tool_result blocks.
type transcriptLine struct {
	Type    string `json:"type"`
	Message struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type transcriptBlock struct {
	Type      string `json:"type"`
	ID        string `json:"id"`
	ToolUseID string `json:"tool_use_id"`
}

// toolCallTurn places tool call toolUseID in the transcript at path against
// turnEnd, the transcript's size when the Stop hook let a turn end. The
// transcript is append-only JSON lines, and Claude Code writes a tool call's
// tool_use entry before it runs the tool, so a call whose entries all start
// before turnEnd ran in the turn that ended there. The first entry naming the
// call decides.
func toolCallTurn(path, toolUseID string, turnEnd int64) toolCallPlace {
	if path == "" || toolUseID == "" || turnEnd < 0 {
		return toolCallUnknown
	}
	f, err := os.Open(path)
	if err != nil {
		return toolCallUnknown
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.Size() < turnEnd {
		return toolCallUnknown // not the transcript the Stop measured
	}
	start := max(turnEnd-transcriptLookback, 0)
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return toolCallUnknown
	}
	r := bufio.NewReader(io.LimitReader(f, turnEnd-start+transcriptLookahead))
	id := []byte(toolUseID)
	pos := start
	partial := start > 0 // a span opened mid-line starts with that line's tail
	for {
		line, err := r.ReadBytes('\n')
		lineStart := pos
		pos += int64(len(line))
		if !partial && bytes.Contains(line, id) && namesToolCall(line, toolUseID) {
			if lineStart < turnEnd {
				return toolCallBeforeStop
			}
			return toolCallAfterStop
		}
		partial = false
		if err != nil {
			return toolCallUnknown // the span ended without the call, or a read failed
		}
	}
}

// namesToolCall reports whether one transcript line is toolUseID's tool_use
// or tool_result entry. Other lines may quote the id (a hook's attachment, a
// message text) and say nothing about when the call ran.
func namesToolCall(line []byte, toolUseID string) bool {
	var entry transcriptLine
	if json.Unmarshal(line, &entry) != nil {
		return false
	}
	var blocks []transcriptBlock
	if json.Unmarshal(entry.Message.Content, &blocks) != nil {
		return false // a plain-text message
	}
	for _, b := range blocks {
		if entry.Type == "assistant" && b.Type == "tool_use" && b.ID == toolUseID ||
			entry.Type == "user" && b.Type == "tool_result" && b.ToolUseID == toolUseID {
			return true
		}
	}
	return false
}

// transcriptSize is the transcript's size in bytes, the turn end a Stop
// records; ok is false when it cannot be read.
func transcriptSize(path string) (size int64, ok bool) {
	if path == "" {
		return 0, false
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return 0, false
	}
	return info.Size(), true
}
