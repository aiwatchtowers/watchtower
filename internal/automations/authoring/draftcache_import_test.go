package authoring

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestImportLegacyDraftCache (#604 Review Focus 4): an older version's
// automation-drafts/<id>.jsonl files are imported in order and removed; a
// file that does not parse is deleted (a cache: no recipe text outside the
// database).
func TestImportLegacyDraftCache(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 11, 12, 13, 14)
	ws := t.TempDir()
	dir := filepath.Join(ws, DraftCacheDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	line := func(text string) string {
		b, err := json.Marshal(DraftCacheEntry{RecipeText: text, At: "2026-10-20T10:00:00Z"})
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	write := func(name string, lines ...string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("11.jsonl", line("a1"), line("a2"))
	write("12.jsonl", line("b1"))
	write("13.jsonl", line("c1"), "{broken")

	n, err := ImportLegacyDraftCache(f.d, ws)
	if err != nil || n != 2 {
		t.Fatalf("ImportLegacyDraftCache = %d, %v; want 2, nil", n, err)
	}
	for id, want := range map[int64][]string{11: {"a1", "a2"}, 12: {"b1"}, 13: nil} {
		var got []string
		for _, e := range readDraftCache(t, f.d, id) {
			got = append(got, e.RecipeText)
		}
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("conversation %d = %v; want %v", id, got, want)
		}
	}
	for _, name := range []string{"11.jsonl", "12.jsonl"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Errorf("%s was not removed", name)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "13.jsonl")); !os.IsNotExist(err) {
		t.Errorf("the unparseable file was not deleted: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("with every file gone, the %s directory must go too: %v", DraftCacheDir, err)
	}

	// A later leftover is imported the same way.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	write("14.jsonl", line("d1"))
	if n, err := ImportLegacyDraftCache(f.d, ws); err != nil || n != 1 {
		t.Fatalf("second import = %d, %v", n, err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("the empty %s directory stayed: %v", DraftCacheDir, err)
	}
	if n, err := ImportLegacyDraftCache(f.d, ws); err != nil || n != 0 {
		t.Fatalf("import with no directory = %d, %v", n, err)
	}
}

// A file whose removal failed is imported again on the next start: the
// conversation already has its rows, so nothing is duplicated or reordered,
// and the file goes this time. A conversation that no longer exists only
// loses the file.
func TestImportLegacyDraftCache_TwiceAfterAFailedRemove(t *testing.T) {
	f := newDraftFixture(t)
	seedConversations(t, f.d, 21)
	ws := t.TempDir()
	dir := filepath.Join(ws, DraftCacheDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, text := range []string{"x1", "x2", "x3"} {
		b, err := json.Marshal(DraftCacheEntry{RecipeText: text, At: "2026-10-20T10:00:00Z"})
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, string(b))
	}
	body := []byte(strings.Join(lines, "\n") + "\n")
	path := filepath.Join(dir, "21.jsonl")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "22.jsonl"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	// The removal fails: the directory is read-only.
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	if _, err := ImportLegacyDraftCache(f.d, ws); err == nil {
		t.Fatal("a failed removal must be reported")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if n, err := ImportLegacyDraftCache(f.d, ws); err != nil || n != 0 {
		t.Fatalf("second import = %d, %v; want 0, nil", n, err)
	}
	var got []string
	for _, e := range readDraftCache(t, f.d, 21) {
		got = append(got, e.RecipeText)
	}
	if strings.Join(got, ",") != "x1,x2,x3" {
		t.Fatalf("cache = %v; want x1,x2,x3 once, in order", got)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("both files (22 has no conversation) and the directory must be gone: %v", err)
	}
}

// A legacy file that cannot be read stays for the next start (an error is
// returned); it is not deleted like one that does not parse.
func TestImportLegacyDraftCache_UnreadableFileStays(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 0000 file")
	}
	f := newDraftFixture(t)
	seedConversations(t, f.d, 31)
	ws := t.TempDir()
	dir := filepath.Join(ws, DraftCacheDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "31.jsonl")
	if err := os.WriteFile(path, []byte(`{"recipe_text":"x","at":"2026-10-20T10:00:00Z"}`+"\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
	if n, err := ImportLegacyDraftCache(f.d, ws); err == nil || n != 0 {
		t.Fatalf("ImportLegacyDraftCache = %d, %v; want 0 and a read error", n, err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("the unreadable file must stay: %v", err)
	}
}
