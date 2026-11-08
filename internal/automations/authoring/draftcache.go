package authoring

import (
	"encoding/json"
	"log"
	"strings"
	"time"
	"unicode"

	"watchtower/internal/inboxfolders"
	"watchtower/internal/tools"
)

// The editor's draft cache (controller ruling, Task 11): the Desktop's
// "New automation" Draft panel cannot see a read tool's result (embedded
// chats stream text only), so draft_automation on the automation_editor
// surface keeps its last few results — with the text they were drafted
// from — in automation_draft_cache (#604 G2; it used to be
// <workspace>/automation-drafts/<conversation id>.jsonl, DraftCacheDir, now
// imported once by ImportLegacyDraftCache). A UI cache of the tool's own
// result, not a store of record: a write failure is logged and never
// changes the draft's result.
const (
	DraftCacheDir  = "automation-drafts"
	draftCacheKeep = 5
)

// DraftCacheEntry is one entry of the cache (an entry_json), decoded by the Desktop's
// AutomationDraftPanelModel. A draft whose evaluation failed is cached too —
// Result null, Error its message — so the panel never shows an older draft
// as the current one.
type DraftCacheEntry struct {
	RecipeText string       `json:"recipe_text"`
	Result     *DraftResult `json:"result"`
	Error      string       `json:"error,omitempty"`
	At         string       `json:"at"`
	// Folder is the chat's Inbox folder suggestion for this draft (nil =
	// none): placement, which the Desktop routes after the owner's save.
	Folder *FolderSuggestion `json:"folder,omitempty"`
}

// UnmarshalJSON decodes an entry whose folder suggestion does not decode
// as an entry without one: the draft is kept, the suggestion dropped.
func (e *DraftCacheEntry) UnmarshalJSON(data []byte) error {
	type plain DraftCacheEntry
	var raw struct {
		plain
		Folder json.RawMessage `json:"folder,omitempty"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*e = DraftCacheEntry(raw.plain)
	e.Folder = decodeFolderSuggestion(raw.Folder)
	return nil
}

// FolderSuggestion is the editor chat's proposed Inbox folder: a title and
// the slug of the folder it sits in ("" = the root). The Desktop shows it
// as "Folder: <title>" when a folder of that title is there already, else
// "New folder: <title>, in <parent>", and routes the saved automation to it.
type FolderSuggestion struct {
	Title      string `json:"title" jsonschema:"the folder's title, 1 to 60 characters on one line; an existing folder's title reuses it"`
	ParentSlug string `json:"parent_slug,omitempty" jsonschema:"the slug of the folder it sits in, from list_inbox_folders; omit for the top level"`
}

// clean checks a suggestion the chat sent: a title a folder may have (it is
// trimmed) and a parent slug without spaces. nil stays nil.
func (s *FolderSuggestion) clean() (*FolderSuggestion, error) {
	if s == nil {
		return nil, nil
	}
	title, err := inboxfolders.CleanTitle(s.Title)
	if err != nil {
		return nil, &tools.ValidationError{Msg: "folder.title: " + err.Error()}
	}
	parent := strings.TrimSpace(s.ParentSlug)
	if strings.ContainsFunc(parent, unicode.IsSpace) {
		return nil, &tools.ValidationError{Msg: "folder.parent_slug: a slug has no spaces (see list_inbox_folders)"}
	}
	return &FolderSuggestion{Title: title, ParentSlug: parent}, nil
}

// decodeFolderSuggestion is a cached suggestion, or nil when there is none
// or it does not decode as a valid one.
func decodeFolderSuggestion(raw json.RawMessage) *FolderSuggestion {
	if len(raw) == 0 {
		return nil
	}
	var s FolderSuggestion
	if json.Unmarshal(raw, &s) != nil {
		return nil
	}
	cleaned, err := s.clean()
	if err != nil {
		return nil
	}
	return cleaned
}

// cacheDraft records res — or, when the evaluation failed, evalErr — for
// the editor chat that drafted text. Only the automation_editor surface with
// a known conversation writes; best effort.
func (d Deps) cacheDraft(b tools.Binding, text string, folder *FolderSuggestion, res *DraftResult, evalErr error) {
	if b.Surface != tools.AutomationEditorSurface || b.ConversationID <= 0 || d.DB == nil {
		return
	}
	now := time.Now()
	if d.Clock != nil {
		now = d.Clock.Now()
	}
	entry := DraftCacheEntry{RecipeText: text, Result: res, At: now.UTC().Format(time.RFC3339), Folder: folder}
	if evalErr != nil {
		entry.Result, entry.Error = nil, evalErr.Error()
	}
	line, err := json.Marshal(entry)
	if err == nil {
		err = d.DB.AppendDraftCache(b.ConversationID, string(line), now, draftCacheKeep)
	}
	if err != nil {
		log.Printf("draft_automation: caching the draft for conversation %d: %v", b.ConversationID, err)
	}
}
