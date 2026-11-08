package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"regexp"
	"strings"
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
	Type string `json:"type"`
	// IsMeta and IsCompactSummary mark user entries Claude Code writes itself
	// (skill bodies, command caveats, a compaction's summary), never a turn's
	// opening (opensUserTurn).
	IsMeta           bool `json:"isMeta"`
	IsCompactSummary bool `json:"isCompactSummary"`
	Message          struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type transcriptBlock struct {
	Type      string `json:"type"`
	ID        string `json:"id"`
	ToolUseID string `json:"tool_use_id"`
	Text      string `json:"text"`
}

// reminderBlockRe matches a <system-reminder> block, the context Claude Code
// and hooks inject into a user entry mid-turn.
var reminderBlockRe = regexp.MustCompile(`(?s)<system-reminder>.*?</system-reminder>`)

// toolCallTurn places tool call toolUseID in the transcript at path against
// turnEnd, the transcript's size when the Stop hook let a turn end. The
// transcript is append-only JSON lines, and Claude Code writes a tool call's
// tool_use entry before it runs the tool, so a call whose tool_use starts
// before turnEnd ran in the turn that ended there. It reads forward from
// turnEnd first (a later turn's call, the common case, sits within a few
// kilobytes; a tool_result there whose tool_use is not is the ended turn's)
// and only then back over the ended turn's tail.
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
	switch entry, ok := findToolCall(f, toolUseID, turnEnd, turnEnd+transcriptLookahead); {
	case !ok:
		return toolCallUnknown
	case entry == toolUseEntry:
		return toolCallAfterStop
	case entry == toolResultEntry:
		return toolCallBeforeStop
	}
	if entry, ok := findToolCall(f, toolUseID, max(turnEnd-transcriptLookback, 0), turnEnd); ok && entry != noToolEntry {
		return toolCallBeforeStop
	}
	return toolCallUnknown // not found on either side, or a read failed
}

// toolEntry is the kind of transcript entry that names a tool call.
type toolEntry int

const (
	noToolEntry toolEntry = iota
	toolUseEntry
	toolResultEntry
)

// findToolCall finds the first whole line in [from, to) of f that is
// toolUseID's tool_use or tool_result entry. A span opened mid-line skips
// that line's tail, and a line cut off at to does not parse. ok is false when
// a read failed.
func findToolCall(f *os.File, toolUseID string, from, to int64) (entry toolEntry, ok bool) {
	partial := false
	if from > 0 {
		var prev [1]byte
		if _, err := f.ReadAt(prev[:], from-1); err != nil {
			return noToolEntry, false
		}
		partial = prev[0] != '\n'
	}
	r := bufio.NewReader(io.NewSectionReader(f, from, to-from))
	id := []byte(toolUseID)
	for {
		line, err := r.ReadBytes('\n')
		if !partial && bytes.Contains(line, id) {
			if e := toolCallEntry(line, toolUseID); e != noToolEntry {
				return e, true
			}
		}
		partial = false
		if errors.Is(err, io.EOF) {
			return noToolEntry, true
		}
		if err != nil {
			return noToolEntry, false
		}
	}
}

// toolCallEntry says whether one transcript line is toolUseID's tool_use or
// tool_result entry. Other lines may quote the id (a hook's attachment, a
// message text) and say nothing about when the call ran.
func toolCallEntry(line []byte, toolUseID string) toolEntry {
	var entry transcriptLine
	if json.Unmarshal(line, &entry) != nil {
		return noToolEntry
	}
	var blocks []transcriptBlock
	if json.Unmarshal(entry.Message.Content, &blocks) != nil {
		return noToolEntry // a plain-text message
	}
	for _, b := range blocks {
		switch {
		case entry.Type == "assistant" && b.Type == "tool_use" && b.ID == toolUseID:
			return toolUseEntry
		case entry.Type == "user" && b.Type == "tool_result" && b.ToolUseID == toolUseID:
			return toolResultEntry
		}
	}
	return noToolEntry
}

// interruptedTurnEnd is the end of the turn tool call toolUseID was
// interrupted in (board #1019), read from offset from (a turn end, or 0)
// over at most transcriptLookahead bytes: after the call's tool_use entry,
// the offset where the first user message starts that carries no tool
// result — the interrupt's marker or the owner's next prompt — else the end
// of the last whole line read (a line still being written is left out). A
// tool result, of this call or a parallel one, never ends the turn: those
// entries are the turn's own. found is false when the span holds no
// tool_use entry of the call; ok is false when the transcript cannot be read.
func interruptedTurnEnd(path, toolUseID string, from int64) (end int64, found, ok bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false, false
	}
	defer f.Close()
	if toolUseID == "" {
		return 0, false, true
	}
	partial := false
	if from > 0 {
		var prev [1]byte
		if _, err := f.ReadAt(prev[:], from-1); err != nil {
			return 0, false, false
		}
		partial = prev[0] != '\n'
	}
	r := bufio.NewReader(io.NewSectionReader(f, from, transcriptLookahead))
	id := []byte(toolUseID)
	pos := from
	for {
		line, err := r.ReadBytes('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return 0, false, false
		}
		if !bytes.HasSuffix(line, []byte{'\n'}) {
			return pos, found, true // the end of the span, or a line still being written
		}
		switch {
		case partial:
		case !found:
			found = bytes.Contains(line, id) && toolCallEntry(line, toolUseID) == toolUseEntry
		case opensUserTurn(line):
			return pos, true, true
		}
		partial = false
		pos += int64(len(line))
	}
}

// opensUserTurn says whether a transcript line is a user message that
// opens what follows a turn: an owner's prompt, Claude Code's interrupt
// marker or a notice that starts a turn by itself. Entries Claude Code
// writes inside a turn never do: tool results, isMeta entries (a skill's
// body, a command caveat), a compaction summary, and a message that is only
// <system-reminder> blocks (injected context, hook output).
func opensUserTurn(line []byte) bool {
	var entry transcriptLine
	if json.Unmarshal(line, &entry) != nil || entry.Type != "user" || entry.IsMeta || entry.IsCompactSummary {
		return false
	}
	var text string
	if json.Unmarshal(entry.Message.Content, &text) == nil {
		return !onlyReminders(text)
	}
	var blocks []transcriptBlock
	if json.Unmarshal(entry.Message.Content, &blocks) != nil {
		return false // neither text nor blocks: not a message the owner sent
	}
	var parts []string
	for _, b := range blocks {
		switch b.Type {
		case "tool_result":
			return false
		case "text":
			parts = append(parts, b.Text)
		default:
			return true // an image or another block the owner sent
		}
	}
	return !onlyReminders(strings.Join(parts, "\n"))
}

// onlyReminders: text holds nothing but <system-reminder> blocks and space.
func onlyReminders(text string) bool {
	return strings.TrimSpace(reminderBlockRe.ReplaceAllString(text, "")) == ""
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
