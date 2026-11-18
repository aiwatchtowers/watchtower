package devpack

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// TestWATCHMAN05_GuardInstalledOnlyByIntegrate pins WATCHMAN-05: the
// `workbench watchman-guard` hook is installed only by the integrate install
// (beside the ask guard), as exactly one PreToolUse entry in its own "*"
// group, taken out by the removal, and nothing else in the package touches
// its spec.
func TestWATCHMAN05_GuardInstalledOnlyByIntegrate(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	for range 2 { // a second install changes nothing
		if _, err := InstallWorkbench(context.Background(), o); err != nil {
			t.Fatalf("install: %v", err)
		}
	}
	cmd := watchmanGuardSpec.command(o.Bin, 7)
	if !strings.Contains(cmd, "workbench watchman-guard --workbench 7") {
		t.Fatalf("the guard's command is %q", cmd)
	}
	pre := eventGroups(t, decodeSettings(t, folder), "PreToolUse")
	if countCommand(pre, cmd) != 1 || countCommand(pre, WorkbenchAskGuardHookCommand(o.Bin, 7)) != 1 {
		t.Fatalf("PreToolUse must hold one Watchman guard entry beside the ask tool block, got %#v", pre)
	}
	for _, g := range pre {
		gm := g.(map[string]any)
		if countCommand([]any{g}, cmd) == 0 {
			continue
		}
		hs := gm["hooks"].([]any)
		h := hs[0].(map[string]any)
		if gm["matcher"] != "*" || len(hs) != 1 || h["type"] != "command" || h["timeout"] != float64(5) || h["async"] != nil {
			t.Fatalf("the Watchman guard sits alone, synchronous, in a \"*\" group: %#v", gm)
		}
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.WatchmanGuard {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}

	if changed, err := RemoveAskGuardHooks(folder, 7); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if n := countCommand(eventGroups(t, decodeSettings(t, folder), "PreToolUse"), cmd); n != 0 {
		t.Fatalf("the removal must take the guard out, %d left", n)
	}
	if ok, err := HasWatchmanGuardHook(folder, 7); err != nil || ok {
		t.Fatalf("after removal: ok=%v err=%v", ok, err)
	}

	// Source scan: only the ask guard's installers (and the status read)
	// name the spec; nothing else in the package can install it.
	allowed := []string{"", "InstallAskGuardHooks", "RemoveAskGuardHooks", "HasWatchmanGuardHook"}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	uses := 0
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range f.Decls {
			fn, _ := decl.(*ast.FuncDecl)
			ast.Inspect(decl, func(n ast.Node) bool {
				id, ok := n.(*ast.Ident)
				if !ok || id.Name != "watchmanGuardSpec" {
					return true
				}
				uses++
				owner := ""
				if fn != nil {
					owner = fn.Name.Name
				}
				if !slices.Contains(allowed, owner) {
					t.Errorf("%s: watchmanGuardSpec used in %s", fset.Position(id.Pos()), owner)
				}
				return true
			})
		}
	}
	if uses == 0 {
		t.Fatal("the scan found no use of watchmanGuardSpec")
	}
	// Outside the hook tables, the installer and the hook itself, no Go code
	// names the hook's subcommand.
	assertSubcommandOnlyIn(t, "workbench watchman-guard", map[string]bool{
		"internal/sessionagent/claude.go":        true,
		"internal/sessionagent/codex.go":         true,
		"internal/devpack/workbench_settings.go": true,
		"cmd/process_role.go":                    true,
	})
}

// assertSubcommandOnlyIn walks the repository's non-test Go files under
// internal/ and cmd/ and fails on a file outside allowed naming sub.
func assertSubcommandOnlyIn(t *testing.T, sub string, allowed map[string]bool) {
	t.Helper()
	root := filepath.Join("..", "..")
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return err
			}
			b, err := os.ReadFile(path) //nolint:gosec // G122: a read-only scan of the repository's own sources
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(root, path)
			if strings.Contains(string(b), sub) && !allowed[filepath.ToSlash(rel)] {
				t.Errorf("%s names %q", rel, sub)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}
