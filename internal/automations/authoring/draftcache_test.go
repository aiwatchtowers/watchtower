package authoring

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
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
