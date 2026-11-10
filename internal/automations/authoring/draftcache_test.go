package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// cacheTool is the fixture's draft_automation with a workspace directory.
func (f *draftFixture) cacheTool(workspaceDir string) *tools.Tool {
	return NewDraftAutomation(Deps{
		DB:           f.d,
		WorkspaceDir: workspaceDir,
		Backends:     func() automations.Backends { return automations.Backends{Generator: f.gen, Registry: f.reg} },
		Clock:        automationstest.NewFakeClock(draftNow),
	})
}

func (f *draftFixture) callBound(t *testing.T, workspaceDir, text string, b tools.Binding) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"recipe_text": text})
	if err != nil {
		t.Fatal(err)
	}
	out, err := f.cacheTool(workspaceDir).Execute(context.Background(), f.d, tools.Call{Args: raw, Binding: b})
	if err != nil {
		t.Fatalf("draft_automation: %v", err)
	}
	js, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	return string(js)
}

func readDraftCache(t *testing.T, d *db.DB, conversationID int64) []DraftCacheEntry {
	t.Helper()
	rows, err := d.DraftCache(conversationID)
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	var out []DraftCacheEntry
	for _, r := range rows {
		var e DraftCacheEntry
		if err := json.Unmarshal([]byte(r), &e); err != nil {
			t.Fatalf("cache entry: %v", err)
		}
		out = append(out, e)
	}
	return out
}

// seedConversations inserts the editor chats the cache rows belong to.
func seedConversations(t *testing.T, d *db.DB, ids ...int64) {
	t.Helper()
	for _, id := range ids {
		if _, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (?, '', 1, 1)`, id); err != nil {
			t.Fatal(err)
		}
	}
}

func editorBinding(conversationID int64) tools.Binding {
	return tools.Binding{Surface: tools.AutomationEditorSurface, ConversationID: conversationID}
}

// TestCacheDraft_WritesRows (#604 G2): the editor's draft lands in
// automation_draft_cache, and no automation-drafts directory is created.
func TestCacheDraft_WritesRows(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 42)
	dir := t.TempDir()
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	resJSON := f.callBound(t, dir, text, editorBinding(42))

	entries := readDraftCache(t, f.d, 42)
	if len(entries) != 1 {
		t.Fatalf("entries = %d; want 1", len(entries))
	}
	if entries[0].RecipeText != text || entries[0].At != "2026-10-14T12:00:00Z" {
		t.Fatalf("entry = %+v", entries[0])
	}
	cached, err := json.Marshal(entries[0].Result)
	if err != nil {
		t.Fatal(err)
	}
	if string(cached) != resJSON {
		t.Fatalf("cached result %s; want the tool's result %s", cached, resJSON)
	}
	if _, err := os.Stat(filepath.Join(dir, DraftCacheDir)); !os.IsNotExist(err) {
		t.Fatalf("%s exists (%v); want no file", DraftCacheDir, err)
	}
}

func TestDraftCache_NotWrittenOnMainOrWithoutConversation(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 42)
	dir := t.TempDir()
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	f.callBound(t, dir, text, tools.Binding{Surface: "main", ConversationID: 42})
	f.callBound(t, dir, text, editorBinding(0))
	if got := readDraftCache(t, f.d, 42); len(got) != 0 {
		t.Fatalf("cache = %d entries; want nothing written on main or without a conversation", len(got))
	}
}

func TestDraftCache_KeepsTheLastFive(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 7)
	dir := t.TempDir()
	var texts []string
	for i := range 7 {
		// A parse error is a result too, and keeps the test free of model calls.
		text := "not a recipe " + string(rune('a'+i))
		texts = append(texts, text)
		f.callBound(t, dir, text, editorBinding(7))
	}
	entries := readDraftCache(t, f.d, 7)
	if len(entries) != 5 {
		t.Fatalf("entries = %d; want 5", len(entries))
	}
	for i, e := range entries {
		if e.RecipeText != texts[i+2] {
			t.Fatalf("entry %d = %q; want %q (oldest dropped first)", i, e.RecipeText, texts[i+2])
		}
	}
}

func TestDraftCache_WriteFailureLeavesTheResultUnchanged(t *testing.T) {
	f := newDraftFixture(t)
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	want := f.callBound(t, t.TempDir(), text, tools.Binding{Surface: "main"})

	f.gen.Replies = []string{"done"}
	// The cache table is gone: the write fails.
	if _, err := f.d.Exec(`DROP TABLE automation_draft_cache`); err != nil {
		t.Fatal(err)
	}
	got := f.callBound(t, t.TempDir(), text, editorBinding(3))
	var w, g map[string]any
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(got), &g); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(w, g) {
		t.Fatalf("result with a failed cache write %s; want %s", got, want)
	}
}

// A draft whose evaluation fails is cached as an error entry, so the panel
// never shows the older draft as the current one (J5).
func TestDraftCache_EvaluationErrorIsCachedNewest(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 9)
	dir := t.TempDir()
	f.callBound(t, dir, "not a recipe", editorBinding(9))

	failing := recipeText([]string{"llm:light"}, "", `return 1`)
	raw, err := json.Marshal(map[string]any{"recipe_text": failing, "workbench_id": -1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.cacheTool(dir).Execute(context.Background(), f.d, tools.Call{Args: raw, Binding: editorBinding(9)}); err == nil {
		t.Fatal("draft_automation with workbench_id -1 succeeded; want an error")
	}
	entries := readDraftCache(t, f.d, 9)
	if len(entries) != 2 {
		t.Fatalf("entries = %d; want 2", len(entries))
	}
	last := entries[1]
	if last.RecipeText != failing || last.Result != nil || last.Error == "" {
		t.Fatalf("newest entry = %+v; want the failing text, no result, its error", last)
	}
}

// TestDraftCache_KeepsBlocksAndKey: the editor's cache entry carries the
// outputs' blocks, key and content hash (the Look pane reads them).
func TestDraftCache_KeepsBlocksAndKey(t *testing.T) {
	f := newDraftFixture(t)
	text := recipeText(nil, "outputs: [inbox]\nartifacts: living\n", livingBlocksScript)
	seedConversations(t, f.d, 9)
	f.callBound(t, t.TempDir(), text, editorBinding(9))
	entries := readDraftCache(t, f.d, 9)
	if len(entries) != 1 || entries[0].Result == nil || entries[0].Result.DryRun == nil {
		t.Fatalf("cache = %+v; want one entry with a dry run", entries)
	}
	outs := entries[0].Result.DryRun.Outputs
	if len(outs) != 2 || outs[0].Key != "thread:1" || !strings.Contains(string(outs[0].Blocks), `"heading"`) ||
		outs[0].ContentHash == "" || string(outs[1].Blocks) != "null" {
		t.Fatalf("cached outputs = %+v; want blocks, key and hash", outs)
	}
}

// callFolder drafts text with args' extra keys (a folder suggestion) on the
// editor surface of conversationID; the tool's error is returned.
func (f *draftFixture) callFolder(t *testing.T, conversationID int64, text string, folder any) error {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"recipe_text": text, "folder": folder})
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.cacheTool(t.TempDir()).Execute(context.Background(), f.d,
		tools.Call{Args: raw, Binding: editorBinding(conversationID)})
	return err
}

// The editor chat's folder suggestion (inbox builder B, Task 15) is cached
// with its draft, trimmed, and goes with the draft's rows when the Desktop
// discards or saves the draft.
func TestDraftCache_FolderSuggestionRoundTripsAndGoesWithTheDraft(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 42)
	if err := f.callFolder(t, 42, "not a recipe", map[string]any{"title": "  Release ", "parent_slug": "acme"}); err != nil {
		t.Fatalf("draft_automation: %v", err)
	}
	if err := f.callFolder(t, 42, "not a recipe either", nil); err != nil {
		t.Fatalf("draft_automation: %v", err)
	}
	entries := readDraftCache(t, f.d, 42)
	if len(entries) != 2 {
		t.Fatalf("entries = %d; want 2", len(entries))
	}
	want := &FolderSuggestion{Title: "Release", ParentSlug: "acme"}
	if !reflect.DeepEqual(entries[0].Folder, want) {
		t.Fatalf("folder = %+v; want %+v", entries[0].Folder, want)
	}
	if entries[1].Folder != nil {
		t.Fatalf("a draft without a folder cached %+v; want none", entries[1].Folder)
	}
	rows, err := f.d.DraftCache(42)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rows[1], `"folder"`) {
		t.Fatalf("a draft without a suggestion carries the key: %s", rows[1])
	}
	if err := f.d.DeleteDraftCache(42); err != nil {
		t.Fatal(err)
	}
	if got := readDraftCache(t, f.d, 42); len(got) != 0 {
		t.Fatalf("cache = %d entries after the discard; want the suggestion gone with the draft", len(got))
	}
}

// A suggestion that is not a folder title is the chat's error to fix: the
// draft is refused and nothing is cached.
func TestDraftCache_BadFolderSuggestionRefusedNothingCached(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 42)
	for _, folder := range []map[string]any{
		{"title": "   "},
		{"title": strings.Repeat("x", 61)},
		{"title": "Two\nlines"},
		{"title": "Release", "parent_slug": "two words"},
	} {
		err := f.callFolder(t, 42, "not a recipe", folder)
		var verr *tools.ValidationError
		if !errors.As(err, &verr) {
			t.Fatalf("folder %v: err = %v; want a ValidationError", folder, err)
		}
	}
	if got := readDraftCache(t, f.d, 42); len(got) != 0 {
		t.Fatalf("cache = %d entries; want nothing cached for a refused suggestion", len(got))
	}
}

// A cache row whose folder does not decode as a suggestion keeps its draft;
// only the suggestion is dropped.
func TestDraftCacheEntry_UndecodableFolderDroppedDraftKept(t *testing.T) {
	for _, folder := range []string{`"Release"`, `{"title": 5}`, `{"title": ""}`, `[1]`, `null`} {
		line := `{"recipe_text":"r","result":null,"error":"e","at":"2026-10-14T12:00:00Z","folder":` + folder + `}`
		var e DraftCacheEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("folder %s: the draft did not decode: %v", folder, err)
		}
		if e.RecipeText != "r" || e.Error != "e" || e.At != "2026-10-14T12:00:00Z" || e.Folder != nil {
			t.Fatalf("folder %s: entry = %+v; want the draft without a suggestion", folder, e)
		}
	}
	var e DraftCacheEntry
	if err := json.Unmarshal([]byte(`{"recipe_text":"r","folder":{"title":"Release"}}`), &e); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(e.Folder, &FolderSuggestion{Title: "Release"}) {
		t.Fatalf("folder = %+v; want Release at the top level", e.Folder)
	}
}
