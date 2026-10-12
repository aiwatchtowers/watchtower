package terminal

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// zstdMagic opens a zstd frame: Codex can compress rollouts, and this reader
// does not decompress them.
var zstdMagic = []byte{0x28, 0xb5, 0x2f, 0xfd}

// codexRollout is a Codex rollout file
// ($CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl). It holds two
// dialects, told apart per line, so a legacy session resumed by a newer
// Codex reads whole:
//   - paginated: `event_msg` `item_completed` whose item is a `UserMessage`
//     (its `text` content parts);
//   - legacy: `event_msg` `user_message` (its `message`).
//
// `response_item` lines (they repeat the owner's text and carry injected
// context), `compacted` lines (their history repeats it) and unknown types
// are skipped.
type codexRollout struct{ path string }

// findCodexRollout prefers the path the SessionStart hook stored when it is
// an absolute regular file named for this session; else it globs the
// date folders under agentHome/sessions.
func findCodexRollout(agentHome, sessionID, storedPath string) (string, error) {
	if !IsSessionID(sessionID) {
		return "", fmt.Errorf("not a session id: %q", sessionID)
	}
	if isRolloutOf(storedPath, sessionID) {
		if st, err := os.Stat(storedPath); err == nil && st.Mode().IsRegular() {
			return storedPath, nil
		}
	}
	if agentHome == "" {
		return "", errors.New("codex home dir unknown")
	}
	root, err := filepath.EvalSymlinks(filepath.Join(agentHome, "sessions"))
	if errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("%w %s", ErrNoTranscript, sessionID)
	}
	if err != nil {
		return "", fmt.Errorf("codex sessions dir: %w", err)
	}
	matches, _ := filepath.Glob(filepath.Join(root, "*", "*", "*", "rollout-*-"+sessionID+".jsonl"))
	for _, m := range matches {
		resolved, err := filepath.EvalSymlinks(m)
		if err == nil && strings.HasPrefix(resolved, root+string(filepath.Separator)) {
			return resolved, nil
		}
	}
	return "", fmt.Errorf("%w %s", ErrNoTranscript, sessionID)
}

// isRolloutOf reports whether path is an absolute rollout path of the
// session: a stored path never opens an arbitrary file.
func isRolloutOf(path, sessionID string) bool {
	base := filepath.Base(path)
	return filepath.IsAbs(path) && strings.HasPrefix(base, "rollout-") &&
		strings.HasSuffix(base, "-"+sessionID+".jsonl")
}

func (c codexRollout) OwnerText(capChars int) (string, error) {
	f, err := os.Open(c.path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("%w %s", ErrNoTranscript, c.path)
	}
	if err != nil {
		return "", fmt.Errorf("opening rollout: %w", err)
	}
	defer f.Close()

	br := bufio.NewReaderSize(f, 64*1024)
	if head, _ := br.Peek(len(zstdMagic)); bytes.Equal(head, zstdMagic) {
		return "", fmt.Errorf("%w: compressed rollout %s", ErrUnsupportedTranscript, c.path)
	}
	sawLine, sawJSON := false, false
	text, err := scanOwnerText(br, capChars, func(line []byte) string {
		if len(bytes.TrimSpace(line)) > 0 {
			sawLine = true
		}
		text, ok := codexLineText(line)
		sawJSON = sawJSON || ok
		return text
	})
	if err != nil {
		return "", err
	}
	if sawLine && !sawJSON {
		return "", fmt.Errorf("%w: no JSON line in %s", ErrUnsupportedTranscript, c.path)
	}
	return text, nil
}

type rolloutLine struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

type rolloutEvent struct {
	Type    string          `json:"type"`
	Message json.RawMessage `json:"message"` // legacy user_message
	Item    struct {
		Type    string `json:"type"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"item"` // paginated item_completed
}

// codexLineText returns the owner's text on one rollout line; ok is false
// when the line is no JSON object (a truncated last line, a foreign format).
func codexLineText(line []byte) (text string, ok bool) {
	var l rolloutLine
	if json.Unmarshal(line, &l) != nil {
		return "", false
	}
	if l.Type != "event_msg" {
		return "", true
	}
	var ev rolloutEvent
	if json.Unmarshal(l.Payload, &ev) != nil {
		return "", true
	}
	switch ev.Type {
	case "user_message":
		var msg string
		if json.Unmarshal(ev.Message, &msg) != nil {
			return "", true
		}
		return strings.TrimSpace(msg), true
	case "item_completed":
		return userMessageText(ev), true
	default:
		return "", true
	}
}

// userMessageText joins the text parts of a paginated UserMessage item; an
// image-only message (empty text parts) reads as "".
func userMessageText(ev rolloutEvent) string {
	if ev.Item.Type != "UserMessage" {
		return ""
	}
	var parts []string
	for _, p := range ev.Item.Content {
		if p.Type == "text" && strings.TrimSpace(p.Text) != "" {
			parts = append(parts, p.Text)
		}
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}
