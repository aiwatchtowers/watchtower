package chat

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// ReplayCapChars bounds the replayed history (spec §2.4), in runes.
const ReplayCapChars = 24000

const (
	replayHeader = "=== CONVERSATION SO FAR (replayed from Watchtower's history; the earlier model session is not available) ==="
	replayFooter = "=== END OF CONVERSATION SO FAR — the owner's new message follows ==="
)

// HistoryBefore returns path without the trailing messages of turnID. The
// owner's message is persisted before the turn is sent (CHAT-01), so the
// active path already ends with it; replaying it and then sending it again
// would duplicate it.
//
// Regenerate reuses the owner's message row under its OLD turn id and only
// inserts a new assistant row under the NEW turnID (preflight ruling A13), so
// after the trailing turnID rows are stripped, a still-trailing "user" row is
// dropped too — it is the same text as the turn about to be sent, and
// replaying it would duplicate the owner's question. This extra drop only
// fires when something was actually stripped by turnID: an unknown/stale
// turnID (nothing in path carries it) is a no-op, matching a plain "not part
// of any turn we recognize" call.
func HistoryBefore(path []db.ChatMessage, turnID string) []db.ChatMessage {
	if turnID == "" {
		return path
	}
	end := len(path)
	for end > 0 && path[end-1].TurnID == turnID {
		end--
	}
	if end < len(path) && end > 0 && path[end-1].Role == "user" {
		end--
	}
	return path[:end]
}

// BuildReplay renders path as a transcript block to prepend to the first turn
// of a fresh provider session. See BuildReplaySteps.
func BuildReplay(path []db.ChatMessage, capChars int) string {
	return BuildReplaySteps(path, nil, capChars)
}

// BuildReplaySteps renders path (root first) as a transcript block, newest
// messages kept first: when the entries exceed capChars runes, the oldest are
// dropped and counted in a "[N earlier messages omitted]" line; a single
// newest entry longer than the cap is truncated rather than dropped. Tool
// steps are one line each (steps is keyed by message id). An assistant row
// with no text and no steps says nothing and is skipped — e.g. the empty
// reply the Desktop writes under a legacy unanswered question. Empty path
// (or nothing left to say) → "".
func BuildReplaySteps(path []db.ChatMessage, steps map[int64][]string, capChars int) string {
	entries := make([]string, 0, len(path))
	for _, m := range path {
		if m.Role == "assistant" && strings.TrimSpace(m.Text) == "" && len(steps[m.ID]) == 0 {
			continue
		}
		entries = append(entries, replayEntry(m, steps[m.ID]))
	}
	if len(entries) == 0 {
		return ""
	}

	start, used := len(entries), 0
	for i := len(entries) - 1; i >= 0; i-- {
		n := utf8.RuneCountInString(entries[i])
		if used+n > capChars {
			if start == len(entries) { // the newest alone is over the cap
				entries[i] = truncateRunes(entries[i], capChars-1) + "\n"
				start = i
			}
			break
		}
		used += n
		start = i
	}

	var b strings.Builder
	b.WriteString(replayHeader + "\n")
	if start > 0 {
		fmt.Fprintf(&b, "[%d earlier messages omitted]\n", start)
	}
	for _, e := range entries[start:] {
		b.WriteString(e)
	}
	b.WriteString(replayFooter + "\n\n")
	return b.String()
}

// replayEntry renders one message and its step lines, newline-terminated.
func replayEntry(m db.ChatMessage, steps []string) string {
	speaker := "System"
	switch m.Role {
	case "user":
		speaker = "Owner"
	case "assistant":
		speaker = "Assistant"
		if m.Status == "partial" {
			speaker = "Assistant (stopped early)"
		}
	}
	var b strings.Builder
	b.WriteString(speaker + ": " + strings.TrimSpace(m.Text) + "\n")
	for _, s := range steps {
		b.WriteString("  · step: " + s + "\n")
	}
	return b.String()
}

// ReplayFromDB renders the conversation's active path before turnID as a
// replay block (spec §2.4): the running turn's persisted rows are excluded,
// tool steps become one line each.
func ReplayFromDB(d *db.DB, conversationID int64, turnID string) (string, error) {
	path, err := d.ActiveChatPath(conversationID)
	if err != nil {
		return "", fmt.Errorf("reading the conversation: %w", err)
	}
	hist := HistoryBefore(path, turnID)
	ids := make([]int64, 0, len(hist))
	for _, m := range hist {
		ids = append(ids, m.ID)
	}
	steps, err := d.ChatStepSummaries(ids)
	if err != nil {
		return "", fmt.Errorf("reading tool steps: %w", err)
	}
	return BuildReplaySteps(hist, steps, ReplayCapChars), nil
}
