package authoring

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"watchtower/internal/fsutil"
	"watchtower/internal/tools"
)

// The editor's draft cache (controller ruling, Task 11): the Desktop's
// "New automation" Draft panel cannot see a read tool's result (embedded
// chats stream text only), so draft_automation on the automation_editor
// surface keeps its last few results — with the text they were drafted
// from — in <workspace>/automation-drafts/<conversation id>.jsonl. A UI cache
// of the tool's own result, not a store of record: no database row, and a
// write failure is logged and never changes the draft's result.
const (
	DraftCacheDir  = "automation-drafts"
	draftCacheKeep = 5
)

// DraftCacheEntry is one line of the cache, decoded by the Desktop's
// AutomationDraftPanelModel.
type DraftCacheEntry struct {
	RecipeText string       `json:"recipe_text"`
	Result     *DraftResult `json:"result"`
	At         string       `json:"at"`
}

// DraftCachePath is the cache file of a conversation.
func DraftCachePath(workspaceDir string, conversationID int64) string {
	return filepath.Join(workspaceDir, DraftCacheDir, strconv.FormatInt(conversationID, 10)+".jsonl")
}

// cacheDraft records res for the editor chat that drafted it. Only the
// automation_editor surface with a known conversation writes; best effort.
func (d Deps) cacheDraft(b tools.Binding, text string, res *DraftResult) {
	if b.Surface != tools.AutomationEditorSurface || b.ConversationID <= 0 || d.WorkspaceDir == "" {
		return
	}
	now := time.Now()
	if d.Clock != nil {
		now = d.Clock.Now()
	}
	entry := DraftCacheEntry{RecipeText: text, Result: res, At: now.UTC().Format(time.RFC3339)}
	if err := appendDraftCache(DraftCachePath(d.WorkspaceDir, b.ConversationID), entry); err != nil {
		log.Printf("draft_automation: caching the draft for conversation %d: %v", b.ConversationID, err)
	}
}

// appendDraftCache rewrites path atomically with its newest draftCacheKeep
// lines, entry last.
func appendDraftCache(path string, entry DraftCacheEntry) error {
	line, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("encoding the entry: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("creating the cache directory: %w", err)
	}
	var lines [][]byte
	old, err := os.ReadFile(path)
	switch {
	case err == nil:
		sc := bufio.NewScanner(bytes.NewReader(old))
		sc.Buffer(make([]byte, 0, 64*1024), len(old)+1)
		for sc.Scan() {
			if l := bytes.TrimSpace(sc.Bytes()); len(l) > 0 {
				lines = append(lines, append([]byte(nil), l...))
			}
		}
	case !errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("reading the cache: %w", err)
	}
	lines = append(lines, line)
	if len(lines) > draftCacheKeep {
		lines = lines[len(lines)-draftCacheKeep:]
	}
	return fsutil.WriteFileAtomic(path, append(bytes.Join(lines, []byte("\n")), '\n'), 0o600)
}
