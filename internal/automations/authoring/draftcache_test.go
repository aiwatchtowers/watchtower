package authoring

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
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

func readDraftCache(t *testing.T, path string) []DraftCacheEntry {
	t.Helper()
	fh, err := os.Open(path)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	defer fh.Close()
	var out []DraftCacheEntry
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		var e DraftCacheEntry
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatalf("cache line: %v", err)
		}
		out = append(out, e)
	}
	return out
}

func editorBinding(conversationID int64) tools.Binding {
	return tools.Binding{Surface: tools.AutomationEditorSurface, ConversationID: conversationID}
}

func TestDraftCache_WrittenOnEditorSurfaceWithConversation(t *testing.T) {
	f := newDraftFixture(t)
	dir := t.TempDir()
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	resJSON := f.callBound(t, dir, text, editorBinding(42))

	path := DraftCachePath(dir, 42)
	entries := readDraftCache(t, path)
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
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("file mode = %v (%v); want 0600", info.Mode().Perm(), err)
	}
	if info, err := os.Stat(filepath.Dir(path)); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode = %v (%v); want 0700", info.Mode().Perm(), err)
	}
}

func TestDraftCache_NotWrittenOnMainOrWithoutConversation(t *testing.T) {
	f := newDraftFixture(t)
	dir := t.TempDir()
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	f.callBound(t, dir, text, tools.Binding{Surface: "main", ConversationID: 42})
	f.callBound(t, dir, text, editorBinding(0))
	if _, err := os.Stat(filepath.Join(dir, DraftCacheDir)); !os.IsNotExist(err) {
		t.Fatalf("cache dir exists (%v); want nothing written on main or without a conversation", err)
	}
}

func TestDraftCache_KeepsTheLastFive(t *testing.T) {
	f := newDraftFixture(t)
	dir := t.TempDir()
	var texts []string
	for i := range 7 {
		// A parse error is a result too, and keeps the test free of model calls.
		text := "not a recipe " + string(rune('a'+i))
		texts = append(texts, text)
		f.callBound(t, dir, text, editorBinding(7))
	}
	entries := readDraftCache(t, DraftCachePath(dir, 7))
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
	broken := t.TempDir()
	// The cache directory's place is taken by a file: MkdirAll fails.
	if err := os.WriteFile(filepath.Join(broken, DraftCacheDir), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := f.callBound(t, broken, text, editorBinding(3))
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
	entries := readDraftCache(t, DraftCachePath(dir, 9))
	if len(entries) != 2 {
		t.Fatalf("entries = %d; want 2", len(entries))
	}
	last := entries[1]
	if last.RecipeText != failing || last.Result != nil || last.Error == "" {
		t.Fatalf("newest entry = %+v; want the failing text, no result, its error", last)
	}
}
