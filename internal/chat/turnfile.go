package chat

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// WriteTurnFile records the running turn id for the chat-mode MCP server
// (spec §1.2): a warm session spans many turns, so the server reads the file
// at propose time instead of taking --turn at launch. Written to a temp file
// and renamed, so a reader never sees a half-written id; mode 0600. The temp
// file gets a fresh random name (os.CreateTemp, O_EXCL), so a symlink planted
// at a predictable name can never redirect the write.
func WriteTurnFile(path, turnID string) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("creating the turn file: %w", err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // no-op once renamed
	if _, err := tmp.WriteString(turnID); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing the turn file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing the turn file: %w", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("renaming the turn file: %w", err)
	}
	return nil
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
