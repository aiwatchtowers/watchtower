package tools

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	"watchtower/internal/chat/blocks"
)

// TestPromptToolMentionsAreRegistered pins every read-tool name a chat prompt
// teaches the model to the registry the MCP server mounts (ReadTools plus
// DependentReadTools). The prompts name tools in prose — Go's shared
// blocks.ToolsList/Workflow/LinkingRules and the Swift Discuss surfaces'
// "=== TOOLS" blocks plus ChatPromptRules — and before this test nothing failed
// when a tool was renamed or removed: the Swift tests assert the prompt text,
// not that the tool exists. A prompt naming a tool the registry lacks sends the
// model after a tool that is not there.
//
// A token counts as a tool mention when it is snake_case and starts with the
// verb of a registered tool (list_, get_, search_, ...), so a field name such
// as channel_id or an action kind such as link_target is not mistaken for one,
// while a renamed or dropped tool still is. Each Swift TOOLS block runs from
// its "=== TOOLS" line to the first blank line, "===" header or end of the
// string literal.
func TestPromptToolMentionsAreRegistered(t *testing.T) {
	registered := map[string]bool{}
	verbs := map[string]bool{}
	all := append(ReadTools(), DependentReadTools(ReadDeps{})...)
	for _, tool := range all {
		registered[tool.Name] = true
		verbs[strings.SplitN(tool.Name, "_", 2)[0]] = true
	}
	mention := mentionPattern(verbs)

	// Go side: the text both the main AI Chat and the CLI ask prompt carry.
	goText := map[string]string{
		"blocks.ToolsList":    blocks.ToolsList,
		"blocks.Workflow":     blocks.Workflow,
		"blocks.LinkingRules": blocks.LinkingRules(nil, "T0"),
	}
	for name, text := range goText {
		checkMentions(t, name, text, mention, registered)
	}

	// Swift side: every TOOLS block in the Desktop sources, plus the shared
	// rules file the Discuss surfaces interpolate.
	root := repoRootForMentions(t)
	sources := filepath.Join(root, "WatchtowerDesktop", "Sources")
	blocksFound := 0
	err := filepath.WalkDir(sources, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		raw, rerr := os.ReadFile(path)
		if rerr != nil {
			return rerr
		}
		rel, _ := filepath.Rel(root, path)
		if filepath.Base(path) == "ChatPromptRules.swift" {
			checkMentions(t, rel, string(raw), mention, registered)
		}
		for _, block := range swiftToolsBlocks(string(raw)) {
			if mention.MatchString(block) { // a no-tools block names none
				blocksFound++
			}
			checkMentions(t, rel, block, mention, registered)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", sources, err)
	}
	// Coverage floor: the four Discuss surfaces (meeting, idea, track, target)
	// carry a tool-naming TOOLS block each. Finding fewer means the scan looked
	// in the wrong place or the block shape changed, and would pass vacuously.
	if blocksFound < 4 {
		t.Fatalf("found %d tool-naming Swift TOOLS blocks under %s, want at least 4", blocksFound, sources)
	}
}

func mentionPattern(verbs map[string]bool) *regexp.Regexp {
	list := make([]string, 0, len(verbs))
	for v := range verbs {
		list = append(list, regexp.QuoteMeta(v))
	}
	sort.Strings(list)
	return regexp.MustCompile(`\b(?:` + strings.Join(list, "|") + `)_[a-z0-9_]*[a-z0-9]\b`)
}

func checkMentions(t *testing.T, where, text string, mention *regexp.Regexp, registered map[string]bool) {
	t.Helper()
	for _, name := range mention.FindAllString(text, -1) {
		if !registered[name] {
			t.Errorf("%s names tool %q, which is not a registered read tool (ReadTools/DependentReadTools) — rename it in the prompt or register the tool", where, name)
		}
	}
}

// swiftToolsBlocks returns each "=== TOOLS" block in a Swift source file.
func swiftToolsBlocks(src string) []string {
	var out []string
	lines := strings.Split(src, "\n")
	for i := 0; i < len(lines); i++ {
		if !strings.Contains(lines[i], "=== TOOLS") {
			continue
		}
		block := []string{lines[i]}
		for j := i + 1; j < len(lines); j++ {
			l := strings.TrimSpace(lines[j])
			if l == "" || strings.HasPrefix(l, "===") || strings.HasPrefix(l, `"""`) {
				break
			}
			block = append(block, l)
			i = j
		}
		out = append(out, strings.Join(block, "\n"))
	}
	return out
}

func repoRootForMentions(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Join(filepath.Dir(file), "..", "..")
	if _, err := os.Stat(filepath.Join(root, "WatchtowerDesktop", "Package.swift")); err != nil {
		t.Fatalf("repo root %q has no WatchtowerDesktop/Package.swift: %v", root, err)
	}
	return root
}
