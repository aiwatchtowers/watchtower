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
// file that does not parse stays for the owner, and the directory with it.
func TestImportLegacyDraftCache(t *testing.T) {
	f := newDraftFixture(t)
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
	if _, err := os.Stat(filepath.Join(dir, "13.jsonl")); err != nil {
		t.Errorf("the unparseable file was removed: %v", err)
	}

	// Once the last file goes, so does the directory.
	if err := os.Remove(filepath.Join(dir, "13.jsonl")); err != nil {
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
