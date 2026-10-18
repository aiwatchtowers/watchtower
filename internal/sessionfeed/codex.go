package sessionfeed

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
)

// zstdMagic opens a zstd frame: Codex can compress rollouts, and this reader
// does not decompress them.
var zstdMagic = []byte{0x28, 0xb5, 0x2f, 0xfd}

var codexIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type codexLine struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type codexEvent struct {
	Type    string          `json:"type"`
	Message json.RawMessage `json:"message"` // legacy user_message / agent_message
	Item    struct {
		Type    string `json:"type"`
		ID      string `json:"id"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"item"` // paginated item_completed
}

// ParseCodex reads complete lines of a Codex rollout from r (positioned at
// startOffset) and returns the chat entries they produce, like Parse does for
// a Claude Code transcript. Two dialects are read per line: paginated
// `event_msg` `item_completed` (UserMessage / AgentMessage items) and legacy
// `event_msg` `user_message` / `agent_message`. `response_item` and
// `compacted` lines repeat that text and are skipped; a zstd-compressed
// rollout yields nothing (counted under Unknown "<zstd>").
func ParseCodex(r io.Reader, startOffset int64, conv string) (*Result, error) {
	res := &Result{Offset: startOffset, Unknown: map[string]int{}}
	br := bufio.NewReaderSize(r, 64<<10)
	if startOffset == 0 {
		if head, _ := br.Peek(len(zstdMagic)); bytes.Equal(head, zstdMagic) {
			res.Unknown["<zstd>"]++
			return res, nil
		}
	}
	for {
		lineStart := res.Offset
		raw, n, complete, err := agentlog.NextLine(br, maxLineBytes)
		if !complete {
			if err != nil && !errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("reading rollout: %w", err)
			}
			break
		}
		res.Offset += n
		if raw == nil {
			res.Skipped++
			continue
		}
		var l codexLine
		if json.Unmarshal(raw, &l) != nil {
			res.Unknown["<invalid>"]++
			continue
		}
		if l.Type != "event_msg" {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, l.Timestamp)
		if e, ok := codexEntry(l.Payload, lineStart); ok {
			e.At, e.Conversation = at, conv
			res.Entries = append(res.Entries, e)
		}
	}
	return res, nil
}

// codexEntry maps one event_msg payload to a chat entry. Ids of the legacy
// dialect, which carries none, are "L<line offset>": stable across re-reads.
func codexEntry(payload json.RawMessage, lineStart int64) (Entry, bool) {
	var ev codexEvent
	if json.Unmarshal(payload, &ev) != nil {
		return Entry{}, false
	}
	legacyID := "L" + strconv.FormatInt(lineStart, 10)
	switch ev.Type {
	case "user_message":
		var msg string
		if json.Unmarshal(ev.Message, &msg) != nil {
			return Entry{}, false
		}
		return codexOwnerEntry(legacyID, msg)
	case "agent_message":
		var msg string
		if json.Unmarshal(ev.Message, &msg) != nil || strings.TrimSpace(msg) == "" {
			return Entry{}, false
		}
		return Entry{ID: legacyID, Kind: KindAgent, Text: strings.TrimSpace(msg)}, true
	case "item_completed":
		text := codexItemText(ev)
		id := ev.Item.ID
		if id == "" {
			id = legacyID
		}
		switch ev.Item.Type {
		case "UserMessage":
			return codexOwnerEntry(id, text)
		case "AgentMessage":
			if text == "" {
				return Entry{}, false
			}
			return Entry{ID: id, Kind: KindAgent, Text: text}, true
		}
	}
	return Entry{}, false
}

func codexOwnerEntry(id, text string) (Entry, bool) {
	e, ok := classifyUserText(id, text)
	if ok && e.Kind == KindOwner && strings.HasPrefix(e.Text, briefPrefix) {
		e.Kind = KindBrief
	}
	return e, ok
}

// codexItemText joins the text parts of a paginated message item.
func codexItemText(ev codexEvent) string {
	var parts []string
	for _, p := range ev.Item.Content {
		if strings.EqualFold(p.Type, "text") && strings.TrimSpace(p.Text) != "" {
			parts = append(parts, p.Text)
		}
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}

// LocateCodex finds the rollout of a Codex session: the stored path when it
// is an absolute regular file named for the session, else a glob over the
// date folders under codexHome/sessions. ok is false when none exists.
func LocateCodex(codexHome, sessionID, storedPath string) (string, bool) {
	if !codexIDRe.MatchString(sessionID) {
		return "", false
	}
	base := filepath.Base(storedPath)
	if filepath.IsAbs(storedPath) && strings.HasPrefix(base, "rollout-") && strings.HasSuffix(base, "-"+sessionID+".jsonl") {
		if st, err := os.Stat(storedPath); err == nil && st.Mode().IsRegular() {
			return storedPath, true
		}
	}
	if codexHome == "" {
		return "", false
	}
	root, err := filepath.EvalSymlinks(filepath.Join(codexHome, "sessions"))
	if err != nil {
		return "", false
	}
	matches, _ := filepath.Glob(filepath.Join(root, "*", "*", "*", "rollout-*-"+sessionID+".jsonl"))
	for _, m := range matches {
		resolved, err := filepath.EvalSymlinks(m)
		if err == nil && strings.HasPrefix(resolved, root+string(filepath.Separator)) {
			return resolved, true
		}
	}
	return "", false
}
