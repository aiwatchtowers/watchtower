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
// server, the knowledge index — reads the chat tables, except the readers
// listed in chatTableReaders, so none can list or search those
// conversations. A new tool that reads them must keep them out
// (`context_type IS NULL`, or an allow-list without `code_question`) and
// extend this guard with a behavioural test before it is let through here:
// an entry in chatTableReaders naming that test.
func TestCodeQuestionGuard_NoGoToolReadsChatHistory(t *testing.T) {
	seen := map[string]bool{}
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
			loc := chatTablesPattern.FindIndex(src)
			if loc == nil {
				continue
			}
			if reader, ok := chatTableReaders[file]; ok {
				seen[file] = true
				checkChatTableReader(t, file, src, reader)
				continue
			}
			t.Errorf("%s reads the chat tables (%q): code_question conversations must stay out of every chat history or search tool — filter them and extend this guard",
				file, src[loc[0]:loc[1]])
		}
	}
	for file := range chatTableReaders {
		if !seen[file] {
			t.Errorf("chatTableReaders lists %s, which no longer reads the chat tables: drop the entry", file)
		}
	}
}

// chatTableReader is a reviewed Go reader of the chat tables: its source
// filters `code_question` conversations out, and test (a func in
// testFile) proves it behaviourally.
type chatTableReader struct {
	testFile, test string
}

// chatTableReaders are the Go files let through the guard, each with the
// behavioural test that proves code questions stay out.
var chatTableReaders = map[string]chatTableReader{
	// Kept chat artifacts in the knowledge index (chat knowledge, 2026-10-24).
	filepath.Join("..", "kb", "source_chat_artifact.go"): {
		testFile: filepath.Join("..", "kb", "source_chat_artifact_test.go"),
		test:     "TestChatArtifactSource_SkipsCodeQuestionChats",
	},
}

// checkChatTableReader: a listed reader still names the code_question
// filter in its SQL, and its behavioural test still exists.
func checkChatTableReader(t *testing.T, file string, src []byte, reader chatTableReader) {
	t.Helper()
	if !strings.Contains(string(src), "'code_question'") {
		t.Errorf("%s reads the chat tables but no longer filters 'code_question' conversations", file)
	}
	testSrc, err := os.ReadFile(reader.testFile)
	if err != nil {
		t.Errorf("%s: its behavioural test file: %v", file, err)
		return
	}
	if !strings.Contains(string(testSrc), "func "+reader.test+"(t *testing.T)") {
		t.Errorf("%s: behavioural test %s is missing from %s", file, reader.test, reader.testFile)
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
