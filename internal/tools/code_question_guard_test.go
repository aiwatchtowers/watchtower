package tools

import (
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
	chatTables := regexp.MustCompile(`\bchat_(conversations|messages|fts)\b`)
	for _, dir := range []string{".", "../mcp", "../kb"} {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		if len(files) == 0 {
			t.Fatalf("no Go files in %s: the guard would pass vacuously", dir)
		}
		for _, file := range files {
			if strings.HasSuffix(file, "_test.go") {
				continue
			}
			src, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			if loc := chatTables.FindIndex(src); loc != nil {
				t.Errorf("%s reads the chat tables (%q): code_question conversations must stay out of every chat history or search tool — filter them and extend this guard",
					file, src[loc[0]:loc[1]])
			}
		}
	}
}
