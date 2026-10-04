package tools

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestCodeQuestionGuard_NoGoToolReadsChatHistory is the Go half of the
// code-question guard (spec 2026-10-02 §9.4, owner decision 2): a
// `code_question` conversation must never surface outside its workbench's
// Questions tab. No model-facing Go tool — the registry here, the MCP
// server, the knowledge index — reads the chat tables today, so none can
// list or search those conversations. A new tool that reads them must keep
// them out (`context_type IS NULL`, or an allow-list without
// `code_question`) and extend this guard with a behavioural test before it
// is let through here.
func TestCodeQuestionGuard_NoGoToolReadsChatHistory(t *testing.T) {
	for _, dir := range []string{".", "../mcp", "../kb"} {
		files := guardedGoFiles(t, dir)
		if len(files) == 0 {
			t.Fatalf("no Go files in %s: the guard would pass vacuously", dir)
		}
		for _, file := range files {
			src, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			if loc := chatTablesPattern.FindIndex(src); loc != nil {
				t.Errorf("%s reads the chat tables (%q): code_question conversations must stay out of every chat history or search tool — filter them and extend this guard",
					file, src[loc[0]:loc[1]])
			}
		}
	}
}

var chatTablesPattern = regexp.MustCompile(`\bchat_(conversations|messages|fts)\b`)

// guardedGoFiles lists the non-test Go files under dir, subpackages
// included (testdata and hidden directories skipped), so a tool moved into
// a subpackage stays under the guard.
func guardedGoFiles(t *testing.T, dir string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if path != dir && (entry.Name() == "testdata" || strings.HasPrefix(entry.Name(), ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}

// TestCodeQuestionGuard_ScanRecursesIntoSubpackages: the guard's walk sees
// a nested package's files and leaves tests and testdata out.
func TestCodeQuestionGuard_ScanRecursesIntoSubpackages(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"top.go", "top_test.go", "sub/deeper/nested.go", "testdata/fixture.go", ".hidden/x.go"} {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("package x\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got := guardedGoFiles(t, root)
	want := []string{filepath.Join(root, "sub/deeper/nested.go"), filepath.Join(root, "top.go")}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("guardedGoFiles = %v, want %v", got, want)
	}
}
