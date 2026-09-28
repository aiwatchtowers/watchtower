package chat

import (
	"os"
	"strings"
)

// WriteTurnFile records the running turn id for the chat-mode MCP server
// (spec §1.2): a warm session spans many turns, so the server reads the file
// at propose time instead of taking --turn at launch. Written to a temp file
// and renamed, so a reader never sees a half-written id; mode 0600.
func WriteTurnFile(path, turnID string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(turnID), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// TurnFileReader returns a function reading the current turn id from path;
// an unreadable file reads as "".
func TurnFileReader(path string) func() string {
	return func() string {
		b, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
}
