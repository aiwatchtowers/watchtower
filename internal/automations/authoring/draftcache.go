package authoring

import (
	"encoding/json"
	"log"
	"time"

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
}

// cacheDraft records res — or, when the evaluation failed, evalErr — for
// the editor chat that drafted text. Only the automation_editor surface with
// a known conversation writes; best effort.
func (d Deps) cacheDraft(b tools.Binding, text string, res *DraftResult, evalErr error) {
	if b.Surface != tools.AutomationEditorSurface || b.ConversationID <= 0 || d.DB == nil {
		return
	}
	now := time.Now()
	if d.Clock != nil {
		now = d.Clock.Now()
	}
	entry := DraftCacheEntry{RecipeText: text, Result: res, At: now.UTC().Format(time.RFC3339)}
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
